import Foundation

// AirPods-in-the-closed-case motion: the platform-independent half.
//
// The motion itself comes from `ClosedCaseMotion` (Helpers/AirPodsCase, from AirPointer by
// Andy Gao, MIT). It streams raw accelerometer and gyro rows; this file turns them into an
// orientation (a Swift port of AirPointer's Orientation.js), follows the lid from the
// earbuds' in-case reports, finds the paired AirPods Pro and words every helper failure.

// MARK: - Motion rows

/// One row from the helper's motion pipe: `sequence,service,sensor_us,received_uptime,x,y,z`.
public struct CaseMotionRow: Equatable, Sendable {
    public enum Sensor: Int, Sendable { case accelerometer = 11, gyro = 12 }
    public var sensor: Sensor
    /// Sensor clock, microseconds.
    public var stamp: Double
    /// Mac uptime (seconds) when the helper received it.
    public var host: Double
    /// Raw value × 1e-5: g for the accelerometer, degrees/second for the gyro.
    public var raw: Vec3

    public init(sensor: Sensor, stamp: Double, host: Double, raw: Vec3) {
        self.sensor = sensor; self.stamp = stamp; self.host = host; self.raw = raw
    }

    /// Parses one line. Nil for anything malformed or for a sensor this game doesn't use.
    public init?(line: Substring) {
        let parts = line.split(separator: ",")
        guard parts.count == 7 else { return nil }
        let v = parts.compactMap { Double($0) }
        guard v.count == 7, v.allSatisfy(\.isFinite), let sensor = Sensor(rawValue: Int(v[1])), v[2] > 0 else { return nil }
        self.init(sensor: sensor, stamp: v[2], host: v[3], raw: Vec3(v[4], v[5], v[6]) * 1e-5)
    }
}

/// Splits the helper's stdout into rows, keeping a partial last line for the next read.
public struct CaseMotionLineBuffer {
    private var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [CaseMotionRow] {
        pending.append(data)
        var rows: [CaseMotionRow] = []
        while let end = pending.firstIndex(of: 10) {
            let line = pending[pending.startIndex..<end]
            pending.removeSubrange(pending.startIndex...end)
            if let text = String(data: line, encoding: .utf8), let row = CaseMotionRow(line: Substring(text)) { rows.append(row) }
        }
        // A runaway line can't grow memory without bound.
        if pending.count > 65536 { pending.removeAll() }
        return rows
    }
}

// MARK: - Orientation

/// Gyro integration with gravity tilt correction, for an IMU with no compass.
///
/// `q` maps the sensor's body frame to a reference frame fixed when the fusion first became
/// ready. The gyro's resting offset is measured from still stretches: the first one may be a
/// hand-held hold, later ones keep a warm sensor's offset current and must be steadier.
public final class CaseOrientation {
    struct Limits { var span: Double; var gyro: Double; var accel: Double }
    static let firstStill = Limits(span: 1.2, gyro: 0.8, accel: 0.03)
    static let steadyStill = Limits(span: 1.8, gyro: 0.35, accel: 0.015)

    public struct Settling: Equatable, Sendable {
        public var progress: Double
        public var moving: Bool
    }

    /// Body → reference rotation.
    public private(set) var q = Quat.identity
    /// Gyro resting offset, degrees/second.
    public private(set) var bias = Vec3.zero
    /// Latest accelerometer reading, g.
    public private(set) var accel: Vec3?
    private var accelStamp = 0.0
    /// Gravity (as the accelerometer reads it) in the reference frame.
    public private(set) var referenceGravity: Vec3?
    public private(set) var ready = false
    /// Whether a saved offset was used instead of waiting for a still stretch.
    public private(set) var seedUsed = false
    /// How many still stretches have been measured (the offset is worth saving when this grows).
    public private(set) var measured = 0
    /// Bumped whenever the reference frame starts over.
    public private(set) var generation = 0
    /// Uptime of the newest gyro sample used.
    public private(set) var lastHost = 0.0
    public private(set) var lastStamp = 0.0
    /// The offset to start from next time (saved between sessions).
    public private(set) var seed: Vec3?

