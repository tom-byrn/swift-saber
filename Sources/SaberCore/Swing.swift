import Foundation

/// Smooths and predicts a saber direction from irregular, low-rate sensor samples
/// (AirPods report motion at roughly 25 Hz) so the blade renders and collides smoothly at 60-120 fps.
public final class SaberPoseFilter {
    private var last: (t: Double, dir: Vec3)?
    private var previous: (t: Double, dir: Vec3)?
    private var output: Vec3?
    private var outputTime: Double = 0

    /// Maximum look-ahead used to bridge the gap between sensor samples.
    public var maxPrediction: Double
    /// Exponential smoothing time constant.
    public var smoothing: Double

    public init(maxPrediction: Double = 0.045, smoothing: Double = 0.022) {
        self.maxPrediction = maxPrediction
        self.smoothing = smoothing
    }

    public var lastSampleTime: Double? { last?.t }

    public func reset() {
        last = nil; previous = nil; output = nil
    }

    public func add(time: Double, direction: Vec3) {
        if let l = last, time - l.t < 1e-4 {
            last = (time, direction.normalized)
            return
        }
        previous = last
        last = (time, direction.normalized)
    }

    public func direction(at now: Double) -> Vec3? {
        guard let l = last else { return nil }
        var target = l.dir
        if let p = previous, maxPrediction > 0 {
            let dt = l.t - p.t
            if dt > 1e-3 && dt < 0.2 {
                let angle = p.dir.angle(to: l.dir)
                if angle > 1e-4 {
                    let axis = p.dir.cross(l.dir).normalized
                    let rate = angle / dt
                    let ahead = clamp(now - l.t, 0, maxPrediction)
                    target = Quat(axis: axis, angle: min(rate * ahead, 0.6)).rotate(l.dir).normalized
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
