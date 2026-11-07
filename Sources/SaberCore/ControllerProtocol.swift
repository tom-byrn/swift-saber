import Foundation

/// Wire protocol between the Swift Saber Mac app and the Swift Saber iPhone app (the "controller").
///
/// Transport: UDP datagrams, discovered via Bonjour (`_swiftsaber._udp`).
/// Remote-control state and commands travel as JSON inside the same framing.
/// Every datagram is: "SS" magic, protocol version, message type, then the payload
/// (little-endian). This file is shared verbatim by both apps, so it depends only on
/// Foundation and `Math.swift`.
public enum ControllerProtocol {
    public static let bonjourType = "_swiftsaber._udp"
    public static let version: UInt8 = 1
    static let magic: [UInt8] = [0x53, 0x53] // "SS"
}

public enum ControllerButton: UInt8, Sendable {
    case recenter = 1
    case pause = 2
}

public enum ControllerMessage: Equatable, Sendable {
    /// Phone → Mac: one motion sample.
    case motion(sequence: UInt32, attitude: Quat, gravity: Vec3)
    /// Phone → Mac: sent on connect and every few seconds.
    case hello(name: String)
    /// Phone → Mac: a button on the phone was tapped.
    case button(ControllerButton)
    /// Mac → Phone: which saber the phone drives (-1 none, 0 left, 1 right) and whether it is calibrated.
    case status(hand: Int8, calibrated: Bool, macName: String)
    /// Mac → Phone: play a haptic tap (0...1).
    case haptic(intensity: Float)
    /// Mac → Phone: everything the phone needs to mirror the game's current screen as a remote.
    case remoteState(RemoteState)
    /// Phone → Mac: a remote-control action. `id` is random per command so the Mac can drop
    /// the duplicate copies the phone sends to survive a lost datagram.
    case command(id: UInt32, RemoteCommand)

    enum Kind: UInt8 {
        case motion = 1, hello = 2, button = 3, status = 4, haptic = 5, remoteState = 6, command = 7
    }

    // MARK: Encoding

    public func encoded() -> Data {
        var w = ByteWriter()
        w.bytes(ControllerProtocol.magic)
        w.u8(ControllerProtocol.version)
        switch self {
        case let .motion(seq, q, g):
            w.u8(Kind.motion.rawValue)
            w.u32(seq)
            w.f32(Float(q.x)); w.f32(Float(q.y)); w.f32(Float(q.z)); w.f32(Float(q.w))
            w.f32(Float(g.x)); w.f32(Float(g.y)); w.f32(Float(g.z))
        case let .hello(name):
            w.u8(Kind.hello.rawValue)
            w.string(name)
        case let .button(b):
            w.u8(Kind.button.rawValue)
            w.u8(b.rawValue)
        case let .status(hand, calibrated, macName):
            w.u8(Kind.status.rawValue)
            w.u8(UInt8(bitPattern: hand))
            w.u8(calibrated ? 1 : 0)
            w.string(macName)
        case let .haptic(intensity):
            w.u8(Kind.haptic.rawValue)
            w.f32(intensity)
        case let .remoteState(state):
            w.u8(Kind.remoteState.rawValue)
            w.blob(Self.json(state))
        case let .command(id, command):
            w.u8(Kind.command.rawValue)
            w.u32(id)
            w.blob(Self.json(command))
        }
        return Data(w.data)
    }

    // MARK: Decoding

    public static func decode(_ data: Data) -> ControllerMessage? {
        var r = ByteReader(Array(data))
        guard r.u8() == ControllerProtocol.magic[0], r.u8() == ControllerProtocol.magic[1],
              r.u8() == ControllerProtocol.version,
              let raw = r.u8(), let kind = Kind(rawValue: raw) else { return nil }
        switch kind {
        case .motion:
            guard let seq = r.u32(),
                  let qx = r.f32(), let qy = r.f32(), let qz = r.f32(), let qw = r.f32(),
                  let gx = r.f32(), let gy = r.f32(), let gz = r.f32() else { return nil }
            let q = Quat(x: Double(qx), y: Double(qy), z: Double(qz), w: Double(qw))
            guard [q.x, q.y, q.z, q.w, Double(gx), Double(gy), Double(gz)].allSatisfy({ $0.isFinite }) else { return nil }
            return .motion(sequence: seq, attitude: q, gravity: Vec3(Double(gx), Double(gy), Double(gz)))
        case .hello:
            guard let name = r.string() else { return nil }
            return .hello(name: name)
        case .button:
            guard let b = r.u8(), let button = ControllerButton(rawValue: b) else { return nil }
            return .button(button)
        case .status:
            guard let h = r.u8(), let c = r.u8(), let name = r.string() else { return nil }
            return .status(hand: Int8(bitPattern: h), calibrated: c != 0, macName: name)
        case .haptic:
            guard let i = r.f32(), i.isFinite else { return nil }
            return .haptic(intensity: i)
        case .remoteState:
            guard let blob = r.blob(), let state = try? JSONDecoder().decode(RemoteState.self, from: Data(blob)) else { return nil }
            return .remoteState(state)
        case .command:
            guard let id = r.u32(), let blob = r.blob(),
                  let command = try? JSONDecoder().decode(RemoteCommand.self, from: Data(blob)) else { return nil }
            return .command(id: id, command)
        }
    }