    private var last: [CaseMotionRow.Sensor: Double] = [:]
    private var window: [(stamp: Double, vector: Vec3, g: Vec3)] = []

    public init(seedBias: Vec3? = nil) {
        if let b = seedBias, b.x.isFinite, b.y.isFinite, b.z.isFinite, b.length < 5 { seed = b }
        reset()
    }

    public func reset() {
        q = .identity; bias = .zero; accel = nil; accelStamp = 0; referenceGravity = nil
        last = [:]; window = []; ready = false; seedUsed = false; generation += 1
    }

    /// Whether the sensor still needs a first still stretch (no saved offset to start from).
    public var needsFirstOffset: Bool { !ready && seed == nil }

    /// How far the first still stretch has got, for a hold ring.
    public var settling: Settling {
        let span = Self.firstStill.span
        if ready { return Settling(progress: 1, moving: false) }
        guard window.count >= 2, let first = window.first, let lastSample = window.last else { return Settling(progress: 0, moving: false) }
        let biasMean = mean(window.map(\.vector)), gMean = mean(window.map(\.g))
        let stable = spread(window.map(\.vector), biasMean) <= Self.firstStill.gyro && spread(window.map(\.g), gMean) <= Self.firstStill.accel
        let seconds = stable ? min(span, (lastSample.stamp - first.stamp) * 1e-6) : 0
        return Settling(progress: seconds / span, moving: !stable)
    }

    /// Feeds one row. Returns true when the orientation advanced.
    @discardableResult
    public func feed(_ row: CaseMotionRow) -> Bool {
        let stamp = row.stamp
        if let previous = last[row.sensor], stamp <= previous { return false }
        let dt = last[row.sensor].map { (stamp - $0) * 1e-6 } ?? 0
        if last[row.sensor] != nil, dt > 0.2 {
            // A gap: hold the last pose rather than integrating across it. Before the fusion is
            // ready there is nothing worth keeping, so it starts over. (AirPointer also starts
            // over after two seconds; a saber keeps its frame so its calibration stays valid,
            // and the gravity correction pulls the tilt back within a moment.)
            if ready { last[row.sensor] = stamp } else { reset() }
            return false
        }
        last[row.sensor] = stamp
        let vector = row.raw
        if row.sensor == .accelerometer {
            accel = vector; accelStamp = stamp
            return false
        }
        guard let g = accel, abs(stamp - accelStamp) <= 100_000 else { return false }
        let magnitude = g.length

        if !ready {
            // The reference pose comes from the first calm sample, so the wait is only for a first offset.
            if let s = seed, magnitude > 0.95, magnitude < 1.05, (vector - s).length < 20 {
                bias = s; referenceGravity = g.normalized; ready = true; seedUsed = true; window = []
                lastHost = row.host; lastStamp = stamp
                return true
            }
            guard let still = still(stamp: stamp, vector: vector, g: g, magnitude: magnitude, limits: Self.firstStill) else { return false }
            bias = still.bias; referenceGravity = still.gravity.normalized; seed = still.bias; measured += 1; ready = true
            lastHost = row.host; lastStamp = stamp
            return true
        }

        // A steadier stretch moves the offset halfway, at most 0.1°/s, so a slow steady turn can't pass for it.
        if let still = still(stamp: stamp, vector: vector, g: g, magnitude: magnitude, limits: Self.steadyStill) {
            let step = still.bias - bias
            let k = min(0.5, 0.1 / max(step.length, 1e-9))
            bias = bias + step * k; seed = bias; measured += 1
        }
        guard dt > 0 else { return false }
        let omega = (vector - bias) * (.pi / 180)
        advance(omega, dt: dt)
        if magnitude > 0.85, magnitude < 1.15, let reference = referenceGravity {
            let expected = q.conjugate.rotate(reference)
            let correction = g.normalized.cross(expected)
            advance(correction * 0.5, dt: dt)
        }
        lastHost = row.host; lastStamp = stamp
        return true
    }

