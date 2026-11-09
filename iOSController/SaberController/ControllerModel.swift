import Foundation
import CoreMotion
import Network
import UIKit

/// Streams the iPhone's (or iPad's) motion to the Swift Saber Mac app over the local network.
///
/// 1. Browses Bonjour for `_swiftsaber._udp` (the Mac advertises it while the game runs).
/// 2. Opens a UDP "connection" to the first Mac found (or the one the user picks).
/// 3. Sends attitude + gravity at 100 Hz, plus button taps.
/// 4. Receives which saber it drives (for the colour) and haptic taps on every cut.
/// 5. Works as a remote: mirrors the game's current screen (`RemoteState`) and sends
///    `RemoteCommand`s, so every menu can be driven from the phone.
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
    /// The game's current screen and values; nil until a Mac that supports remote control answers.
    @Published private(set) var remote: RemoteState?
    /// False when the player chose "Remote only": no motion is sent and the device just drives
    /// the menus. Remembered between launches.
    @Published private(set) var wantsSaber: Bool = UserDefaults.standard.object(forKey: ControllerModel.wantsSaberKey) as? Bool ?? true

    private static let wantsSaberKey = "SaberController.wantsSaber"

    /// iPhone or iPad.
    static let kind: ControllerDevice.Kind = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    /// What to call this device in instructions: "phone" or "iPad".
    static var deviceWord: String { kind == .iPad ? "iPad" : "phone" }
    /// Identifies this install to the Mac, so it gets its saber (and calibration) back after reconnecting.
    private static let deviceID: String = {
        let key = "SaberController.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private var hello: ControllerMessage {
        .hello(name: UIDevice.current.name, device: ControllerDevice(kind: Self.kind, id: Self.deviceID, wantsSaber: wantsSaber))
    }
    /// Preview only: freeze the hold-to-pause ring part-way (for screenshots).
    private(set) var previewHoldProgress: Double?

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
    private let light = UIImpactFeedbackGenerator(style: .light)
    /// When the user last changed a value here; incoming state briefly keeps local values so
    /// a slider doesn't jump back before the Mac has applied the change.
    private var lastLocalEdit = Date.distantPast

    /// `--preview-left` / `--preview-right`: show the connected, calibrated screen without a Mac
    /// (used to take screenshots in the simulator, which has no motion sensors).
    static var previewHand: Int8? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-left") { return 0 }
        if args.contains("--preview-right") { return 1 }
        return nil
    }

    /// `--preview <screen>`: also mirror a sample game screen (menu, levelSelect, settings,
    /// calibration, countdown, playing, paused, results). `--preview-hold` freezes the
    /// hold-to-pause ring part-way.
    static var previewScreen: RemoteState.Screen? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return nil }
        return RemoteState.Screen(rawValue: args[i + 1])
    }

    func start() {
        NSLog("SaberRemote fonts: %@", Theme.hasAvenirCondensed ? "Avenir Next Condensed" : "SF Pro Condensed (Avenir Next Condensed not installed)")
        if let h = Self.previewHand {
            hand = h
            calibrated = true
            link = .connected("Tom's MacBook Pro")
            if let screen = Self.previewScreen { remote = Self.sampleState(screen) }
            if ProcessInfo.processInfo.arguments.contains("--preview-hold") { previewHoldProgress = 0.62 }
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        heavy.prepare()
        rigid.prepare()
        if wantsSaber { startMotion() }
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
            NSLog("SaberRemote browse: \(entries.map(\.id))")
            DispatchQueue.main.async {
                guard let self else { return }
                self.macs = entries
                if self.connection == nil, let first = entries.first(where: { $0.id == self.preferredMac }) ?? entries.first {
                    self.connect(to: first)
                }
            }
        }
        b.stateUpdateHandler = { state in NSLog("SaberRemote browser: \(String(describing: state))") }
        b.start(queue: netQueue)
        browser = b
    }

    func connect(to mac: MacEntry) {
        preferredMac = mac.id
        connection?.cancel()
        let c = NWConnection(to: mac.endpoint, using: .udp)
        c.stateUpdateHandler = { [weak self, weak c] state in
            NSLog("SaberRemote connection: \(String(describing: state))")
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.send(self.hello)
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    if self.connection === c {
                        self.connection = nil
                        self.link = .searching
                        self.remote = nil
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
            if case .connected = link {} else { NSLog("SaberRemote first status from \(macName)") }
            lastStatus = Date()
            if self.hand != hand { self.hand = hand }
            if self.calibrated != calibrated { self.calibrated = calibrated }
            if link != .connected(macName.isEmpty ? (preferredMac ?? "Mac") : macName) {
                link = .connected(macName.isEmpty ? (preferredMac ?? "Mac") : macName)
            }
        case let .remoteState(state):
            // Buzz when a calibration pose is captured so the player knows they can move.
            if state.calibration.canAdvance == true, remote?.calibration.canAdvance != true {
                heavy.impactOccurred(intensity: 0.8)
            }
            if remote == nil { NSLog("SaberRemote first remote state: \(state.screen.rawValue)") }
            lastStatus = Date()
            if Date().timeIntervalSince(lastLocalEdit) < 0.4, let current = remote {
                // Keep what the user just set until the Mac has caught up.
                var merged = state
                merged.settings = current.settings
                merged.difficulty = current.difficulty
                merged.mode = current.mode
                if merged.look != nil { merged.look = current.look ?? merged.look }
                if merged != remote { remote = merged }
            } else if state != remote {
                remote = state
            }
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
            remote = nil
            if let first = macs.first(where: { $0.id == preferredMac }) ?? macs.first { connect(to: first) }
        } else if connection == nil, let first = macs.first(where: { $0.id == preferredMac }) ?? macs.first {
            // The last connection failed while the Mac is still advertised; Bonjour won't
            // report a change, so retry here instead of searching forever.
            connect(to: first)
        }
        // Periodic hello so the Mac shows our name even if the first one was lost.
        if case .connected = link { send(hello) }
    }

    // MARK: Sending

    private func send(_ m: ControllerMessage) {
        netQueue.async { [weak self] in
            self?.connection?.send(content: m.encoded(), completion: .idempotent)
        }
    }

    /// Switches between swinging this device as a saber and using it only as a remote.
    func setWantsSaber(_ on: Bool) {
        guard on != wantsSaber else { return }
        wantsSaber = on
        UserDefaults.standard.set(on, forKey: Self.wantsSaberKey)
        light.impactOccurred(intensity: 0.7)
        if on {
            startMotion()
        } else {
            motion.stopDeviceMotionUpdates()
            hand = -1
        }
        send(hello)
    }

    func tap(_ b: ControllerButton) {
        rigid.impactOccurred(intensity: 0.5)
        send(.button(b))
    }

    // MARK: Remote control

    /// Sends a remote command. UDP can drop a datagram, so it goes out twice; the Mac
    /// ignores the copy by its id.
    func send(_ command: RemoteCommand, haptic: Bool = true) {
        if haptic { light.impactOccurred(intensity: 0.7) }
        applyLocally(command)
        let message = ControllerMessage.command(id: UInt32.random(in: 1...UInt32.max), command)
        send(message)
        netQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.connection?.send(content: message.encoded(), completion: .idempotent)
        }
    }

    /// For continuous controls (colour pickers): updates the screen at once but sends at most
    /// ~12 times a second, always ending with the latest value.
    func sendThrottled(_ command: RemoteCommand) {
        applyLocally(command)
        pendingThrottled = command
        guard throttleWork == nil else { return }
        let elapsed = Date().timeIntervalSince(lastThrottledSend)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let c = self.pendingThrottled else { return }
            self.pendingThrottled = nil
            self.throttleWork = nil
            self.lastThrottledSend = Date()
            self.send(c, haptic: false)
        }
        throttleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.08 - elapsed), execute: work)
    }
    private var pendingThrottled: RemoteCommand?
    private var throttleWork: DispatchWorkItem?
    private var lastThrottledSend = Date.distantPast

    /// Strong buzz when the hold-to-pause completes.
    func confirmHaptic() {
        heavy.impactOccurred(intensity: 1)
    }

    /// Updates the mirrored values straight away so toggles and sliders feel instant.
    private func applyLocally(_ c: RemoteCommand) {
        guard var s = remote else { return }
        switch c {
        case .selectDifficulty(let d): s.difficulty = d
        case .selectMode(let m): s.mode = m
        case let .setFlag(flag, on):
            switch flag {
            case .lenientCuts: s.settings.lenientCuts = on
            case .autoRecenter: s.settings.autoRecenter = on
            case .keepAirPodsAwake: s.settings.keepAirPodsAwake = on
            case .bloom: s.settings.bloom = on
            case .cameraShake: s.settings.cameraShake = on
            case .noFail: s.settings.noFail = on
            }
        case let .setValue(key, v):
            switch key {
            case .sensitivity: s.settings.sensitivity = v
            case .airPodLatencyMs: s.settings.airPodLatencyMs = v
            case .musicVolume: s.settings.musicVolume = v
            case .sfxVolume: s.settings.sfxVolume = v
            case .audioOffsetMs: s.settings.audioOffsetMs = v
            }
        case .setArena(let a): s.look?.arena = a
        case .setCustomColors(let on): s.look?.customColors = on
        case let .setColor(slot, hex):
            if var look = s.look, look.colors.indices.contains(slot) {
                look.colors[slot] = hex
                look.customColors = true
                look.presetID = look.presets.first { $0.colors == look.colors }?.id
                s.look = look
            }
        case .applyColorPreset(let id):
            if var look = s.look, let preset = look.presets.first(where: { $0.id == id }) {
                look.colors = preset.colors
                look.customColors = true
                look.presetID = id
                s.look = look
            }
        case .setInputMode(let m): s.settings.inputMode = m
        case .setPrimaryHand(let h): s.settings.primaryHand = h
        case let .setDeviceUsed(id, used):
            guard let i = s.calibration.streams.firstIndex(where: { $0.id == id }) else { return }
            s.calibration.streams[i].used = used
        case .setAudioOutput(let o): s.settings.audioOutput = o
        default: return
        }
        lastLocalEdit = Date()
        remote = s
    }

    // MARK: Preview data

    static func sampleState(_ screen: RemoteState.Screen) -> RemoteState {
        var s = RemoteState()
        s.screen = screen
        s.loadingProgress = 0.6
        s.songTitle = "Prism Run"
        s.songInfo = "Swift Saber · 128 BPM · 2:30"
        s.difficulties = ["Easy", "Normal", "Hard", "Expert"]
        s.difficulty = 3
        s.mode = 0
        s.twoSabersAvailable = true
        s.sabersReady = 2
        s.anyCalibrated = true
        s.phoneIsSaber = true
        s.sabers = [.init(hand: 0, device: "Tom's iPad", symbol: "ipad", ready: true),
                    .init(hand: 1, device: "Left AirPod", symbol: "airpodpro.left", ready: true)]
        s.canSwapHands = true
        s.mapStats = "412 blocks · 18 bombs · 2.9 / sec"
        s.best = "184 220 · A"
        s.countdown = 2
        s.countdownMessage = "Aim at the centre of the screen"
        s.progress = 0.38
        s.timeText = "0:57 / 2:30"
        s.score = 48_315
        s.combo = 86
        var c = RemoteState.Calibration()
        c.phase = .calibrating
        c.title = "Now point at the ceiling"
        c.detail = "Raise both fists so they point straight up, without twisting your wrists. Hold still."
        c.streams = [.init(id: "1", name: "Left AirPod", live: true, progress: 1, done: true, symbol: "airpodpro.left", hand: 1),
                     .init(id: "3", name: "Tom's iPad", live: true, progress: 0.55, done: false, symbol: "ipad", hand: 0)]
        s.calibration = c
        var g = RemoteState.Settings()
        g.inputMode = "automatic"
        g.inputModes = [.init(id: "automatic", title: "Automatic"), .init(id: "airpodAndPhone", title: "AirPod + iPhone / iPad"),
                        .init(id: "twoPhones", title: "Two iPhones / iPads"), .init(id: "phone", title: "iPhone / iPad only"),
                        .init(id: "airpods", title: "AirPod only"), .init(id: "controllers", title: "Game controllers"),
                        .init(id: "airpodAndMouse", title: "AirPod + Mouse"), .init(id: "mouse", title: "Mouse / Trackpad")]
        g.inputDetail = "Uses whatever you connect: AirPods, iPhones and iPads running Swift Saber, or motion game controllers. Two devices give you two sabers. Nothing connected? The mouse works."
        g.primaryHand = 0
        g.sensitivity = 1.15
        g.airPodLatencyMs = 45
        g.lenientCuts = true
        g.autoRecenter = true
        g.keepAirPodsAwake = true
        g.audioOutput = "auto"
        g.audioOutputs = [.init(id: "auto", title: "Mac speakers (recommended)"), .init(id: "system", title: "System default output")]
        g.musicVolume = 0.85
        g.sfxVolume = 0.7
        g.audioOffsetMs = 0
        s.settings = g
        var r = RemoteState.Results()
        r.headline = "LEVEL CLEARED"
        r.rank = "S"
        r.score = 201_874
        r.accuracy = 0.846
        r.newRecord = true
        r.maxCombo = 173
        r.goodCuts = 398
        r.totalNotes = 412
        r.misses = 9
        s.results = r
        var look = RemoteState.Look()
        look.arena = "neonSkyline"
        look.arenas = [
            .init(id: "prismHall", title: "Prism Hall", tagline: "A mirrored runway through spinning prism rings and laser fans.", symbol: "octagon", swatch: ["#FF2640", "#2E8CFF"]),
            .init(id: "sunsetDrive", title: "Sunset Drive", tagline: "Race down a neon grid towards a striped retro sun.", symbol: "sun.horizon", swatch: ["#FF3CC8", "#28E1FF"]),
            .init(id: "warpTunnel", title: "Warp Tunnel", tagline: "A twisting tunnel of light frames streaking through hyperspace.", symbol: "tornado", swatch: ["#FF5A14", "#3CC8FF"]),
            .init(id: "neonSkyline", title: "Neon Skyline", tagline: "Rooftop runway above a glowing city, searchlights in the sky.", symbol: "building.2", swatch: ["#FF7828", "#B43CFF"]),
            .init(id: "orbit", title: "Orbit", tagline: "A platform in deep space, circled by giant gyroscope rings.", symbol: "globe", swatch: ["#FFB428", "#14DCC8"]),
        ]
        look.customColors = true
        look.colors = ["#FF3CC8", "#28E1FF", "#FF3CC8", "#28E1FF"]
        look.presets = [
            .init(id: "classic", name: "Classic", colors: ["#FF2940", "#2E8CFF", "#FF2940", "#2E8CFF"]),
            .init(id: "synthwave", name: "Synthwave", colors: ["#FF3CC8", "#28E1FF", "#FF3CC8", "#28E1FF"]),
            .init(id: "fireice", name: "Fire & Ice", colors: ["#FF5A14", "#3CC8FF", "#FF5A14", "#3CC8FF"]),
            .init(id: "toxic", name: "Toxic", colors: ["#7CFF32", "#B43CFF", "#7CFF32", "#B43CFF"]),
            .init(id: "sunset", name: "Sunset", colors: ["#FF7828", "#B43CFF", "#FF7828", "#B43CFF"]),
            .init(id: "goldteal", name: "Gold & Teal", colors: ["#FFB428", "#14DCC8", "#FFB428", "#14DCC8"]),
        ]
        look.presetID = "synthwave"
        s.look = look
        return s
    }
}
