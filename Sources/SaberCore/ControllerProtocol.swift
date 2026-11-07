import Foundation

/// Wire protocol between the Swift Saber Mac app and the iPhone "Saber Controller" app.
///
/// Transport: UDP datagrams, discovered via Bonjour (`_swiftsaber._udp`).
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
    /// Moves calibration on to the next pose.
    case next = 3
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
    /// Mac → Phone: calibration progress, so the phone can show a Next button.
    /// Older phone apps ignore this message (unknown kind).
    case calibration(active: Bool, canAdvance: Bool, prompt: String)

    enum Kind: UInt8 {
        case motion = 1, hello = 2, button = 3, status = 4, haptic = 5, calibration = 6
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
        case let .calibration(active, canAdvance, prompt):
            w.u8(Kind.calibration.rawValue)
            w.u8(active ? 1 : 0)
            w.u8(canAdvance ? 1 : 0)
            w.string(prompt)
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
        case .calibration:
            guard let a = r.u8(), let c = r.u8(), let prompt = r.string() else { return nil }
            return .calibration(active: a != 0, canAdvance: c != 0, prompt: prompt)
        }
    }
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
}