    private func advance(_ rate: Vec3, dt: Double) {
        let speed = rate.length, angle = speed * dt
        guard speed > 1e-10 else { return }
        let delta = Quat(axis: rate / speed, angle: angle)
        q = (q * delta).normalized
    }

    /// The mean of a still stretch is the gyro's resting offset; any movement starts the stretch over.
    private func still(stamp: Double, vector: Vec3, g: Vec3, magnitude: Double, limits: Limits) -> (bias: Vec3, gravity: Vec3)? {
        if magnitude < 0.85 || magnitude > 1.15 || vector.length > 5 { window = []; return nil }
        window.append((stamp, vector, g))
        while window.count > 1, let first = window.first, stamp - first.stamp > (limits.span + 0.4) * 1e6 { window.removeFirst() }
        guard let first = window.first, stamp - first.stamp >= limits.span * 1e6 else { return nil }
        let b = mean(window.map(\.vector)), gravity = mean(window.map(\.g))
        if spread(window.map(\.vector), b) > limits.gyro || spread(window.map(\.g), gravity) > limits.accel { return nil }
        window = []
        return (b, gravity)
    }

    private func mean(_ vs: [Vec3]) -> Vec3 { vs.reduce(.zero, +) / Double(max(1, vs.count)) }
    private func spread(_ vs: [Vec3], _ center: Vec3) -> Double {
        (vs.reduce(0) { $0 + ($1 - center).lengthSquared } / Double(max(1, vs.count))).squareRoot()
    }

    /// The current pose as a saber sample. `gravity` is the down direction in the sensor frame:
    /// the accelerometer reads specific force (+1 g pointing up at rest), so down is its negation,
    /// unless `invertGravity` says this hardware reports the other way.
    public func sample(time: Double, invertGravity: Bool = false) -> MotionSample? {
        guard ready, let g = accel, g.length > 0.3 else { return nil }
        let down = g.normalized * (invertGravity ? 1 : -1)
        return MotionSample(time: time, attitude: q, gravity: down)
    }
}

// MARK: - The lid

public enum CaseLid {
    /// One in-case report from the earbuds (AACP opcode 0x06), as `status.json` lists them.
    public struct Report: Equatable, Sendable {
        public var uptime: Double
        public var primary: Int
        public var secondary: Int
        public init(uptime: Double, primary: Int, secondary: Int) {
            self.uptime = uptime; self.primary = primary; self.secondary = secondary
        }
    }

    public static func reports(_ value: Any?) -> [Report] {
        (value as? [[String: Any]] ?? []).compactMap { r in
            guard let uptime = r["received_uptime"] as? Double, let p = r["primary_code"] as? Int,
                  let s = r["secondary_code"] as? Int else { return nil }
            return Report(uptime: uptime, primary: p, secondary: s)
        }
    }

    /// Whether the lid is closed, from the earbuds' paired in-case reports: a 3 means closed,
    /// and a pair of "both in case" reports within half a second toggles it. A bud lifted out
    /// and put back doesn't count.
    public static func isClosed(_ reports: [Report]) -> Bool {
        var closed = false, index = 0
        while index < reports.count {
            let r = reports[index]
            if r.primary == 3 || r.secondary == 3 {
                closed = true
            } else if index + 1 < reports.count, r.primary == 2, r.secondary == 2,
                      reports[index + 1].primary == 2, reports[index + 1].secondary == 2,
                      reports[index + 1].uptime - r.uptime <= 0.5 {
                closed.toggle(); index += 2; continue
            }
            index += 1
        }
        return closed
    }

    /// Reads Apple's proximity-pairing broadcast (manufacturer data, company ID first): true
    /// while the lid is open, false while closed, nil for any other broadcast or model.
    /// The lid byte is current only while an earbud reports being in the case.
    public static func isOpen(advertisement bytes: [UInt8], productID: UInt16) -> Bool? {
        guard bytes.count == 29, bytes[0] == 0x4C, bytes[1] == 0, bytes[2] == 7, bytes[3] == 0x19, bytes[4] == 1,
              bytes[5] == UInt8(productID & 0xFF), bytes[6] == UInt8(productID >> 8), bytes[7] & 0x44 != 0 else { return nil }
        return bytes[10] & 0x08 == 0
    }

