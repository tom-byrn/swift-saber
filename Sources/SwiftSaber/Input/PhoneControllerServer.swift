import Foundation
import Network
import QuartzCore
import SaberCore

/// Receives motion from the Swift Saber app on iPhones and iPads over the local network.
///
/// The Mac advertises `_swiftsaber._udp` with Bonjour; each device finds it, connects and
/// streams attitude + gravity at ~100 Hz. Up to two devices drive sabers, as the `.phone` and
/// `.phone2` streams, so calibration, smoothing and collisions work exactly like an AirPod.
/// Any number of devices can be connected at once: the rest (and any set to "Remote only")
/// work as remotes.
final class PhoneControllerServer: ObservableObject {
    enum Status: Equatable {
        case off
        case waiting
        case connected(name: String)
        case failed(String)
    }

    /// One connected iPhone or iPad.
    struct Device: Identifiable, Equatable {
        /// Stable id from the app (or its name, for older apps).
        var id: String
        var name: String
        var kind: ControllerDevice.Kind
        /// The saber stream it streams as, if it has one.
        var slot: StreamID?
        /// False when the player set it to "Remote only".
        var wantsSaber: Bool

        var symbol: String { kind.symbol }
    }

    @Published private(set) var status: Status = .off
    /// Every connected device, saber slots first.
    @Published private(set) var devices: [Device] = []

    /// Called on the main thread when a device's Recenter / Pause / Next buttons are tapped.
    var onButton: ((ControllerButton) -> Void)?
    /// Called on the main thread for each remote-control command from a device.
    var onCommand: ((RemoteCommand) -> Void)?
    /// Called on the main thread when a saber slot is taken by a different device than last time,
    /// so its calibration (which belongs to the old device) must be dropped.
    var onSlotOwnerChanged: ((StreamID) -> Void)?

    /// Whether device motion drives sabers. The server keeps running in every input mode so
    /// the devices always work as remotes, but their motion is ignored unless the input mode
    /// uses them (otherwise they would join calibration as stray streams).
    var forwardsMotion: Bool {
        get { queue.sync { forwardsMotionValue } }
        set { queue.async { self.forwardsMotionValue = newValue } }
    }
    private var forwardsMotionValue = true
    /// Recent command ids, to drop the duplicate copies the devices send.
    private var recentCommandIDs: [UInt32] = []

    private final class Client {
        let connection: NWConnection
        /// Until the first hello: the endpoint.
        var identity: String
        var name = "iPhone"
        var kind: ControllerDevice.Kind = .iPhone
        var wantsSaber = true
        var helloReceived = false
        var slot: StreamID?
        var lastPacket: Double = CACurrentMediaTime()
        init(connection: NWConnection) {
            self.connection = connection
            identity = "\(connection.endpoint)"
        }
    }

    private let hub: InputHub
    private let queue = DispatchQueue(label: "SwiftSaber.PhoneController", qos: .userInteractive)
    private var listener: NWListener?
    /// Network-queue state.
    private var clients: [ObjectIdentifier: Client] = [:]
    /// Which device last held each saber slot, so a reconnecting device gets its slot (and its
    /// calibration) back.
    private var slotOwners: [StreamID: String] = [:]
    private var watchdog: Timer?

    /// A device that sent nothing for this long is gone.
    private static let timeout: Double = 3

    init(hub: InputHub) {
        self.hub = hub
    }

    var isConnected: Bool { !devices.isEmpty }