    private static func json<T: Encodable>(_ value: T) -> [UInt8] {
        Array((try? JSONEncoder().encode(value)) ?? Data())
    }
}

// MARK: - Remote control

/// A snapshot of the Mac game that the phone renders as a remote control: which screen is
/// showing and every value its controls need. Sent a few times a second and after each command.
public struct RemoteState: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, Sendable {
        case loading, menu, levelSelect, calibration, settings, countdown, playing, paused, results
    }

    public struct Option: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public struct Calibration: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable { case detecting, calibrating, done }
        public struct Stream: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var live: Bool
            public var progress: Double
            public var done: Bool
            public init(id: String, name: String, live: Bool, progress: Double, done: Bool) {
                self.id = id; self.name = name; self.live = live; self.progress = progress; self.done = done
            }
        }
        public var phase: Phase = .detecting
        public var streams: [Stream] = []
        public var title = ""
        public var detail = ""
        public var failure: String?
        public var canStart = false
        public init() {}
    }

    public struct Settings: Codable, Equatable, Sendable {
        public var inputMode = ""
        public var inputModes: [Option] = []
        public var inputDetail = ""
        /// 0 = left, 1 = right.
        public var primaryHand = 1
        public var sensitivity = 1.0
        public var airPodLatencyMs = 0.0
        public var lenientCuts = false
        public var autoRecenter = false
        public var keepAirPodsAwake = false
        public var audioOutput = ""
        public var audioOutputs: [Option] = []
        public var musicVolume = 1.0
        public var sfxVolume = 1.0
        public var audioOffsetMs = 0.0
        public var bloom = true
        public var cameraShake = true
        public var noFail = false
        public init() {}
    }

    public struct Results: Codable, Equatable, Sendable {
        public var headline = ""
        public var rank = ""
        public var score = 0
        public var accuracy = 0.0
        public var failed = false
        public var newRecord = false
        public var maxCombo = 0
        public var goodCuts = 0
        public var totalNotes = 0
        public var misses = 0
        public init() {}
    }

    public var screen: Screen = .loading
    public var loadingProgress = 0.0
    public var songTitle = ""
    public var songInfo = ""
    /// `Difficulty` raw values / names, in order.
    public var difficulties: [String] = []
    public var difficulty = 0
    /// `PlayMode` raw value (0 two sabers, 1 one saber).
    public var mode = 0
    public var twoSabersAvailable = false
    public var sabersReady = 0
    public var anyCalibrated = false
    /// Whether the phone drives a saber in the current input mode (otherwise it is only a remote).
    public var phoneIsSaber = false
    public var mapStats = ""
    public var best: String?
    public var demo = false
    public var countdown = 0
    public var countdownMessage = ""
    public var progress = 0.0
    public var timeText = ""
    public var score = 0
    public var combo = 0
    public var calibration = Calibration()
    public var settings = Settings()
    public var results: Results?

    public init() {}
}

public enum RemoteSettingFlag: String, Codable, Sendable {
    case lenientCuts, autoRecenter, keepAirPodsAwake, bloom, cameraShake, noFail
}

public enum RemoteSettingValue: String, Codable, Sendable {
    case sensitivity, airPodLatencyMs, musicVolume, sfxVolume, audioOffsetMs
}

/// Everything the Mac's menus can do, as remote commands from the phone.
public enum RemoteCommand: Codable, Equatable, Sendable {
    // Main menu
    case openLevelSelect, openCalibration, openSettings, quitGame
    /// Back to the main menu from level select, settings, calibration or results.
    case back
    // Level select
    case selectDifficulty(Int), selectMode(Int), start, watchDemo
    // In game
    case pause, resume, restart, quitToMenu, recenter
    // Calibration
    case beginCalibration, restartCalibration, finishCalibration, calibrationPlayNow, useMouseInstead
    // Settings
    case setFlag(RemoteSettingFlag, Bool)
    case setValue(RemoteSettingValue, Double)
    case setInputMode(String), setPrimaryHand(Int), setAudioOutput(String)
}

// MARK: - Byte helpers

struct ByteWriter {
    var data: [UInt8] = []
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u32(_ v: UInt32) {
        for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8.prefix(200))
        u8(UInt8(utf8.count))
        bytes(utf8)
    }
    /// Up to 65 535 bytes with a 16-bit length.
    mutating func blob(_ b: [UInt8]) {
        let n = min(b.count, Int(UInt16.max))
        u8(UInt8(n & 0xFF)); u8(UInt8(n >> 8))
        bytes(Array(b.prefix(n)))
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var index = 0
    init(_ b: [UInt8]) { bytes = b }
    mutating func u8() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }
    mutating func u32() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[index + i]) << (8 * UInt32(i)) }
        index += 4
        return v
    }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    mutating func string() -> String? {
        guard let n = u8(), index + Int(n) <= bytes.count else { return nil }
        defer { index += Int(n) }
        return String(decoding: bytes[index..<index + Int(n)], as: UTF8.self)
    }
    mutating func blob() -> [UInt8]? {
        guard let lo = u8(), let hi = u8() else { return nil }
        let n = Int(lo) | Int(hi) << 8
        guard index + n <= bytes.count else { return nil }
        defer { index += n }
        return Array(bytes[index..<index + n])
    }
}
