import Foundation

/// Maps a sensor's own sample timestamps onto the local clock.
///
/// Bluetooth and Wi-Fi deliver motion samples in clumps: several arrive almost together, then
/// nothing for a while. Stamping samples with their arrival time makes evenly spaced motion look
/// jerky (and wrecks any speed estimate). The sensor's own timestamps are evenly spaced, so we
/// keep those and only estimate the offset between the two clocks.
///
/// The offset is the smallest `arrival - sensorTime` seen, i.e. the fastest delivery. It is allowed
/// to creep upwards slowly so clock drift, or one unusually fast packet, can't pin it forever.
public struct SensorClock: Sendable {
    /// How fast (seconds per second) the offset may grow back after a fast packet / clock drift.
    public var creepRate: Double = 0.001
    /// A sample this much later than the current offset predicts means the clocks jumped: resync.
    public var resyncThreshold: Double = 0.2
    /// After a gap this long the stream is treated as new.
    public var resyncGap: Double = 1.0

    public private(set) var offset: Double?
    private var lastArrival: Double = 0

    public init() {}

    public mutating func reset() { offset = nil }

    /// Local time at which `sensorTime` was measured. Falls back to `arrival` when there is no
    /// usable sensor timestamp, which is exactly the old behaviour.
    public mutating func map(sensorTime: Double?, arrival: Double) -> Double {
        guard let sensorTime, sensorTime.isFinite, sensorTime > 0 else { return arrival }
        let d = arrival - sensorTime
        if let o = offset, arrival - lastArrival < resyncGap, d - o < resyncThreshold {
            offset = min(d, o + creepRate * max(0, arrival - lastArrival))
        } else {
            offset = d
        }
        lastArrival = arrival
        return min(sensorTime + (offset ?? d), arrival)
    }
}

/// How a gyroscope rate is applied to the attitude quaternion.
///
/// CoreMotion reports the rotation rate in the device frame, but the attitude quaternion's
/// convention (device→world or world→device) depends on the API, and a sign or frame mix-up
/// would make prediction run backwards. Rather than guess, `GyroConventionDetector` measures
/// which of these four predicts the next sample best.
public enum GyroConvention: Int, CaseIterable, Sendable {
    /// q' = q · Δ(+ω): quaternion maps device→world, rate in the device frame.
    case rightPositive
    case rightNegative
    /// q' = Δ(−ω) · q: quaternion maps world→device, rate in the device frame.
    case leftNegative
    case leftPositive

    /// Attitude after rotating at `rate` (rad/s, device frame) for `dt` seconds.
    public func advance(_ q: Quat, rate: Vec3, dt: Double) -> Quat {
        let speed = rate.length
        guard speed > 1e-9, dt != 0 else { return q }
        let positive = self == .rightPositive || self == .leftPositive
        let delta = Quat(axis: rate / speed, angle: speed * dt * (positive ? 1 : -1))
        switch self {
        case .rightPositive, .rightNegative: return (q * delta).normalized
        case .leftNegative, .leftPositive: return (delta * q).normalized
        }
    }
}

/// Learns which `GyroConvention` a stream uses by comparing each candidate's one-step
/// prediction with the next real attitude. Reports `nil` until the evidence is clear, or if the
/// rotation rate doesn't match the attitude at all (e.g. a sensor that reports zero rate).
public struct GyroConventionDetector: Sendable {
    /// Running relative error per convention (0 = perfect, 1 = no better than not predicting).
    public private(set) var errors: [Double] = Array(repeating: 1, count: GyroConvention.allCases.count)
    public private(set) var evidence = 0

    public static let minimumEvidence = 8
    /// Ignore steps smaller than this (radians); they are mostly noise.
    public static let minimumStep = 0.02

    public init() {}

    public var convention: GyroConvention? {
        guard evidence >= Self.minimumEvidence else { return nil }
        let ranked = GyroConvention.allCases.sorted { errors[$0.rawValue] < errors[$1.rawValue] }
        let best = ranked[0], second = ranked[1]
        let e = errors[best.rawValue]
        guard e < 0.6, e < errors[second.rawValue] * 0.7 else { return nil }
        return best
    }

    public mutating func observe(from a: MotionSample, to b: MotionSample, dt: Double) {
        guard dt > 0.002, dt < 0.12, let ra = a.rotationRate, let rb = b.rotationRate else { return }
        let step = a.attitude.angle(to: b.attitude)
        guard step > Self.minimumStep else { return }
        // Trapezoidal: the average rate over the interval.
        let rate = (ra + rb) * 0.5
        let k = 0.15
        for c in GyroConvention.allCases {
            let predicted = c.advance(a.attitude, rate: rate, dt: dt)
            let rel = min(predicted.angle(to: b.attitude) / step, 3)
            errors[c.rawValue] += (rel - errors[c.rawValue]) * k
        }
        evidence += 1
    }
}

/// Prepares one sensor stream's samples for `SaberPoseFilter`: puts them on the sensor's own
/// timeline and turns the gyroscope rate into the saber's angular velocity in player space.
public struct SensorMotionProcessor: Sendable {
    public private(set) var clock = SensorClock()
    public private(set) var gyro = GyroConventionDetector()
    private var previous: (time: Double, sample: MotionSample)?

    public init() {}

    public mutating func reset() {
        clock.reset()
        previous = nil
    }

    /// - Parameters:
    ///   - sample: `time` is the arrival time; `sensorTime` / `rotationRate` are used when present.
    ///   - direction: maps an attitude to the saber direction (calibration + sensitivity).
    /// - Returns: the local time the sample was measured, and the saber's angular velocity
    ///   (axis × rad/s) once the gyroscope convention is known.
    public mutating func process(_ sample: MotionSample, direction: (Quat) -> Vec3) -> (time: Double, angularVelocity: Vec3?) {
        let t = clock.map(sensorTime: sample.sensorTime, arrival: sample.time)
        if let p = previous {
            gyro.observe(from: p.sample, to: sample, dt: t - p.time)
        }
        previous = (t, sample)

        guard let convention = gyro.convention, let rate = sample.rotationRate else { return (t, nil) }
        // Differentiate through the calibration numerically, so sensitivity and the
        // calibrated basis are handled exactly like the real direction.
        let h = 0.004
        let now = direction(sample.attitude)
        let ahead = direction(convention.advance(sample.attitude, rate: rate, dt: h))
        let angle = now.angle(to: ahead)
        guard angle > 1e-7 else { return (t, .zero) }
        let axis = now.cross(ahead)
        guard axis.length > 1e-12 else { return (t, .zero) }
        return (t, axis.normalized * (angle / h))
    }
}
