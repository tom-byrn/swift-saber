import Foundation

/// One raw orientation sample from a motion sensor (e.g. an AirPod).
public struct MotionSample: Sendable {
    /// Local time the sample arrived (`CACurrentMediaTime`).
    public var time: Double
    /// Attitude quaternion exactly as reported by the sensor.
    public var attitude: Quat
    /// Gravity in the device frame (unit g). May be zero if the sensor does not report it.
    public var gravity: Vec3
    /// The sensor's own timestamp for this sample (any clock, seconds), if it reports one.
    public var sensorTime: Double?
    /// Gyroscope rotation rate in the device frame (rad/s), if the sensor reports it.
    public var rotationRate: Vec3?

    public init(time: Double, attitude: Quat, gravity: Vec3, sensorTime: Double? = nil, rotationRate: Vec3? = nil) {
        self.time = time; self.attitude = attitude; self.gravity = gravity
        self.sensorTime = sensorTime; self.rotationRate = rotationRate
    }
}

/// Maps a held sensor's orientation onto a saber direction in player space
/// (x right, y up, z towards the player; the screen is at -z).
///
/// The mapping is derived from two poses: "pointing at the screen" and "pointing at the ceiling".
/// This means the AirPod can be held in any orientation inside the fist.
public struct SaberCalibration: Codable, Equatable, Sendable {
    /// Whether the sensor quaternion maps device->world (true) or world->device (false).
    public var deviceToWorld: Bool
    /// Device-to-world rotation captured while pointing at the screen centre.
    public var reference: Quat
    /// Player basis expressed in the sensor's world frame.
    public var right: Vec3
    public var up: Vec3
    public var back: Vec3

    public init(deviceToWorld: Bool, reference: Quat, right: Vec3, up: Vec3, back: Vec3) {
        self.deviceToWorld = deviceToWorld; self.reference = reference
        self.right = right; self.up = up; self.back = back
    }

    @inline(__always) public func worldRotation(_ q: Quat) -> Quat {
        deviceToWorld ? q.normalized : q.normalized.conjugate
    }

    /// Saber direction in player space for a raw attitude.
    public func direction(for attitude: Quat) -> Vec3 {
        let delta = worldRotation(attitude) * reference.conjugate
        let forwardWorld = -back
        let d = delta.rotate(forwardWorld)
        return Vec3(d.dot(right), d.dot(up), d.dot(back)).normalized
    }

    /// Re-centres the forward direction to the current attitude (keeps the basis).
    public mutating func recenter(to attitude: Quat) {
        reference = worldRotation(attitude)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notEnoughRotation(degrees: Double)
        case turnedInsteadOfRaised
        case noSamples

        public var description: String {
            switch self {
            case .notEnoughRotation(let d):
                return String(format: "Only %.0f° of movement detected — point higher, at the ceiling.", d)
            case .turnedInsteadOfRaised:
                return "That looked like a sideways turn. Raise the AirPod straight up towards the ceiling."
            case .noSamples:
                return "No motion data received."
            }
        }
    }

    /// Builds a calibration from the averaged "centre" and "up" poses.
    public static func solve(center: [MotionSample], up upSamples: [MotionSample]) -> Result<SaberCalibration, Failure> {
        guard !center.isEmpty, !upSamples.isEmpty else { return .failure(.noSamples) }
        let q0 = Quat.average(center.map { $0.attitude })
        let q1 = Quat.average(upSamples.map { $0.attitude })
        let g0 = center.reduce(Vec3.zero) { $0 + $1.gravity } / Double(center.count)
        let g1 = upSamples.reduce(Vec3.zero) { $0 + $1.gravity } / Double(upSamples.count)

        let rotation = degrees(q0.angle(to: q1))
        if rotation < 35 { return .failure(.notEnoughRotation(degrees: rotation)) }

        // Work out the quaternion convention: with the right one, gravity expressed in the
        // world frame is the same vector for both poses.
        let hasGravity = g0.length > 0.3 && g1.length > 0.3
        var deviceToWorld = true
        var upWorld = Vec3.unitZ
        if hasGravity {
            let a0 = q0.rotate(g0).normalized, a1 = q1.rotate(g1).normalized
            let b0 = q0.conjugate.rotate(g0).normalized, b1 = q1.conjugate.rotate(g1).normalized
            let scoreA = a0.dot(a1), scoreB = b0.dot(b1)
            deviceToWorld = scoreA >= scoreB
            let down = deviceToWorld ? (a0 + a1) : (b0 + b1)
            upWorld = (-down).normalized
        }

        func W(_ q: Quat) -> Quat { deviceToWorld ? q : q.conjugate }
        let w0 = W(q0), w1 = W(q1)
        let delta = w1 * w0.conjugate
        // Raising the arm rotates positively about the player's "right" axis.
        let axis = delta.axis
        var right = axis - upWorld * axis.dot(upWorld)
        if right.length < 0.5 { return .failure(.turnedInsteadOfRaised) }
        right = right.normalized
        let forward = upWorld.cross(right).normalized
        let back = -forward
        // Re-orthogonalise up.
        let up = back.cross(right).normalized

        return .success(SaberCalibration(deviceToWorld: deviceToWorld, reference: w0, right: right, up: up, back: back))
    }

