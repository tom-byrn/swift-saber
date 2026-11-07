import Foundation
import CoreMotion
import QuartzCore
import SaberCore

/// Identifies a motion stream coming from the AirPods.
/// AirPods tag each sample with the bud that produced it (left / right).
enum StreamID: Int, Codable, CaseIterable, Comparable {
    case unknown = 0
    case left = 1
    case right = 2
    /// The iPhone "Saber Controller" app.
    case phone = 3

    var label: String {
        switch self {
        case .unknown: return "AirPods"
        case .left: return "Left AirPod"
        case .right: return "Right AirPod"
        case .phone: return "iPhone"
        }
    }

    var isAirPod: Bool { self != .phone }
    static let airPods: [StreamID] = [.unknown, .left, .right]

    static func < (a: StreamID, b: StreamID) -> Bool { a.rawValue < b.rawValue }
}

/// Wraps `CMHeadphoneMotionManager` and forwards every sample to the input hub.
final class HeadphoneMotionService: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    enum Status: Equatable {
        case unavailable
        case denied
        case waitingForAirPods
        case connected
    }

    @Published private(set) var status: Status = .waitingForAirPods
    @Published private(set) var lastError: String?

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "SwiftSaber.HeadphoneMotion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let hub: InputHub
    private var running = false

    init(hub: InputHub) {
        self.hub = hub
        super.init()
        manager.delegate = self
    }

    var isDeviceMotionAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard !running else { return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status = .denied
            return
        default:
            break
        }
        guard manager.isDeviceMotionAvailable else {
            status = .unavailable
            return
        }
        running = true
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
                if CMHeadphoneMotionManager.authorizationStatus() == .denied {
                    DispatchQueue.main.async { self.status = .denied }
                }
                return
            }
            guard let motion else { return }
            let stream: StreamID
            switch motion.sensorLocation {
            case .headphoneLeft: stream = .left
            case .headphoneRight: stream = .right
            default: stream = .unknown
            }
            let q = motion.attitude.quaternion
            let g = motion.gravity
            let r = motion.rotationRate
            let sample = MotionSample(
                time: CACurrentMediaTime(),
                attitude: Quat(x: q.x, y: q.y, z: q.z, w: q.w),
                gravity: Vec3(g.x, g.y, g.z),
                sensorTime: motion.timestamp,
                rotationRate: Vec3(r.x, r.y, r.z)
            )
            self.hub.ingest(stream: stream, sample: sample)
        }
    }

    func stop() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
    }

    /// Restarts updates (useful after the AirPods reconnect).
    func restart() {
        stop()
        start()
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { self.status = .connected }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { self.status = .waitingForAirPods }
    }
}
