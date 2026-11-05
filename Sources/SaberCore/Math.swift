import Foundation

/// Minimal 3D vector used by the platform-independent game core.
/// (The core avoids `simd` so it can be built and unit-tested on any platform.)
public struct Vec3: Equatable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)
    /// Player-space "forward" (towards the screen).
    public static let forward = Vec3(0, 0, -1)

    @inlinable public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inlinable public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inlinable public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    @inlinable public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    @inlinable public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    @inlinable public static func -= (a: inout Vec3, b: Vec3) { a = a - b }

    @inlinable public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    @inlinable public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    @inlinable public var lengthSquared: Double { x * x + y * y + z * z }
    @inlinable public var length: Double { lengthSquared.squareRoot() }

    public var normalized: Vec3 {
        let l = length
        return l > 1e-12 ? self / l : Vec3(0, 0, -1)
    }

    public func lerp(to b: Vec3, _ t: Double) -> Vec3 { self + (b - self) * t }

    /// Angle in radians between two (not necessarily unit) vectors.
    public func angle(to b: Vec3) -> Double {
        let d = normalized.dot(b.normalized)
        return acos(max(-1, min(1, d)))
    }

    /// Spherical interpolation between two unit directions.
    public func slerpDirection(to b: Vec3, _ t: Double) -> Vec3 {
        let a = normalized, bn = b.normalized
        let d = max(-1, min(1, a.dot(bn)))
        let theta = acos(d)
        if theta < 1e-5 { return a.lerp(to: bn, t).normalized }
        let s = sin(theta)
        if s < 1e-6 { return a.lerp(to: bn, t).normalized }
        let wa = sin((1 - t) * theta) / s
        let wb = sin(t * theta) / s
        return (a * wa + bn * wb).normalized
    }

    public var description: String {
        String(format: "(%.3f, %.3f, %.3f)", x, y, z)
    }
}

/// Unit quaternion (Hamilton convention, `x, y, z` vector part and `w` scalar part).
public struct Quat: Equatable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    public init(axis: Vec3, angle: Double) {
        let a = axis.normalized
        let s = sin(angle / 2)
        self.init(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(angle / 2))
    }

    /// Shortest-arc rotation that takes unit vector `from` onto unit vector `to`.
    public init(from: Vec3, to: Vec3) {
        let f = from.normalized, t = to.normalized
        let d = f.dot(t)
        if d < -0.999999 {
            var axis = Vec3.unitX.cross(f)
            if axis.length < 1e-6 { axis = Vec3.unitY.cross(f) }
            self.init(axis: axis, angle: .pi)
            return
        }
        let c = f.cross(t)
        let q = Quat(x: c.x, y: c.y, z: c.z, w: 1 + d)
        self = q.normalized
    }

    @inlinable public var vector: Vec3 { Vec3(x, y, z) }

    @inlinable public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    @inlinable public var conjugate: Quat { Quat(x: -x, y: -y, z: -z, w: w) }

    public var normalized: Quat {
        let l = (x * x + y * y + z * z + w * w).squareRoot()
        guard l > 1e-12 else { return .identity }
        return Quat(x: x / l, y: y / l, z: z / l, w: w / l)
    }

    @inlinable public func dot(_ b: Quat) -> Double { x * b.x + y * b.y + z * b.z + w * b.w }

    /// Rotates a vector by this (unit) quaternion.
    @inlinable public func rotate(_ v: Vec3) -> Vec3 {
        let u = vector
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }

    /// Rotation angle in radians, in [0, pi].
    public var angle: Double {
        let q = w < 0 ? Quat(x: -x, y: -y, z: -z, w: -w) : self
        let s = q.vector.length
        return 2 * atan2(s, q.w)
    }

    /// Rotation axis (unit) matching `angle` in [0, pi].
    public var axis: Vec3 {
        let q = w < 0 ? Quat(x: -x, y: -y, z: -z, w: -w) : self
        let v = q.vector
        let l = v.length
        return l > 1e-9 ? v / l : Vec3.unitX
    }

    /// Angle between two orientations (independent of quaternion convention).
    public func angle(to b: Quat) -> Double {
        let d = abs(normalized.dot(b.normalized))
        return 2 * acos(min(1, d))
    }

    /// Averages a set of orientations that are close to each other.
    public static func average(_ qs: [Quat]) -> Quat {
        guard let first = qs.first else { return .identity }
        var sx = 0.0, sy = 0.0, sz = 0.0, sw = 0.0
        for q in qs {
            let s: Double = q.dot(first) < 0 ? -1 : 1
            sx += q.x * s; sy += q.y * s; sz += q.z * s; sw += q.w * s
        }
        return Quat(x: sx, y: sy, z: sz, w: sw).normalized
    }

    public var description: String {
        String(format: "Quat(%.3f, %.3f, %.3f | %.3f)", x, y, z, w)
    }
}

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

@inlinable public func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
@inlinable public func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

/// Small deterministic PRNG (SplitMix64) so level generation is reproducible on every platform.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
    public mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
}