    /// Calibration used when the user skips calibration: assumes the sensor quaternion
    /// is device->world with a z-up world and the device's -z axis pointing at the screen.
    public static func fallback(current: Quat) -> SaberCalibration {
        var c = SaberCalibration(deviceToWorld: true, reference: current.normalized,
                                 right: Vec3(1, 0, 0), up: Vec3(0, 0, 1), back: Vec3(0, -1, 0))
        c.recenter(to: current)
        return c
    }
}

/// Applies the user's sensitivity setting to a direction by scaling yaw and pitch
/// relative to straight ahead.
public func applySensitivity(_ dir: Vec3, gain: Double) -> Vec3 {
    if abs(gain - 1) < 1e-6 { return dir.normalized }
    let d = dir.normalized
    let yaw = atan2(d.x, -d.z)
    let pitch = asin(clamp(d.y, -1, 1))
    let ny = clamp(yaw * gain, -.pi * 0.95, .pi * 0.95)
    let np = clamp(pitch * gain, -radians(88), radians(88))
    return Vec3(sin(ny) * cos(np), sin(np), -cos(ny) * cos(np))
}

/// Step-by-step calibration driver for one sensor stream.
/// Feed it samples; it detects when the user holds still and captures each pose.
public final class CalibrationProcess {
    public enum Step: Equatable, Sendable {
        case pointAtScreen
        case pointUp
        case confirmCenter
        case done
        case failed(String)
    }

    public private(set) var step: Step = .pointAtScreen
    /// 0...1 progress of the current hold.
    public private(set) var holdProgress: Double = 0
    public private(set) var result: SaberCalibration?

    let holdDuration: Double
    let stillThresholdDegrees: Double
    private var window: [MotionSample] = []
    private var centerSamples: [MotionSample] = []
    private var upSamples: [MotionSample] = []
    private var stillSince: Double?

    public init(holdDuration: Double = 0.9, stillThresholdDegrees: Double = 5) {
        self.holdDuration = holdDuration
        self.stillThresholdDegrees = stillThresholdDegrees
    }

    public func restart() {
        step = .pointAtScreen
        holdProgress = 0
        result = nil
        window.removeAll()
        centerSamples.removeAll()
        upSamples.removeAll()
        stillSince = nil
    }

    /// Feeds one sample. Returns true when the step changed.
    @discardableResult
    public func add(_ s: MotionSample) -> Bool {
        if case .done = step { return false }
        if case .failed = step { return false }

        window.append(s)
        window.removeAll { s.time - $0.time > 0.6 }

        // Stillness: every sample in the recent window is close to the newest one.
        let maxDev = window.map { degrees($0.attitude.angle(to: s.attitude)) }.max() ?? 0
        let isStill = maxDev < stillThresholdDegrees && window.count >= 3

        // The "up" step additionally requires being far from the centre pose.
        var poseOK = true
        if step == .pointUp, let c = centerSamples.last {
            poseOK = degrees(c.attitude.angle(to: s.attitude)) > 45
        }

        if isStill && poseOK {
            if stillSince == nil { stillSince = s.time }
        } else {
            stillSince = nil
        }
        holdProgress = stillSince.map { clamp((s.time - $0) / holdDuration, 0, 1) } ?? 0

        guard let since = stillSince, s.time - since >= holdDuration else { return false }
        let captured = window.filter { $0.time >= since }
        stillSince = nil
        holdProgress = 0
        window.removeAll()

        switch step {
        case .pointAtScreen:
            centerSamples = captured
            step = .pointUp
        case .pointUp:
            upSamples = captured
            switch SaberCalibration.solve(center: centerSamples, up: upSamples) {
            case .success(let cal):
                result = cal
                step = .confirmCenter
            case .failure(let f):
                step = .failed(f.description)
            }
        case .confirmCenter:
            if var r = result, let last = captured.last {
                r.recenter(to: last.attitude)
                result = r
            }
            step = .done
        case .done, .failed:
            break
        }
        return true
    }
}
