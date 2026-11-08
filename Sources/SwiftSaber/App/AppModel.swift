import AppKit
import SwiftUI
import QuartzCore
import SaberCore

enum Screen: Equatable {
    case loading
    case menu
    case levelSelect
    case calibration
    case settings
    case customize
    case countdown
    case playing
    case paused
    case results
}

/// Top-level state machine: owns input, audio, the renderer and the screens.
final class AppModel: ObservableObject {
    @Published var screen: Screen = .loading {
        didSet { if screen != oldValue { updateSaberVisibility() } }
    }
    @Published var loadingProgress: Double = 0
    @Published var hud = HUDSnapshot()
    @Published var results: GameResults?
    @Published var isNewRecord = false
    @Published var countdownValue = 3
    @Published var countdownMessage = ""
    @Published var toast: String?
    @Published var selectedDifficulty: Difficulty = .normal
    @Published var selectedMode: PlayMode = .twoSabers
    @Published var streamInfos: [StreamInfo] = []
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var settings: GameSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applySettings(previous: oldValue)
        }
    }

    let song = SongDefinition.prismRun
    let hub = InputHub()
    let audio = GameAudio()
    let renderer: GameRenderer
    let motion: HeadphoneMotionService
    let phone: PhoneControllerServer
    /// The closed AirPods case as a saber (used when `settings.airPodGrip == .closedCase`).
    let airPodsCase: AirPodsCaseSession
    lazy var calibration = CalibrationModel(hub: hub)

    private var monitors: [Any] = []
    private var statusTimer: Timer?
    private var countdownTimer: Timer?
    private var toastWork: DispatchWorkItem?
    private var cursorHidden = false
    private var resumingFromPause = false
    private var beatmaps: [String: Beatmap] = [:]
    /// Difficulty / mode of the level currently being played.
    private(set) var playing: (difficulty: Difficulty, mode: PlayMode) = (.normal, .twoSabers)
    @Published private(set) var isDemo = false
    /// Set by `--demo-capture <dir>`: plays the demo and saves screenshots there (used by CI).
    var demoCaptureDirectory: URL?

    init() {
        let loaded = GameSettings.load()
        settings = loaded
        renderer = GameRenderer(input: hub, audio: audio, stage: loaded.stage, colors: loaded.effectiveColors)
        motion = HeadphoneMotionService(hub: hub)
        phone = PhoneControllerServer(hub: hub)
        airPodsCase = AirPodsCaseSession(hub: hub)
        // Put back any audio devices a session moved off the AirPods before a crash or force quit.
        CaseAudioGuard.shared.restoreAfterCrash()

        renderer.onHUD = { [weak self] snap in
            guard let self, self.screen == .playing || self.screen == .paused else { return }
            if snap != self.hud { self.hud = snap }
        }
        renderer.onGameOver = { [weak self] r in self?.gameOver(r) }
        // Render thread: buzz the phone when its saber hits something.
        let hub = self.hub, phone = self.phone
        renderer.onSaberContact = { hand, strength in
            if case .stream(.phone)? = hub.currentAssignment()[hand] { phone.sendHaptic(strength) }
        }
        phone.onButton = { [weak self] b in self?.phoneButton(b) }
        phone.onCommand = { [weak self] c in self?.handleRemote(c) }
        audio.onConfigurationChange = { [weak self] in self?.audioConfigurationChanged() }

        calibration.onStepCompleted = { [weak self] in self?.audio.play(.calibrationStep, volume: 0.8) }
        airPodsCase.onStageAdvanced = { [weak self] in
            guard let self else { return }
            self.audio.play(.calibrationStep, volume: 0.6)
            if self.airPodsCase.stage == .ready { self.caseBecameReady() }
        }
        airPodsCase.onNewFrame = { [weak self] in
            // Each connection has its own orientation frame, so the case needs calibrating again.
            guard let self else { return }
            self.hub.setCalibration(nil, for: .airPodCase)
            self.updateAssignment()
        }
        airPodsCase.onEnded = { [weak self] message in self?.airPodsCaseEnded(message) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.airPodsCase.shutdown()
        }
        calibration.onFinished = { [weak self] results in self?.calibrationFinished(results) }
        calibration.onPhaseChanged = { [weak self] _ in
            self?.updateSaberVisibility()
            self?.sendPhoneState()
        }

        applySettings(previous: nil)
        outputDevices = AudioDevices.outputDevices()
        installMonitors()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let infos = self.hub.streamInfos()
            if infos != self.streamInfos { self.streamInfos = infos }
            // The phone is always a remote, even when it isn't one of the sabers.
            self.sendPhoneStatus()
            self.sendPhoneState()
        }
        loadMusic()
    }

    // MARK: Loading

    private func loadMusic() {
        let song = self.song
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let audioData: StereoAudio
            if let cached = MusicCache.load(song: song) {
                audioData = cached
            } else {
                audioData = MusicSynth(song: song).render { p in
                    DispatchQueue.main.async { self?.loadingProgress = p }
                }
                MusicCache.save(audioData, song: song)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.audio.setMusic(audioData)
                self.loadingProgress = 1
                withAnimation(.easeOut(duration: 0.6)) { self.screen = .menu }
                if let dir = self.demoCaptureDirectory { self.runDemoCapture(to: dir) }
            }
        }
    }

    // MARK: Settings

    private func applySettings(previous: GameSettings?) {
        hub.configure(sensitivity: settings.sensitivity, airPodLatency: settings.airPodLatencyMs / 1000)
        audio.userOffset = settings.audioOffsetMs / 1000
        audio.setVolumes(music: settings.musicVolume, sfx: settings.sfxVolume)
        renderer.setVisualOptions(bloom: settings.bloom, cameraShake: settings.cameraShake)
        renderer.setLook(stage: settings.stage, colors: settings.effectiveColors)
        if previous?.audioOutput != settings.audioOutput {
            audio.applyOutput(choice: settings.audioOutput)
        }
        if usesHeadphoneMotion {
            motion.start()
        } else {
            motion.stop()
        }
        airPodsCase.setInvertGravity(settings.invertCaseGravity)
        if !usesAirPodsCase && airPodsCase.isActive { airPodsCase.disconnect() }
        if let previous, previous.invertCaseGravity != settings.invertCaseGravity, hub.calibration(for: .airPodCase) != nil {
            hub.setCalibration(nil, for: .airPodCase)
            showToast("Case saber flipped — calibrate it again in Set Up Sabers")
        }
        // Always listen for the phone so it can drive the menus in every input mode;
        // its motion only reaches the sabers when the input mode uses it.
        phone.forwardsMotion = settings.inputMode.usesPhone
        phone.start()
        if previous?.keepAirPodsAwake != settings.keepAirPodsAwake || previous?.inputMode != settings.inputMode
            || previous?.airPodGrip != settings.airPodGrip {
            // A case session keeps its own silent stream going and holds sound off the AirPods.
            audio.setKeepAirPodsAwake(settings.keepAirPodsAwake && usesHeadphoneMotion)
        }
        updateAssignment()
    }

    func refreshOutputDevices() {
        outputDevices = AudioDevices.outputDevices()
    }

    private func audioConfigurationChanged() {
        // Devices changed (e.g. AirPods connected). Re-route and pause a running song.
        if screen == .playing { pauseGame() }
        audio.applyOutput(choice: settings.audioOutput)
        audio.setVolumes(music: settings.musicVolume, sfx: settings.sfxVolume)
        refreshOutputDevices()
        if usesHeadphoneMotion {
            audio.setKeepAirPodsAwake(false)
            audio.setKeepAirPodsAwake(settings.keepAirPodsAwake)
        }
    }

    /// AirPod motion through Core Motion (a bud in the hand).
    var usesHeadphoneMotion: Bool { settings.inputMode.usesAirPods && settings.airPodGrip == .bud }
    /// AirPod motion from the closed charging case.
    var usesAirPodsCase: Bool { settings.inputMode.usesAirPods && settings.airPodGrip == .closedCase }

    /// Guided setup: once the case streams, go straight into calibration if nothing else is awaited.
    private func caseBecameReady() {
        guard screen == .calibration, calibration.phase == .detecting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.screen == .calibration, self.calibration.phase == .detecting,
                  self.airPodsCase.stage == .ready else { return }
            let live = self.hub.liveStreams()
            guard live.contains(.airPodCase), !self.settings.inputMode.usesPhone || live.contains(.phone) else { return }
            self.calibration.begin()
        }
    }

    private func airPodsCaseEnded(_ message: String?) {
        hub.setCalibration(nil, for: .airPodCase)
        updateAssignment()
        guard let message else { return }
        if screen == .playing { pauseGame() } else if screen == .countdown && !isDemo { quitToMenu() }
        if screen != .calibration {
            showToast(airPodsCase.lostContact ? "AirPods case went quiet — open the lid, then reconnect in Set Up Sabers" : message)
        }
    }

    // MARK: Saber assignment

    var calibratedStreams: [StreamID] {
        StreamID.allCases.filter { hub.calibration(for: $0) != nil }
    }

    var calibratedAirPods: [StreamID] { calibratedStreams.filter { $0.isAirPod } }
    var phoneCalibrated: Bool { hub.calibration(for: .phone) != nil }

    /// Hands that currently have an input source.
    var availableHands: [Hand] {
        Array(hub.currentAssignment().keys).sorted { $0.rawValue < $1.rawValue }
    }

    var needsCalibration: Bool {
        (settings.inputMode.usesAirPods && calibratedAirPods.isEmpty)
            || (settings.inputMode.usesPhone && !phoneCalibrated)
    }

    func updateAssignment() {
        var a: [Hand: SaberSource] = [:]
        let primary = settings.primaryHand
        let pods = calibratedAirPods
        switch settings.inputMode {
        case .mouse:
            a[primary] = .mouse
        case .airpods:
            if pods.contains(.left) && pods.contains(.right) && bothBudsStreaming {
                // Only if this hardware really streams both buds at once.
                a[.left] = .stream(settings.swapAirPods ? .right : .left)
                a[.right] = .stream(settings.swapAirPods ? .left : .right)
            } else if !pods.isEmpty {
                a[primary] = .anyAirPod
            }
        case .airpodAndPhone:
            if !pods.isEmpty { a[primary] = .anyAirPod }
            if phoneCalibrated { a[primary.other] = .stream(.phone) }
        case .phone:
            if phoneCalibrated { a[primary] = .stream(.phone) }
        case .airpodAndMouse:
            if !pods.isEmpty { a[primary] = .anyAirPod }
            a[primary.other] = .mouse
        }
        hub.setAssignment(a)
        let hands = a.count
        if hands < 2 { selectedMode = .oneSaber } else if selectedMode == .oneSaber && screen != .levelSelect { selectedMode = .twoSabers }
        objectWillChange.send()
    }

    // MARK: Calibration

    /// True if left and right buds were both live at the same moment (not just one after another).
    private var bothBudsStreaming: Bool {
        let live = hub.liveStreams()
        return live.contains(.left) && live.contains(.right)
    }

    func openCalibration() {
        if !settings.inputMode.usesMotionDevices { settings.inputMode = .airpodAndPhone }
        if usesHeadphoneMotion { motion.start() }
        if settings.inputMode.usesPhone { phone.start() }
        calibration.restart()
        calibration.activate()
        screen = .calibration
    }

    func closeCalibration() {
        calibration.deactivate()
        screen = .menu
    }

    /// The sabers would swing around wildly (or with a stale calibration) while calibrating,
    /// so they are hidden until calibration is done.
    private func updateSaberVisibility() {
        renderer.setSabersHidden(screen == .calibration && calibration.phase != .done)
    }

    /// Next button (on screen, keyboard or iPhone) during calibration.
    func calibrationNext() {
        calibration.next()
        sendPhoneState()
    }

    private func calibrationFinished(_ results: [StreamID: SaberCalibration]) {
        hub.clearCalibrations()
        for (id, c) in results { hub.setCalibration(c, for: id) }
        updateAssignment()
        audio.play(.clear, volume: 0.7)
    }

    // MARK: iPhone controller

    private func phoneButton(_ b: ControllerButton) {
        // While calibrating, any phone button moves on to the next pose (older phone apps
        // have no NEXT button, so Recenter / Pause work too).
        if screen == .calibration && calibration.phase == .calibrating {
            calibrationNext()
            return
        }
        switch b {
        case .next:
            if screen == .calibration && calibration.phase == .detecting { calibration.begin() }
        case .recenter:
            recenter()
        case .pause:
            switch screen {
            case .playing: pauseGame()
            case .paused: resumeGame()
            case .results: restartLevel()
            case .menu, .levelSelect: if !needsCalibration { startLevel() }
            default: break
            }
        }
    }

    private func sendPhoneStatus() {
        let hand = hub.currentAssignment().first { $0.value == .stream(.phone) }?.key
        phone.sendStatus(hand: hand, calibrated: phoneCalibrated)
    }

    func recenter() {
        hub.recenter()
        renderer.inputTeleported()
        showToast("Recentered — sabers now point where you aimed")
    }

    // MARK: Flow

    func goToLevelSelect() {
        updateAssignment()
        if availableHands.count < 2 { selectedMode = .oneSaber }
        screen = .levelSelect
    }

    func beatmap(_ d: Difficulty, _ m: PlayMode) -> Beatmap {
        let key = "\(d.rawValue)-\(m.rawValue)"
        if let b = beatmaps[key] { return b }
        let b = LevelDesigner.beatmap(song: song, difficulty: d, mode: m)
        beatmaps[key] = b
        return b
    }

    /// Plays the selected level with the autoplay saber driver.
    func startDemo() {
        startLevel(demo: true)
    }

    func startLevel(demo: Bool = false) {
        updateAssignment()
        isDemo = demo
        var mode = selectedMode
        if availableHands.count < 2 && !demo { mode = .oneSaber }
        let map = beatmap(selectedDifficulty, mode)
        playing = (selectedDifficulty, mode)
        let config = SessionConfig(noFail: settings.noFail, cutTolerance: settings.lenientCuts ? 75 : 60,
                                   minimumSwingSpeed: settings.lenientCuts ? 30 : 45)
        // In one-saber mode the saber is whichever hand has input (preferring the primary hand).
        var primary = settings.primaryHand
        if mode == .oneSaber, !availableHands.contains(primary), let h = availableHands.first { primary = h }
        renderer.prepare(beatmap: map, config: config, primaryHand: primary, autoplay: demo)
        hud = HUDSnapshot(duration: map.duration, noFail: settings.noFail, autoplay: demo)
        results = nil
        resumingFromPause = false
        runCountdown(message: demo ? "Autoplay demo" : (settings.autoRecenter && settings.inputMode.usesMotionDevices ? "Aim at the centre of the screen" : "Get ready"))
    }

    private func runCountdown(message: String) {
        countdownTimer?.invalidate()
        countdownValue = 3
        countdownMessage = message
        screen = .countdown
        audio.play(.countdown, volume: 0.7)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.countdownValue > 1 {
                self.countdownValue -= 1
                self.audio.play(.countdown, volume: 0.7)
            } else {
                t.invalidate()
                self.countdownFinished()
            }
        }
    }

    private func countdownFinished() {
        if settings.autoRecenter && settings.inputMode.usesMotionDevices && !isDemo { hub.recenter() }
        audio.play(.go, volume: 0.7)
        if resumingFromPause {
            renderer.resume()
        } else {
            renderer.beginPlayback()
        }
        resumingFromPause = false
        screen = .playing
        hideCursorIfNeeded(true)
    }

    func pauseGame() {
        guard screen == .playing else { return }
        renderer.pause()
        screen = .paused
        hideCursorIfNeeded(false)
    }

    func resumeGame() {
        guard screen == .paused else { return }
        resumingFromPause = true
        runCountdown(message: "Resuming")
    }

    func restartLevel() {
        countdownTimer?.invalidate()
        renderer.returnToMenu()
        startLevel(demo: isDemo)
    }

    func quitToMenu() {
        countdownTimer?.invalidate()
        renderer.returnToMenu()
        hideCursorIfNeeded(false)
        screen = .menu
    }

    private func gameOver(_ r: GameResults) {
        guard screen == .playing || screen == .paused else { return }
        hideCursorIfNeeded(false)
        isNewRecord = isDemo ? false : BestScores.submit(r, playing.difficulty, playing.mode)
        results = r
        renderer.returnToMenu()
        withAnimation(.easeOut(duration: 0.4)) { screen = .results }
    }

    private func hideCursorIfNeeded(_ hide: Bool) {
        let shouldHide = hide && (settings.inputMode == .mouse || settings.inputMode == .airpodAndMouse) && !isDemo
        if shouldHide && !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        } else if !shouldHide && cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation { toast = text }
        let work = DispatchWorkItem { [weak self] in withAnimation { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: Automated capture (CI)

    private func runDemoCapture(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func capture(_ name: String) {
            if let tiff = renderer.snapshot().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("scene-\(name).png"))
            }
            if let window = renderer.view.window {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", dir.appendingPathComponent("window-\(name).png").path]
                try? p.run()
                p.waitUntilExit()
            }
            NSLog("SwiftSaber capture: \(name)")
        }
        let main = DispatchQueue.main
        // Navigation goes through the same remote commands the iPhone sends, so a phone
        // simulator connected during the run shows each screen mirrored. CI watches the log
        // for "phone-shot" lines and screenshots the simulator at each one. Markers are
        // scheduled from each screen change (captures block the main thread for a moment,
        // so absolute times drift).
        func phoneShot(_ name: String, after delay: Double = 1.2) {
            main.asyncAfter(deadline: .now() + delay) { NSLog("SwiftSaber phone-shot: \(name)") }
        }
        phoneShot("menu", after: 2.5)
        main.asyncAfter(deadline: .now() + 4) {
            capture("0-menu")
            self.handleRemote(.openSettings)
            phoneShot("settings")
        }
        main.asyncAfter(deadline: .now() + 8) {
            capture("1-settings")
            self.handleRemote(.back)
            self.handleRemote(.openCustomize)
            phoneShot("customize", after: 1.5)
        }
        // Tour every arena (with its own colours, then with a custom preset) before the demo.
        let originalLook = (self.settings.stage, self.settings.overrideColors, self.settings.customColors)
        var tourTime = 11.0
        for (i, kind) in StageKind.allCases.enumerated() {
            main.asyncAfter(deadline: .now() + tourTime) {
                self.settings.overrideColors = false
                self.handleRemote(.setArena(kind.rawValue))
            }
            main.asyncAfter(deadline: .now() + tourTime + 1.2) {
                capture("arena-\(i)-\(kind.rawValue)")
                self.handleRemote(.previewLights)
            }
            main.asyncAfter(deadline: .now() + tourTime + 1.6) { capture("arena-\(i)-\(kind.rawValue)-flash") }
            tourTime += 2.2
        }
        main.asyncAfter(deadline: .now() + tourTime) {
            self.handleRemote(.applyColorPreset("toxic"))
            phoneShot("customcolors", after: 0.8)
        }
        main.asyncAfter(deadline: .now() + tourTime + 1) { capture("arena-custom-colors") }
        tourTime += 2.5
        main.asyncAfter(deadline: .now() + tourTime) {
            self.settings.stage = originalLook.0
            self.settings.overrideColors = originalLook.1
            self.settings.customColors = originalLook.2
            self.handleRemote(.back)
            self.handleRemote(.openCalibration)
            phoneShot("calibration")
        }
        let t0 = tourTime
        main.asyncAfter(deadline: .now() + t0 + 4) {
            capture("1b-calibration")
            self.handleRemote(.back)
            self.handleRemote(.openLevelSelect)
            self.selectedMode = .twoSabers
            self.handleRemote(.selectDifficulty(Difficulty.expert.rawValue))
            phoneShot("levelselect")
        }
        main.asyncAfter(deadline: .now() + t0 + 8) {
            capture("2-levelselect")
            self.handleRemote(.watchDemo)
            phoneShot("countdown", after: 0.9)
        }
        // Countdown takes ~2.3 s; then song time ≈ wall time.
        let start = t0 + 8 + 2.4
        let shots: [(Double, String)] = [(10, "3-intro"), (24, "4-groove"), (40, "5-build"), (47.5, "6-drop"), (55, "7-drop"), (80, "8-breakdown")]
        for (t, name) in shots {
            main.asyncAfter(deadline: .now() + start + t) { capture(name) }
        }
        main.asyncAfter(deadline: .now() + start + 30) { phoneShot("playing", after: 0) }
        main.asyncAfter(deadline: .now() + start + 82) {
            self.handleRemote(.pause)
            phoneShot("paused")
        }
        main.asyncAfter(deadline: .now() + start + 85) {
            capture("9-paused")
        }
        main.asyncAfter(deadline: .now() + start + 88) {
            if let r = self.renderer.currentResults() {
                self.results = r
                self.renderer.returnToMenu()
                self.screen = .results
            }
            phoneShot("results", after: 1.5)
        }
        main.asyncAfter(deadline: .now() + start + 91) {
            capture("10-results")
        }
        main.asyncAfter(deadline: .now() + start + 95) {
            NSApp.terminate(nil)
        }
    }

    // MARK: Keyboard & mouse

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] e in
            guard let self, let window = self.renderer.view.window, e.window === window else { return e }
            let p = self.renderer.view.convert(e.locationInWindow, from: nil)
            if let aim = self.renderer.aimPoint(viewPoint: p) { self.hub.setMouseTarget(aim) }
            return e
        }
        monitors = [keys as Any, mouse as Any]
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) { return false }
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch e.keyCode {
        case 53: // Escape
            switch screen {
            case .playing: pauseGame()
            case .paused: resumeGame()
            case .levelSelect, .settings, .customize, .results: screen = .menu
            case .calibration: closeCalibration()
            default: return false
            }
            return true
        case 49: // Space
            if screen == .playing { pauseGame(); return true }
            if screen == .paused { resumeGame(); return true }
            if screen == .calibration && calibration.phase == .calibrating { calibrationNext(); return true }
            return false
        case 36, 76: // Return / Enter
            switch screen {
            case .menu: goToLevelSelect()
            case .levelSelect: startLevel()
            case .results: restartLevel()
            case .calibration where calibration.phase == .detecting: calibration.begin()
            case .calibration where calibration.phase == .calibrating: calibrationNext()
            case .calibration where calibration.phase == .done: closeCalibration()
            default: return false
            }
            return true
        default:
            break
        }
        switch key {
        case "r":
            recenter()
            return true
        case "f":
            renderer.view.window?.toggleFullScreen(nil)
            return true
        default:
            return false
        }
    }
}

/// Caches the rendered music so later launches start instantly.
enum MusicCache {
    static func url(song: SongDefinition) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("SwiftSaber", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = song.title.replacingOccurrences(of: " ", with: "_").lowercased()
        return folder.appendingPathComponent("\(name)_v3.pcm")
    }

    static func load(song: SongDefinition) -> StereoAudio? {
        guard let url = url(song: song), let data = try? Data(contentsOf: url) else { return nil }
        let frames = Int(song.duration * 44100)
        guard data.count == frames * 2 * MemoryLayout<Float>.size else { return nil }
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<frames {
                left[i] = f[i]
                right[i] = f[frames + i]
            }
        }
        return StereoAudio(left: left, right: right, sampleRate: 44100)
    }

    static func save(_ a: StereoAudio, song: SongDefinition) {
        guard let url = url(song: song) else { return }
        var data = Data(capacity: a.frameCount * 8)
        a.left.withUnsafeBufferPointer { data.append($0) }
        a.right.withUnsafeBufferPointer { data.append($0) }
        try? data.write(to: url, options: .atomic)
    }
}