    /// Angle between two gravity readings, degrees.
    public static func tilt(_ a: Vec3, _ b: Vec3) -> Double {
        let n = a.length * b.length
        return n > 0 ? degrees(acos(clamp(a.dot(b) / n, -1, 1))) : 0
    }
}

// MARK: - Finding the AirPods

/// AirPods Pro paired with this Mac, found by Apple's vendor and product IDs (not by name).
public struct CaseAirPods: Equatable, Sendable {
    public var name: String
    public var model: String
    public var address: String
    public var connected: Bool
    public var productID: UInt16

    public init(name: String, model: String, address: String, connected: Bool, productID: UInt16) {
        self.name = name; self.model = model; self.address = address; self.connected = connected; self.productID = productID
    }

    public var title: String { name.localizedCaseInsensitiveContains(model) ? name : "\(name) · \(model)" }

    /// Tested by AirPointer with AirPods Pro 3; AirPods Pro 2 share the case protocol.
    public static let models: [String: String] = ["0x2014": "AirPods Pro 2", "0x2024": "AirPods Pro 2", "0x2027": "AirPods Pro 3"]

    public struct Survey: Equatable, Sendable {
        public var poweredOn: Bool
        public var pairs: [CaseAirPods]
        public init(poweredOn: Bool, pairs: [CaseAirPods]) { self.poweredOn = poweredOn; self.pairs = pairs }
    }

    public enum Choice: Equatable, Sendable {
        case chosen(CaseAirPods), missing, several, bluetoothOff, unreadable
        public var failure: String? {
            switch self {
            case .chosen: return nil
            case .missing: return "No AirPods Pro are paired with this Mac. Pair them in System Settings › Bluetooth, then connect again."
            case .several: return "More than one pair of AirPods Pro is paired with this Mac. Connect the pair you want in the Bluetooth menu, then connect again."
            case .bluetoothOff: return "Bluetooth is off. Turn it on in Control Center, then connect again."
            case .unreadable: return "Swift Saber couldn't read this Mac's Bluetooth devices. Connect again."
            }
        }
    }

    public static func normalized(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: ":").uppercased()
    }

    /// Parses `system_profiler SPBluetoothDataType -json`, connected pairs first.
    public static func parse(_ data: Data) -> Survey? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        let state = (info["controller_properties"] as? [String: Any])?["controller_state"] as? String
        var pairs: [CaseAirPods] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in info[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let device = value as? [String: Any],
                          (device["device_vendorID"] as? String)?.lowercased() == "0x004c",
                          let product = (device["device_productID"] as? String)?.lowercased(), let model = models[product],
                          let address = (device["device_address"] as? String).map(normalized),
                          address.range(of: "^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$", options: .regularExpression) != nil else { continue }
                    pairs.append(CaseAirPods(name: name, model: model, address: address, connected: connected,
                                             productID: UInt16(product.dropFirst(2), radix: 16) ?? 0))
                }
            }
        }
        return Survey(poweredOn: state != "attrib_off", pairs: pairs)
    }

    /// The saved pair while it's still paired; otherwise the only pair, or the only connected one.
    public static func choose(_ survey: Survey?, saved: String?) -> Choice {
        guard let survey else { return .unreadable }
        guard survey.poweredOn else { return .bluetoothOff }
        if let saved = saved.map(normalized), let pair = survey.pairs.first(where: { $0.address == saved }) { return .chosen(pair) }
        if survey.pairs.count == 1 { return .chosen(survey.pairs[0]) }
        let connected = survey.pairs.filter(\.connected)
        if connected.count == 1 { return .chosen(connected[0]) }
        return survey.pairs.isEmpty ? .missing : .several
    }
}

// MARK: - Helper exit codes, in plain words

public enum CaseHelperExit {
    public static let bluetoothDenied = "Swift Saber needs Bluetooth to reach your AirPods. Allow it in System Settings › Privacy & Security › Bluetooth, then connect again."

