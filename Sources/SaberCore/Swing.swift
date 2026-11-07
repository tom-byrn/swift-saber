import Foundation

/// Smooths and predicts a saber direction from irregular, low-rate sensor samples
/// (AirPods report motion at roughly 25 Hz) so the blade renders and collides smoothly at 60-120 fps.
public final class SaberPoseFilter {
    private var last: (t: Double, dir: Vec3, velocity: Vec3?)?
    private var previous: (t: Double, dir: Vec3)?
    private var output: Vec3?
    private var outputTime: Double = 0

    /// Maximum look-ahead used to bridge the gap between sensor samples.
    public var maxPrediction: Double
    /// Exponential smoothing time constant.
    public var smoothing: Double
    /// When > 0, prediction eases out over this time constant once it passes `maxPrediction`
    /// instead of stopping dead (a hard stop makes the blade stall, then jump, on late samples).
    public var predictionTail: Double

    public init(maxPrediction: Double = 0.045, smoothing: Double = 0.022, predictionTail: Double = 0) {
        self.maxPrediction = maxPrediction
        self.smoothing = smoothing
        self.predictionTail = predictionTail
    }

    public var lastSampleTime: Double? { last?.t }

    public func reset() {
        last = nil; previous = nil; output = nil
    }

    /// - Parameter angularVelocity: the direction's angular velocity (axis × rad/s), e.g. from a
    ///   gyroscope. When nil, speed is estimated from the last two samples.
    public func add(time: Double, direction: Vec3, angularVelocity: Vec3? = nil) {
        if let l = last {
            // Late, out-of-order sample: newer data is already in.
            if time < l.t - 1e-4 { return }
            if time - l.t < 1e-4 {
                last = (time, direction.normalized, angularVelocity)
                return
            }
            previous = (l.t, l.dir)
        }
        last = (time, direction.normalized, angularVelocity)
    }

    /// How far ahead (seconds) to extrapolate a sample that is `age` seconds old.
    func lookAhead(_ age: Double) -> Double {
        let a = max(0, age)
        guard predictionTail > 0 else { return min(a, maxPrediction) }
        guard a > maxPrediction else { return a }
        return maxPrediction + predictionTail * (1 - exp(-(a - maxPrediction) / predictionTail))
    }

    public func direction(at now: Double) -> Vec3? {
        guard let l = last else { return nil }
        var target = l.dir
        if maxPrediction > 0 {
            let ahead = lookAhead(now - l.t)
            if let w = l.velocity {
                let speed = w.length
                if speed > 1e-6 {
                    target = Quat(axis: w / speed, angle: min(speed * ahead, 0.6)).rotate(l.dir).normalized
                }
            } else if let p = previous {
                let dt = l.t - p.t
                if dt > 1e-3 && dt < 0.2 {
                    let angle = p.dir.angle(to: l.dir)
                    if angle > 1e-4 {
                        let axis = p.dir.cross(l.dir).normalized
                        let rate = angle / dt
                        target = Quat(axis: axis, angle: min(rate * ahead, 0.6)).rotate(l.dir).normalized
                    }
                }
            }
        }
        guard let o = output else {
            output = target
            outputTime = now
            return target
        }
        let dt = max(0, now - outputTime)
        outputTime = now
        let k = smoothing > 0 ? 1 - exp(-dt / smoothing) : 1
        let next = o.slerpDirection(to: target, k)
        output = next
        return next
    }
}

/// Tracks continuous swing arcs for one saber; used for pre-swing / post-swing scoring
/// and to know which way the blade is moving.
public struct SwingTracker: Sendable {
    public private(set) var previousDirection: Vec3?
    public private(set) var previousTime: Double = 0
    /// Accumulated angle of the current continuous swing, degrees.
    public private(set) var swingAngle: Double = 0
    public private(set) var swingAxis: Vec3?
    /// Smoothed angular speed, degrees per second.
    public private(set) var angularSpeed: Double = 0
    /// Rotation axis of the most recent frame (unit) and its angle in degrees.
    public private(set) var frameAxis: Vec3?
    public private(set) var frameAngle: Double = 0
    private var slowTime: Double = 0

    public static let stillSpeed: Double = 45

    public init() {}

    public mutating func reset() { self = SwingTracker() }

    public mutating func update(direction: Vec3, time: Double) {
        defer {
            previousDirection = direction
            previousTime = time
        }
        guard let prev = previousDirection else { return }
        let dt = max(time - previousTime, 1e-4)
        let angle = degrees(prev.angle(to: direction))
        frameAngle = angle
        let instSpeed = angle / dt
        angularSpeed = angularSpeed * 0.5 + instSpeed * 0.5
        if angle < 1e-3 {
            frameAxis = nil
        } else {
            frameAxis = prev.cross(direction).normalized
        }

        if instSpeed < Self.stillSpeed {
            slowTime += dt
            if slowTime > 0.06 {
                swingAngle = 0
                swingAxis = nil
            }
            return
        }
        slowTime = 0
        guard let a = frameAxis else { return }
        if let s = swingAxis, s.dot(a) > 0.25 {
            swingAngle += angle
            swingAxis = (s * 0.75 + a * 0.25).normalized
        } else {
            swingAngle = angle
            swingAxis = a
        }
    }
}
