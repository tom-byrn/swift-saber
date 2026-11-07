import Foundation
import Network
import QuartzCore
import SaberCore

/// Receives motion from the Swift Saber iPhone app over the local network.
///
/// The Mac advertises `_swiftsaber._udp` with Bonjour; the phone finds it, connects and
/// streams attitude + gravity at ~100 Hz. Samples go into the `InputHub` as the `.phone`
/// stream, so calibration, smoothing and collisions work exactly like an AirPod.
final class PhoneControllerServer: ObservableObject {
    enum Status: Equatable {
        case off
        case waiting
        case connected(name: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    /// Called on the main thread when the phone's Recenter / Pause buttons are tapped.
    var onButton: ((ControllerButton) -> Void)?
    /// Called on the main thread for each remote-control command from the phone.
    var onCommand: ((RemoteCommand) -> Void)?

    /// Whether phone motion drives a saber. The server keeps running in every input mode so
    /// the phone always works as a remote, but its motion is ignored unless it is a saber
    /// (otherwise it would join calibration as a stray stream).
    var forwardsMotion: Bool {
        get { queue.sync { forwardsMotionValue } }
        set { queue.async { self.forwardsMotionValue = newValue } }
    }
    private var forwardsMotionValue = true
    /// Recent command ids, to drop the duplicate copies the phone sends.
    private var recentCommandIDs: [UInt32] = []

    private let hub: InputHub
    private let queue = DispatchQueue(label: "SwiftSaber.PhoneController", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var lastPacket: Double = 0
    private var phoneName = "iPhone"
    private var watchdog: Timer?

    init(hub: InputHub) {
        self.hub = hub
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: Self.macName, type: ControllerProtocol.bonjourType)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if !self.isConnected { self.status = .waiting }
                    case .failed(let e):
                        self.status = .failed(e.localizedDescription)
                        self.listener = nil
                    default:
                        break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
            status = .waiting
        } catch {
            status = .failed(error.localizedDescription)
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkTimeout() }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        status = .off
    }

    // MARK: Connection

    private func accept(_ c: NWConnection) {
        // One controller at a time: the newest phone wins.
        connection?.cancel()
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            if case .failed = state, let c, self?.connection === c {
                DispatchQueue.main.async { self?.status = .waiting }
            }
        }
        c.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = ControllerMessage.decode(data) {
                self.handle(message)
            }
            if error == nil, self.connection === c {
                self.receive(on: c)
            }
        }
    }

    /// Runs on the network queue.
    private func handle(_ m: ControllerMessage) {
        let now = CACurrentMediaTime()
        var wasIdle = now - lastPacket > 2
        lastPacket = now
        switch m {
        case let .motion(_, attitude, gravity):
            if forwardsMotionValue {
                hub.ingest(stream: .phone, sample: MotionSample(time: now, attitude: attitude, gravity: gravity))
            }
        case let .hello(name):
            // Motion usually arrives before the first hello, so refresh the shown name.
            if name != phoneName { wasIdle = true }
            phoneName = name
        case let .button(b):
            DispatchQueue.main.async { self.onButton?(b) }
        case let .command(id, command):
            guard !recentCommandIDs.contains(id) else { break }
            recentCommandIDs.append(id)
            if recentCommandIDs.count > 32 { recentCommandIDs.removeFirst() }
            DispatchQueue.main.async { self.onCommand?(command) }
        case .status, .haptic, .remoteState:
            break // Mac → phone only
        }
        if wasIdle || !isConnectedSnapshot {
            let name = phoneName
            DispatchQueue.main.async { self.status = .connected(name: name) }
            isConnectedSnapshot = true
        }
    }

    private var isConnectedSnapshot = false

    private func checkTimeout() {
        let idle = queue.sync { CACurrentMediaTime() - lastPacket }
        if isConnected && idle > 2 {
            status = .waiting
            queue.async { self.isConnectedSnapshot = false }
        }
    }

    // MARK: Mac → phone

    func send(_ m: ControllerMessage) {
        queue.async {
            self.connection?.send(content: m.encoded(), completion: .idempotent)
        }
    }

    /// Tells the phone which saber it drives so it can show the right colour.
    func sendStatus(hand: Hand?, calibrated: Bool) {
        let h: Int8 = hand.map { Int8($0.rawValue) } ?? -1
        send(.status(hand: h, calibrated: calibrated, macName: Self.macName))
    }

    /// Mirrors the current screen on the phone. Skips the send while no phone is connected.
    func sendState(_ state: RemoteState) {
        guard isConnected else { return }
        send(.remoteState(state))
    }

    func sendHaptic(_ intensity: Float) {
        send(.haptic(intensity: intensity))
    }
}