    /// ClosedCaseRestore's exit codes.
    public static func restoreFailure(_ status: Int32) -> String {
        switch status {
        case 3: return "Your AirPods didn't answer. Open the lid, briefly lift and reseat one earbud, then connect again."
        case 4: return bluetoothDenied
        case 5: return "Your AirPods aren't paired with this Mac anymore. Pair them in System Settings › Bluetooth, then connect again."
        case 6: return CaseAirPods.Choice.bluetoothOff.failure!
        default: return "Swift Saber couldn't start the connection to your AirPods. Connect again."
        }
    }

    /// Exits that mean the AirPods went quiet (usually asleep), not that anything failed. Opening the lid wakes them.
    public static func lostContact(_ status: Int32?) -> Bool { status.map { [35, 40, 42, 43, 44].contains($0) } ?? false }

    /// ClosedCaseMotion's exit codes (the table atop ClosedCaseMotion.m). Nil means nothing to tell.
    public static func helperFailure(_ status: Int32?, stopping: Bool) -> String? {
        let reopen = "Open the lid, take one AirPod out and put it back, then connect again."
        switch status {
        case 0, 46: return nil
        case 2: return "Swift Saber couldn't start its AirPods case helper. Quit and reopen the game, then connect again."
        case 3: return "The connection ended unexpectedly. Open the lid, then connect again."
        case 10, 11: return "Swift Saber couldn't save its session files. Free some disk space, then connect again."
        case 12: return "Swift Saber lost track of which AirPods to use. Connect again."
        case 20: return bluetoothDenied
        case 21: return "Bluetooth isn't ready. Turn it on, wait a few seconds, then connect again."
        case 22: return restoreFailure(5)
        case 23: return "Your AirPods aren't connected. Open the lid, choose them in the Bluetooth menu, then connect again."
        case 24: return "This version of macOS changed a Bluetooth feature the case connection needs. Use an AirPod in your hand instead until Swift Saber is updated."
        case 25: return "Another app is using your AirPods' control connection. Quit other AirPods utilities, then connect again."
        case 26: return "Your AirPods didn't reconnect. " + reopen
        case 27: return "Your AirPods reconnected but didn't open a motion connection. " + reopen
        case 28: return "Your AirPods didn't answer. " + reopen
        case 30: return "No motion came from your AirPods. If they're also connected to your iPhone, turn off Bluetooth there. Keep both AirPods in the open case, then connect again."
        case 31: return "Your AirPods didn't say what model they are. " + reopen
        case 32: return "These earbuds don't report as AirPods Pro. The closed-case saber needs AirPods Pro 2 or 3."
        case 34: return "The case didn't report as an AirPods charging case. Use the case that came with these AirPods, then connect again."
        case 35: return "The charging case stopped responding. Open the lid, then connect again."
        case 36: return "The charging case turned down the request. Open the lid, wait a few seconds, then connect again."
        case 40: return "Your AirPods stopped answering. Open the lid, then connect again."
        case 41: return "Your AirPods sent something unexpected, so the connection stopped to be safe. Open the lid, then connect again."
        case 42: return "Swift Saber couldn't send to your AirPods. Open the lid, then connect again. If it keeps happening, turn Bluetooth off and on."
        case 43: return "Motion from your AirPods stopped. Open the lid, then connect again."
        case 44: return "The connection to your AirPods ended. Open the lid, then connect again."
        case 45: return "The case connection stopped, but your AirPods may still be sending motion. Turn Bluetooth off and on to reset them."
        case 50: return stopping ? nil : "Swift Saber stopped responding, so the AirPods connection closed. Connect again."
        case 51: return stopping ? nil : "Swift Saber stopped reading motion, so the AirPods connection closed. Connect again."
        case 52: return stopping ? nil : "The AirPods connection closed when it was stopped. Connect again."
        case 53: return "The AirPods connection had to be forced closed. If your AirPods act oddly, turn Bluetooth off and on, then connect again."
        default: return stopping ? nil : "The AirPods connection ended unexpectedly. Open the lid, then connect again."
        }
    }
}
