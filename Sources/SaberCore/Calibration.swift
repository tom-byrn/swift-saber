import Foundation

/// One raw orientation sample from a motion sensor (e.g. an AirPod).
public struct MotionSample: Sendable {
    public var time: Double
    /// Attitude quaternion exactly as reported by the sensor.
    public var attitude: Quat
    /// Gravity in the device frame (unit g). May be zero if the sensor does not report it.
    public var gravity: Vec3

    public init(time: Double, attitude: Quat, gravity: Vec3) {
        self.time = time; self.attitude = attitude; self.gravity = gravity
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
///
/// After the "screen" and "ceiling" poses are captured the process waits (`isAwaitingNext`)
/// until `advance()` is called, so the player has time to move to the next pose instead of
/// the next hold starting while they are still in the old one.
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
    /// True once the current step's pose has been captured and the process is waiting for `advance()`.
    public private(set) var isAwaitingNext = false
    /// Largest rotation (degrees) across the recent sample window: how much the hand is moving.
    public private(set) var motionDegrees: Double = 0
    /// Angle (degrees) between the latest sample and the captured screen pose, once there is one.
    public private(set) var degreesFromScreen: Double?
    /// Why the hold is not counting even though the hand is steady (e.g. "Raise higher").
    public private(set) var poseHint: String?
    /// Latest raw sample fed in.
    public private(set) var latest: MotionSample?

    /// How far from the screen pose the ceiling pose must be.
    public static let minimumRaiseDegrees: Double = 45
    /// How close to the screen pose the final "back to centre" pose must be.
    public static let maximumRecenterDegrees: Double = 30

    let holdDuration: Double
    let stillThresholdDegrees: Double
    let waitsForNext: Bool
    private var window: [MotionSample] = []
    private var centerSamples: [MotionSample] = []
    private var upSamples: [MotionSample] = []
    private var stillSince: Double?

    /// - Parameter waitsForNext: when false the process moves straight on to the next step
    ///   after each capture (no `advance()` needed).
    public init(holdDuration: Double = 0.9, stillThresholdDegrees: Double = 5, waitsForNext: Bool = true) {
        self.holdDuration = holdDuration
        self.stillThresholdDegrees = stillThresholdDegrees
        self.waitsForNext = waitsForNext
    }

    public func restart() {
        step = .pointAtScreen
        holdProgress = 0
        result = nil
        isAwaitingNext = false
        motionDegrees = 0
        degreesFromScreen = nil
        poseHint = nil
        latest = nil
        window.removeAll()
        centerSamples.removeAll()
        upSamples.removeAll()
        stillSince = nil
    }

    /// Moves on from a captured pose to the next step. Returns true if the step changed.
    @discardableResult
    public func advance() -> Bool {
        guard isAwaitingNext else { return false }
        isAwaitingNext = false
        holdProgress = 0
        stillSince = nil
        window.removeAll()
        switch step {
        case .pointAtScreen: step = .pointUp
        case .pointUp: step = .confirmCenter
        case .confirmCenter: step = .done
        case .done, .failed: break
        }
        return true
    }

    /// Feeds one sample. Returns true when the step (or waiting state) changed.
    @discardableResult
    public func add(_ s: MotionSample) -> Bool {
        latest = s
        if let c = centerSamples.last {
            degreesFromScreen = degrees(c.attitude.angle(to: s.attitude))
        }
        if case .done = step { return false }
        if case .failed = step { return false }

        window.append(s)
        window.removeAll { s.time - $0.time > 0.6 }

        // Stillness: every sample in the recent window is close to the newest one.
        let maxDev = window.map { degrees($0.attitude.angle(to: s.attitude)) }.max() ?? 0
        motionDegrees = maxDev
        if isAwaitingNext {
            poseHint = nil
            return false
        }
        let isStill = maxDev < stillThresholdDegrees && window.count >= 3

        // The "up" step must be far from the screen pose, and the final step close to it again
        // (otherwise holding still at the ceiling would count as "back to the centre").
        var poseOK = true
        poseHint = nil
        if let fromScreen = degreesFromScreen {
            switch step {
            case .pointUp:
                poseOK = fromScreen > Self.minimumRaiseDegrees
                if !poseOK { poseHint = "Raise higher — point at the ceiling" }
            case .confirmCenter:
                poseOK = fromScreen < Self.maximumRecenterDegrees
                if !poseOK { poseHint = "Point back at the screen" }
            default:
                break
            }
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
        window.removeAll()

        switch step {
        case .pointAtScreen:
            centerSamples = captured
            if let c = centerSamples.last { degreesFromScreen = degrees(c.attitude.angle(to: s.attitude)) }
            capturedPose()
        case .pointUp:
            upSamples = captured
            switch SaberCalibration.solve(center: centerSamples, up: upSamples) {
            case .success(let cal):
                result = cal
                capturedPose()
            case .failure(let f):
                holdProgress = 0
                step = .failed(f.description)
            }
        case .confirmCenter:
            if var r = result, let last = captured.last {
                r.recenter(to: last.attitude)
                result = r
            }
            // Last pose: no need to wait.
            holdProgress = 0
            step = .done
        case .done, .failed:
            break
        }
        return true
    }

    private func capturedPose() {
        holdProgress = 1
        isAwaitingNext = true
        if !waitsForNext { advance() }
    }
}