    /// The device streaming as `slot`, if any.
    func device(for slot: StreamID) -> Device? { devices.first { $0.slot == slot } }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// Bonjour instance names are limited to 63 bytes of UTF-8; a longer name (e.g. an
    /// auto-generated host name) makes registration fail silently while the listener still
    /// reports ready, so the phone never finds the game.
    static var serviceName: String {
        var name = macName
        while name.utf8.count > 63 { name.removeLast() }
        return name.isEmpty ? "Swift Saber" : name
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: Self.serviceName, type: ControllerProtocol.bonjourType)
            l.serviceRegistrationUpdateHandler = { change in
                NSLog("PhoneController Bonjour: \(String(describing: change))")
            }
            NSLog("PhoneController advertising \"\(Self.serviceName)\" (\(Self.macName.utf8.count) bytes)")
            l.stateUpdateHandler = { [weak self] state in
                NSLog("PhoneController listener: \(String(describing: state)) port \(String(describing: l.port))")
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
            NSLog("PhoneController listener failed to start: \(error)")
            status = .failed(error.localizedDescription)
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.dropSilentClients() }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        queue.async {
            for c in self.clients.values { c.connection.cancel() }
            self.clients.removeAll()
            self.publish()
        }
        listener?.cancel()
        listener = nil
        status = .off
    }

    // MARK: Connections (network queue)

    private func accept(_ c: NWConnection) {
        NSLog("PhoneController new connection from \(c.endpoint)")
        let client = Client(connection: c)
        clients[ObjectIdentifier(c)] = client
        c.stateUpdateHandler = { [weak self, weak c] state in
            NSLog("PhoneController connection: \(String(describing: state))")
            guard let self, let c else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.remove(c) }
            default:
                break
            }
        }
        c.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = ControllerMessage.decode(data), let client = self.clients[ObjectIdentifier(c)] {
                self.handle(message, from: client)
            }
            if error == nil, self.clients[ObjectIdentifier(c)] != nil {
                self.receive(on: c)
            }
        }
    }

    private func remove(_ c: NWConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        c.cancel()
        publish()
    }

    private func dropSilentClients() {
        let now = CACurrentMediaTime()
        let silent = clients.values.filter { now - $0.lastPacket > Self.timeout }
        guard !silent.isEmpty else { return }
        for client in silent {
            NSLog("PhoneController \(client.name) went quiet")
            clients[ObjectIdentifier(client.connection)] = nil
            client.connection.cancel()
        }
        publish()
    }

    private func handle(_ m: ControllerMessage, from client: Client) {
        let now = CACurrentMediaTime()
        client.lastPacket = now
        switch m {
        case let .motion(_, attitude, gravity):
            guard forwardsMotionValue, client.wantsSaber, let slot = slot(for: client) else { break }
            hub.ingest(stream: slot, sample: MotionSample(time: now, attitude: attitude, gravity: gravity))
        case let .hello(name, device):
            let identity = device?.id ?? name
            var changed = !client.helloReceived || client.name != name || client.identity != identity
            if changed { NSLog("PhoneController hello from \(name) (\(device?.kind.title ?? "older app"))") }
            if identity != client.identity {
                // The same device on a new connection (it reconnected): drop the old one.
                for (key, other) in clients where other !== client && other.identity == identity {
                    other.connection.cancel()
                    clients[key] = nil
                    changed = true
                }
            }
            client.identity = identity
            client.name = name
            client.kind = device?.kind ?? .iPhone
            client.helloReceived = true
            let wantsSaber = device?.wantsSaber ?? true
            if wantsSaber != client.wantsSaber {
                client.wantsSaber = wantsSaber
                if !wantsSaber { client.slot = nil }
                changed = true
            }
            if changed { publish() }
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
    }

    /// The saber slot a device streams as, taking a free one if it has none yet. Waits for the
    /// first hello so the slot is tied to the right device.
    private func slot(for client: Client) -> StreamID? {
        if let slot = client.slot { return slot }
        guard client.helloReceived else { return nil }
        let taken = Set(clients.values.compactMap(\.slot))
        let free = StreamID.phones.filter { !taken.contains($0) }
        // Its own slot from last time if it's free; then one no other device has calibrated;
        // otherwise the first free one.
        guard let slot = free.first(where: { slotOwners[$0] == client.identity })
                ?? free.first(where: { slotOwners[$0] == nil }) ?? free.first else { return nil }
        client.slot = slot
        if let previous = slotOwners[slot], previous != client.identity {
            DispatchQueue.main.async { self.onSlotOwnerChanged?(slot) }
        }
        slotOwners[slot] = client.identity
        publish()
        return slot
    }

    /// Mirrors the client list to the main thread.
    private func publish() {
        let sortedList = clients.values
            .filter(\.helloReceived)
            .map { Device(id: $0.identity, name: $0.name, kind: $0.kind, slot: $0.slot, wantsSaber: $0.wantsSaber) }
            .sorted { ($0.slot?.rawValue ?? 99, $0.name) < ($1.slot?.rawValue ?? 99, $1.name) }
        // Recent iOS versions report a generic name ("iPhone") to apps, so two devices can share
        // one: number the second.
        var seen: [String: Int] = [:]
        let list = sortedList.map { d -> Device in
            var d = d
            let n = (seen[d.name] ?? 0) + 1
            seen[d.name] = n
            if n > 1 { d.name += " \(n)" }
            return d
        }
        DispatchQueue.main.async {
            if list != self.devices { self.devices = list }
            let status: Status
            if let first = list.first {
                status = .connected(name: list.count > 1 ? list.map(\.name).joined(separator: " + ") : first.name)
            } else if self.listener != nil {
                status = .waiting
            } else {
                status = .off
            }
            if case .failed = self.status, list.isEmpty { return }
            if status != self.status { self.status = status }
        }
    }

    // MARK: Mac → devices

    private func send(_ m: ControllerMessage, where include: @escaping (Client) -> Bool = { _ in true }) {
        queue.async {
            let data = m.encoded()
            for c in self.clients.values where include(c) {
                c.connection.send(content: data, completion: .idempotent)
            }
        }
    }

    /// Tells each device which saber it drives so it can show the right colour.
    func sendStatus(hands: [StreamID: Hand], calibrated: Set<StreamID>) {
        queue.async {
            for c in self.clients.values {
                let hand: Int8 = c.slot.flatMap { hands[$0] }.map { Int8($0.rawValue) } ?? -1
                let isCalibrated = c.slot.map { calibrated.contains($0) } ?? false
                let m = ControllerMessage.status(hand: hand, calibrated: isCalibrated, macName: Self.macName)
                c.connection.send(content: m.encoded(), completion: .idempotent)
            }
        }
    }

    /// Mirrors the current screen on every device. `isSaber` says, per slot, whether that
    /// device drives a saber (the others are told they are remotes).
    func sendState(_ state: RemoteState, isSaber: @escaping (StreamID?) -> Bool) {
        guard isConnected else { return }
        queue.async {
            var asSaber = state, asRemote = state
            asSaber.phoneIsSaber = true
            asRemote.phoneIsSaber = false
            let saberData = ControllerMessage.remoteState(asSaber).encoded()
            let remoteData = ControllerMessage.remoteState(asRemote).encoded()
            for c in self.clients.values {
                let data = c.wantsSaber && isSaber(c.slot) ? saberData : remoteData
                c.connection.send(content: data, completion: .idempotent)
            }
        }
    }

    /// Buzzes the device streaming as `slot`.
    func sendHaptic(_ intensity: Float, slot: StreamID) {
        send(.haptic(intensity: intensity)) { $0.slot == slot }
    }
}
