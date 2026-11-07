import Foundation
import CoreMotion
import Network
import UIKit

/// Streams the iPhone's motion to the Swift Saber Mac app over the local network.
///
/// 1. Browses Bonjour for `_swiftsaber._udp` (the Mac advertises it while the game runs).
/// 2. Opens a UDP "connection" to the first Mac found (or the one the user picks).
/// 3. Sends attitude + gravity at 100 Hz, plus button taps.
/// 4. Receives which saber it drives (for the colour) and haptic taps on every cut.
final class ControllerModel: ObservableObject {
    enum LinkState: Equatable {
        case searching
        case connecting(String)
        case connected(String)
    }

    struct MacEntry: Identifiable, Equatable {
        let id: String
        let endpoint: NWEndpoint
        static func == (a: MacEntry, b: MacEntry) -> Bool { a.id == b.id }
    }

    @Published private(set) var link: LinkState = .searching
    @Published private(set) var macs: [MacEntry] = []
    /// -1 = not assigned, 0 = left (red), 1 = right (blue).
    @Published private(set) var hand: Int8 = -1
    @Published private(set) var calibrated = false
    @Published private(set) var motionAvailable = true
    @Published private(set) var lastHit: Date = .distantPast
    /// The Mac is running saber calibration.
    @Published private(set) var calibrating = false
    /// The current pose is captured: NEXT moves calibration on.
    @Published private(set) var canAdvance = false
    @Published private(set) var calibrationPrompt = ""

    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let netQueue = DispatchQueue(label: "SaberController.net", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var sequence: UInt32 = 0
    private var lastStatus = Date.distantPast
    private var preferredMac: String?
    private var watchdog: Timer?
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// `--preview-left` / `--preview-right`: show the connected, calibrated screen without a Mac
    /// (used to take screenshots in the simulator, which has no motion sensors).
    static var previewHand: Int8? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-left") { return 0 }
        if args.contains("--preview-right") { return 1 }
        return nil
    }

    func start() {
        if let h = Self.previewHand {
            hand = h
            calibrated = true
            link = .connected("Tom's MacBook Pro")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        heavy.prepare()
        rigid.prepare()
        startMotion()
        startBrowsing()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        motion.stopDeviceMotionUpdates()
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        watchdog?.invalidate()
    }

    // MARK: Motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            motionAvailable = false
            return
        }
        guard !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100
        // The magnetometer-corrected frame keeps "forward" from drifting.
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
        motion.startDeviceMotionUpdates(using: frame, to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let q = dm.attitude.quaternion
            let g = dm.gravity
            self.sequence &+= 1
            let msg = ControllerMessage.motion(sequence: self.sequence,
                                               attitude: Quat(x: q.x, y: q.y, z: q.z, w: q.w),
                                               gravity: Vec3(g.x, g.y, g.z))
            self.send(msg)
        }
    }

    // MARK: Discovery

    private func startBrowsing() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: ControllerProtocol.bonjourType, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let entries: [MacEntry] = results.compactMap { r in
                if case let .service(name, _, _, _) = r.endpoint { return MacEntry(id: name, endpoint: r.endpoint) }
                return nil
            }.sorted { $0.id < $1.id }
            DispatchQueue.main.async {
                guard let self else { return }
                self.macs = entries
                if self.connection == nil, let first = entries.first(where: { $0.id == self.preferredMac }) ?? entries.first {
                    self.connect(to: first)
                }
            }
        }
        b.start(queue: netQueue)
        browser = b
    }

    func connect(to mac: MacEntry) {
        preferredMac = mac.id
        connection?.cancel()
        let c = NWConnection(to: mac.endpoint, using: .udp)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.send(.hello(name: UIDevice.current.name))
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    if self.connection === c {
                        self.connection = nil
                        self.link = .searching
                    }
                }
            default:
                break
            }
        }
        connection = c
        link = .connecting(mac.id)
        lastStatus = Date()
        c.start(queue: netQueue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let m = ControllerMessage.decode(data) {
                DispatchQueue.main.async { self.handle(m) }
            }
            if error == nil { self.receive(on: c) }
        }
    }

    private func handle(_ m: ControllerMessage) {
        switch m {
        case let .status(hand, calibrated, macName):
            lastStatus = Date()
            if self.hand != hand { self.hand = hand }
            if self.calibrated != calibrated { self.calibrated = calibrated }
            if link != .connected(macName.isEmpty ? (preferredMac ?? "Mac") : macName) {
                link = .connected(macName.isEmpty ? (preferredMac ?? "Mac") : macName)
            }
        case let .calibration(active, canAdvance, prompt):
            if calibrating != active { calibrating = active }
            if self.canAdvance != canAdvance {
                self.canAdvance = canAdvance
                // Buzz when the pose is captured so the player knows they can move.
                if canAdvance { heavy.impactOccurred(intensity: 0.8) }
            }
            if calibrationPrompt != prompt { calibrationPrompt = prompt }
        case let .haptic(intensity):
            if intensity >= 0.9 {
                heavy.impactOccurred(intensity: 1)
            } else {
                rigid.impactOccurred(intensity: CGFloat(max(0.3, intensity)))
            }
            rigid.prepare()
            lastHit = Date()
        default:
            break
        }
    }

    /// Reconnects if the Mac went quiet (game closed, Wi-Fi changed…).
    private func tick() {
        if connection != nil, Date().timeIntervalSince(lastStatus) > 4 {
            connection?.cancel()
            connection = nil
            link = .searching
            hand = -1
            calibrating = false
            canAdvance = false
            if let first = macs.first(where: { $0.id == preferredMac }) ?? macs.first { connect(to: first) }
        } else if connection == nil, let first = macs.first(where: { $0.id == preferredMac }) ?? macs.first {
            // The last connection failed while the Mac is still advertised; Bonjour won't
            // report a change, so retry here instead of searching forever.
            connect(to: first)
        }
        // Periodic hello so the Mac shows our name even if the first one was lost.
        if case .connected = link { send(.hello(name: UIDevice.current.name)) }
    }

    // MARK: Sending

    private func send(_ m: ControllerMessage) {
        netQueue.async { [weak self] in
            self?.connection?.send(content: m.encoded(), completion: .idempotent)
        }
    }

    func tap(_ b: ControllerButton) {
        rigid.impactOccurred(intensity: 0.5)
        send(.button(b))
    }
}
