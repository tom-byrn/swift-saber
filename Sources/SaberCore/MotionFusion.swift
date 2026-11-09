import Foundation

/// Turns raw gyroscope + accelerometer readings into an attitude, the way Core Motion's device
/// motion does for AirPods and iPhones. Game controllers (DualSense, DualShock 4, Joy-Con…)
/// only report raw sensor values, so this fills the gap.
///
/// The gyroscope is integrated for a fast, smooth response, and gravity slowly pulls the tilt
/// back into place so it can't drift (a Mahony complementary filter). There's no compass, so
/// the heading can creep slowly over a long song, exactly as with AirPods: recentering fixes it.
public struct AttitudeEstimator: Sendable {
    /// Device → world rotation. World z is up.
    public private(set) var attitude: Quat = .identity
    /// Whether a first gravity reading has set the tilt yet.
    public private(set) var isInitialized = false
    /// Slowly learned gyroscope offset (rad/s), subtracted from every reading.
    public private(set) var gyroBias = Vec3.zero

    /// How strongly gravity corrects the tilt (rad/s per unit of error).
    public var correctionGain = 1.5
    /// How quickly the gyroscope offset is learned.
    public var biasGain = 0.08
    /// Readings further than this from 1 g (in g) mean the controller is being swung, so they
    /// say little about which way is down and are left out of the tilt correction.
    public var accelerationTolerance = 0.25

    private var lastTime: Double?

    public init() {}

    /// Gravity (pointing down, unit length) in the device frame, from the current estimate.
    public var gravity: Vec3 { attitude.conjugate.rotate(Vec3(0, 0, -1)) }

    /// Adds one reading.
    /// - Parameters:
    ///   - rotationRate: rad/s about the device's own axes.
    ///   - acceleration: total acceleration in g. At rest it equals gravity, pointing down.
    ///   - time: seconds, from any monotonic clock.
    public mutating func update(rotationRate: Vec3, acceleration: Vec3, time: Double) {
        let aLen = acceleration.length
        guard isInitialized else {
            // Start level with the measured gravity, so there is no slow settle at the start.
            if aLen > 0.5 {
                attitude = Quat(from: acceleration / aLen, to: Vec3(0, 0, -1))
            }
            isInitialized = true
            lastTime = time
            return
        }
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time
        guard dt > 0, rotationRate.x.isFinite, rotationRate.y.isFinite, rotationRate.z.isFinite else { return }

        var omega = rotationRate - gyroBias
        if acceleration.x.isFinite, acceleration.y.isFinite, acceleration.z.isFinite,
           abs(aLen - 1) < accelerationTolerance {
            // Rotate the estimated "down" towards the measured one.
            let measured = acceleration / aLen
            let error = measured.cross(gravity)
            omega += error * correctionGain
            // Only learn the offset while the controller is fairly still, so swings don't skew it.
            if rotationRate.length < 0.5 {
                gyroBias -= error * (biasGain * dt)
            }
        }
        let speed = omega.length
        if speed > 1e-12 {
            attitude = (attitude * Quat(axis: omega / speed, angle: speed * dt)).normalized
        }
    }

    /// Forgets everything, e.g. after the controller reconnects.
    public mutating func reset() {
        self = AttitudeEstimator()
    }
}

/// Something that can drive a saber, listed in the order the game prefers it.
public struct SaberCandidate<Key: Hashable>: Equatable {
    public var key: Key
    /// Controllers made for one hand (a Joy-Con (L) or (R)) say which.
    public var preferredHand: Hand?

    public init(_ key: Key, preferredHand: Hand? = nil) {
        self.key = key
        self.preferredHand = preferredHand
    }
}

/// Decides which device drives which saber.
public enum SaberAssignment {
    /// The first candidate takes the player's main hand and the second the other hand. A pair
    /// of one-handed controllers (Joy-Con L and R) always goes in the matching hands.
    /// Candidates beyond the second are left out: the player only has two hands.
    public static func assign<Key: Hashable>(_ candidates: [SaberCandidate<Key>], primary: Hand) -> [Hand: Key] {
        var seen = Set<Key>()
        let chosen = candidates.filter { seen.insert($0.key).inserted }.prefix(2)
        guard let a = chosen.first else { return [:] }
        guard chosen.count > 1 else { return [primary: a.key] }
        let b = chosen[chosen.startIndex + 1]
        if let pa = a.preferredHand, let pb = b.preferredHand, pa != pb {
            return [pa: a.key, pb: b.key]
        }
        return [primary: a.key, primary.other: b.key]
    }

    /// Guesses the hand a controller is made for from its name ("Joy-Con (L)", "Joy-Con (R)").
    public static func preferredHand(forControllerNamed name: String) -> Hand? {
        let n = name.lowercased()
        guard n.contains("joy-con") || n.contains("joycon") else { return nil }
        if n.contains("(l)") || n.hasSuffix(" l") || n.contains("left") { return .left }
        if n.contains("(r)") || n.hasSuffix(" r") || n.contains("right") { return .right }
        return nil
    }
}
