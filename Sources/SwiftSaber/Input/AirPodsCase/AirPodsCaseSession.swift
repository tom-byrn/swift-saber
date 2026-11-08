import AppKit
import QuartzCore
import SaberCore

/// Turns the closed AirPods charging case into a saber.
///
/// Runs AirPointer's two helpers (see Helpers/AirPodsCase): `ClosedCaseRestore` brings the
/// AirPods' Bluetooth link up, then `ClosedCaseMotion` opens their motion channel while the lid
/// is open, keeps the shut case awake and streams accelerometer and gyro rows over a pipe.
/// Those rows are fused into an orientation here and fed to the input hub as `.airPodCase`.
///
/// The connection walks through the stages of `Stage`; the setup screen shows each one.
/// After the flow follows AirPointer's ClosedCaseSession (MIT License, Copyright (c) 2026 Andy Gao).
final class AirPodsCaseSession: ObservableObject {
    enum Stage: Equatable {
        case off
        /// Asking for Bluetooth and finding the AirPods.
        case preparing
        /// Waiting for the lid to open.
        case openLid
        /// Reconnecting and opening the motion channel (lid open).
        case connecting
        /// Motion is flowing with the lid open; the lid has to close.
        case closeLid
        /// Lid closed; the gyro's resting offset is being measured.
        case holdStill
        /// Lid closed, waiting for the case to answer.
        case linking
        /// Motion is reaching the saber.
        case ready

        var isActive: Bool { self != .off }
    }

    @Published private(set) var stage: Stage = .off
    /// Fill of the "set it down" ring, 0...1.
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var holdMoving = false
    /// Why the last connection ended, in the player's words (nil after a requested stop).
    @Published private(set) var problem: String?
    @Published private(set) var pairTitle: String?
    /// True when motion went quiet mid-session (the case fell asleep or the 30-minute limit hit).
    @Published private(set) var lostContact = false
    @Published private(set) var connectedSince: Date?

    /// A new connection starts a new orientation frame, so any calibration of the old one is void.
    var onNewFrame: (() -> Void)?
    var onEnded: ((String?) -> Void)?
    /// The step chime.
    var onStageAdvanced: (() -> Void)?

    private let hub: InputHub
    private let bluetooth = CaseBluetoothAccess()
    private var lidWatcher: CaseLidWatcher?
    private var lidTimeout: Timer?
    private var restore: Process?
    private var helper: Process?
    private var motionSource: DispatchSourceRead?
    private var motionHandle: FileHandle?
    private var helperLog: FileHandle?
    private var sessionFolder: URL?
    private var capture: URL? { sessionFolder?.appendingPathComponent("recording", isDirectory: true) }
    private var timer: Timer?
    private var silentOutput: PointerSilentOutput?
    private var activity: NSObjectProtocol?
    private var pair: CaseAirPods?

    private var preparing = false, preparation = 0
    private var stopping = false, stoppedAt = 0.0, signalled = false, userEnded = false
    private var connected = false, baselineReady = false, confirmed = false, held = false
    private var closedAt = 0.0, startedAt = 0.0, helperStartedAt = 0.0, lastLease = 0.0, lastStatusRead = 0.0
    private var busyRetries = 0, everReady = false
    private var feedError: String?
    private var savedMeasure = 0, lastOffsetSave = 0.0

    // Touched on the motion queue; guarded by `lock`.
    private let lock = NSLock()
    private let motionQueue = DispatchQueue(label: "SwiftSaber.AirPodsCase.motion", qos: .userInteractive)
    private var fusion = CaseOrientation()
    private var lines = CaseMotionLineBuffer()
    private var forwarding = false
    private var invertGravity = false
    private var lastHost = 0.0
    private var lastStage: Stage = .off

    static let keptSessions = 5

    init(hub: InputHub) {
        self.hub = hub
    }

    var isActive: Bool { preparing || restore?.isRunning == true || helper?.isRunning == true }

    func setInvertGravity(_ on: Bool) {
        lock.lock(); invertGravity = on; lock.unlock()
    }

    // MARK: Control

    /// Starts a connection: finds the AirPods, waits for the lid if they aren't connected, then
    /// runs the helpers.
    func connect() {
        guard !isActive else { return }
        preparing = true
        preparation += 1
        userEnded = false
        lostContact = false
        problem = nil
        feedError = nil
        busyRetries = 0
        everReady = false
        CaseAudioGuard.shared.sessionStarted(target: CaseFiles.savedTarget)
        updateStage()
        let token = preparation
        bluetooth.request { [weak self] allowed in
            guard let self, self.preparing, self.preparation == token else { return }
            guard allowed else {
                if let url = CaseBluetoothAccess.settingsURL { NSWorkspace.shared.open(url) }
                self.finished(CaseHelperExit.bluetoothDenied)
                return
            }
            CaseSurvey.run { [weak self] survey in
                guard let self, self.preparing, self.preparation == token else { return }
                let choice = CaseAirPods.choose(survey, saved: CaseFiles.savedTarget)
                guard case .chosen(let pair) = choice else { self.finished(choice.failure ?? ""); return }
                do { try CaseFiles.save(target: pair) } catch {
                    self.finished("Swift Saber couldn't save which AirPods to use. Connect again.")
                    return
                }
                self.pair = pair
                self.pairTitle = pair.title
                CaseAudioGuard.shared.sessionStarted(target: pair.address)
                if pair.connected {
                    self.preparing = false
                    self.launch()
                } else {
                    self.waitForLid(pair, token: token)
                }
            }
        }
    }

    /// Ends the connection. The helper stops the sensors and releases the case before it exits.
    func disconnect() {
        userEnded = true
        stop()
    }

    /// The player says the lid is shut (the earbuds' own report usually does this by itself).
    func confirmLidClosed() {
        guard helper?.isRunning == true, !confirmed, baselineReady else { return }
        confirmClosed()
    }

    /// Called as the app quits: gives the helper its cleanup time.
    func shutdown() {
        guard isActive else { return }
        userEnded = true
        stop()
        let deadline = Date().addingTimeInterval(7)
        while helper?.isRunning == true && deadline.timeIntervalSinceNow > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if helper?.isRunning == true { helper?.terminate() }
    }

    // MARK: Connection

    private func waitForLid(_ pair: CaseAirPods, token: Int) {
        let watcher = CaseLidWatcher(productID: pair.productID) { [weak self] in
            guard let self, self.preparing, self.preparation == token else { return }
            self.endLidWait()
            self.preparing = false
            self.launch()
        }
        lidWatcher = watcher
        watcher.start()
        lidTimeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            guard let self, self.preparing, self.preparation == token else { return }
            self.endLidWait()
            self.finished("Stopped waiting for the lid. Connect again when you're ready.")
        }
        updateStage()
    }

    private func endLidWait() {
        lidTimeout?.invalidate(); lidTimeout = nil
        lidWatcher?.stop(); lidWatcher = nil
    }

    private func launch() {
        guard let restoreURL = Bundle.main.url(forResource: "ClosedCaseRestore", withExtension: "bin") else {
            finished("The AirPods case helpers are missing from this build. Build the app with Scripts/build-app.sh.")
            return
        }
        do {
            resetMotion()
            confirmed = false; connected = false; baselineReady = false; held = false
            stopping = false; signalled = false; closedAt = 0; stoppedAt = 0
            startedAt = ProcessInfo.processInfo.systemUptime
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Receive AirPods case motion")
            try FileManager.default.createDirectory(at: CaseFiles.sessions, withIntermediateDirectories: true)
            CaseFiles.pruneSessions(keeping: Self.keptSessions - 1)
            let folder = CaseFiles.sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            sessionFolder = folder
            lastLease = 0
            try renewLease()
            if let address = CaseFiles.savedTarget { silentOutput = PointerSilentOutput(targetAddress: address) }
            let logURL = folder.appendingPathComponent("native.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            helperLog = try FileHandle(forWritingTo: logURL)
            log("STEP restore started")

            let process = Process()
            restore = process
            process.executableURL = restoreURL
            process.arguments = [CaseFiles.target.path]
            process.standardOutput = helperLog
            process.standardError = helperLog
            process.terminationHandler = { [weak self] p in
                DispatchQueue.main.async {
                    guard let self, self.restore === p else { return }
                    self.restore = nil
                    if self.stopping { self.finished(self.feedError); return }
                    if p.terminationStatus == 0 { self.launchHelper() } else { self.finished(CaseHelperExit.restoreFailure(p.terminationStatus)) }
                }
            }
            try process.run()
            onNewFrame?()
            startTimer()
            updateStage()
        } catch {
            finished(error.localizedDescription)
        }
    }

    private func launchHelper() {
        guard let executable = Bundle.main.url(forResource: "ClosedCaseMotion", withExtension: "bin"), let capture else {
            finished("The AirPods case helpers are missing from this build. Build the app with Scripts/build-app.sh.")
            return
        }
        let process = Process()
        helper = process
        process.executableURL = executable
        process.arguments = [CaseFiles.target.path, "--pointer-session", capture.path]
        let motionPipe = Pipe()
        let fd = motionPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { finished("Couldn't open the motion connection."); return }
        process.standardOutput = motionPipe
        process.standardError = helperLog ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.helper === p else { return }
                self.readStatus()
                let status: Int32? = p.terminationReason == .exit ? p.terminationStatus : nil
                // Another client briefly held the channel callback: try again a few times.
                if status == 25, !self.stopping, self.busyRetries < 3 {
                    self.busyRetries += 1
                    self.helper = nil
                    self.stopMotionReader()
                    self.preparing = true
                    let token = self.preparation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.preparing, self.preparation == token else { return }
                        self.preparing = false
                        self.launch()
                    }
                    return
                }
                self.lostContact = !self.userEnded && self.everReady && CaseHelperExit.lostContact(status)
                let message = CaseHelperExit.helperFailure(status, stopping: self.stopping) ?? self.feedError
                    ?? (self.stopping ? nil : "The AirPods case disconnected. Open the lid, then connect again.")
                self.finished(message)
            }
        }
        do {
            helperStartedAt = ProcessInfo.processInfo.systemUptime
            try process.run()
            try? motionPipe.fileHandleForWriting.close()
            startMotionReader(motionPipe.fileHandleForReading)
            log("STEP helper started")
        } catch {
            finished(error.localizedDescription)
        }
    }

    // MARK: Motion

    private func resetMotion() {
        let seed = pair.flatMap { CaseFiles.loadOffset(for: $0.address) }
        lock.lock()
        fusion = CaseOrientation(seedBias: seed)
        lines = CaseMotionLineBuffer()
        forwarding = false
        lastHost = 0
        lock.unlock()
        savedMeasure = 0
    }

    private func startMotionReader(_ handle: FileHandle) {
        stopMotionReader()
        motionHandle = handle
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: motionQueue)
        source.setEventHandler { [weak self] in self?.readMotion(fd: handle.fileDescriptor, source: source) }
        source.resume()
        motionSource = source
    }

    private func stopMotionReader() {
        motionSource?.cancel()
        motionSource = nil
        try? motionHandle?.close()
        motionHandle = nil
    }

    /// Motion queue: drains the pipe, fuses the rows and feeds the saber.
    private func readMotion(fd: Int32, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 32768)
        var chunks: [Data] = []
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { chunks.append(Data(buffer.prefix(n))); continue }
            if n == 0 { source.cancel() } // The helper closed its end.
            break
        }
        guard !chunks.isEmpty else { return }
        var samples: [MotionSample] = []
        lock.lock()
        for chunk in chunks {
            for row in lines.append(chunk) {
                guard fusion.feed(row), forwarding else { continue }
                if let s = fusion.sample(time: CACurrentMediaTime(), invertGravity: invertGravity) { samples.append(s) }
            }
        }
        if fusion.lastHost > lastHost { lastHost = fusion.lastHost }
        lock.unlock()
        // The hub smooths and predicts, so only the newest pose of each read matters much,
        // but every sample keeps its arrival-rate statistics honest.
        for s in samples { hub.ingest(stream: .airPodCase, sample: s) }
    }

    private struct FusionSnapshot {
        var ready: Bool, needsFirstOffset: Bool, settling: CaseOrientation.Settling
        var measured: Int, seed: Vec3?, lastHost: Double
    }

    private func fusionSnapshot() -> FusionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return FusionSnapshot(ready: fusion.ready, needsFirstOffset: fusion.needsFirstOffset, settling: fusion.settling,
                              measured: fusion.measured, seed: fusion.seed, lastHost: lastHost)
    }

    // MARK: Session files

    private func renewLease() throws {
        guard let sessionFolder else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLease >= 1 else { return }
        try Data(String(format: "%.6f\n", now).utf8).write(to: sessionFolder.appendingPathComponent("app-lease.txt"), options: .atomic)
        lastLease = now
    }

    private func writePhase(_ phase: String) {
        guard let capture else { return }
        try? Data("\(phase)\n".utf8).write(to: capture.appendingPathComponent("phase.txt"), options: .atomic)
    }

    private func readStatus() {
        guard let capture, let data = try? Data(contentsOf: capture.appendingPathComponent("status.json")),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let snapshot = state["case_snapshot"] as? [String: Any],
              let sensors = state["sensors"] as? [[String: Any]] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let reportAge = Date().timeIntervalSince1970 - (state["updated_unix"] as? Double ?? 0)
        let ages = sensors.map { $0["age_seconds"] as? Double ?? 100 }
        let motionAge = now - fusionSnapshot().lastHost
        connected = reportAge >= 0 && reportAge < 2 && ages.count == 2
            && (motionAge < 0.5 || ages.allSatisfy { $0 >= 0 && $0 + reportAge < 1 })
        if connected && !stopping { silentOutput?.refresh() }
        baselineReady = !stopping && !confirmed && connected
            && state["open_baseline_verified"] as? Bool == true && snapshot["root_identity_verified"] as? Bool == true
        if baselineReady, helper?.isRunning == true, CaseLid.isClosed(CaseLid.reports(state["earbud_state_events"])) {
            confirmClosed()
        }
        if !stopping && confirmed {
            held = snapshot["case_identity_verified"] as? Bool == true || (connected && now - closedAt >= 2)
        }
        if let error = snapshot["error"] as? String, !error.isEmpty, feedError == nil {
            log("helper error: \(error)")
            feedError = "The charging case stopped responding. Open the lid, then connect again."
        }
    }

    private func confirmClosed() {
        guard !confirmed, baselineReady, capture != nil else { return }
        closedAt = ProcessInfo.processInfo.systemUptime
        writePhase("closed_confirmed")
        log("STEP lid closed")
        confirmed = true
        baselineReady = false
        updateStage()
    }

    // MARK: Ticking

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if isActive && !stopping {
            do { try renewLease() } catch { fail("Couldn't keep the AirPods case connection active."); return }
        }
        if restore?.isRunning == true && now - startedAt > 30 {
            fail("Your AirPods didn't connect. Open the lid, wake one earbud, then connect again.")
            return
        }
        let snap = fusionSnapshot()
        if !stopping && helper?.isRunning == true && !confirmed && snap.lastHost == 0 && now - helperStartedAt > 20 {
            fail("No motion arrived. Open the lid, wake one earbud, then connect again.")
            return
        }
        if stopping && stoppedAt > 0 && now - stoppedAt > 3 {
            if !signalled { signalled = true; helper?.terminate() }
            return
        }
        if now - lastStatusRead > 0.2 { lastStatusRead = now; readStatus() }
        if snap.measured > savedMeasure, let seed = snap.seed, let address = pair?.address,
           savedMeasure == 0 || now - lastOffsetSave > 30 {
            savedMeasure = snap.measured; lastOffsetSave = now
            CaseFiles.saveOffset(seed, for: address)
        }
        if feedError != nil && !stopping { stop(); return }
        updateStage()
    }

    private func updateStage() {
        let snap = fusionSnapshot()
        let next: Stage
        if stopping || !isActive {
            next = .off
        } else if preparing {
            next = lidWatcher != nil ? .openLid : .preparing
        } else if !confirmed {
            next = baselineReady ? .closeLid : .connecting
        } else if !snap.ready {
            next = .holdStill
        } else if !held {
            next = .linking
        } else {
            next = .ready
        }
        let forward = next == .ready
        lock.lock(); forwarding = forward; lock.unlock()
        if next == .ready && !everReady {
            everReady = true
            connectedSince = Date()
            log("STEP ready")
        }
        let progress = next == .holdStill ? snap.settling.progress : 0
        if abs(progress - holdProgress) > 0.01 || (progress == 0) != (holdProgress == 0) { holdProgress = progress }
        let moving = next == .holdStill && snap.settling.moving
        if moving != holdMoving { holdMoving = moving }
        if next != stage {
            let advanced = order(next) > order(stage) && next != .off && stage != .off
            stage = next
            if advanced { onStageAdvanced?() }
        }
    }

    private func order(_ s: Stage) -> Int {
        switch s {
        case .off: return 0
        case .preparing: return 1
        case .openLid: return 2
        case .connecting: return 3
        case .closeLid: return 4
        case .holdStill: return 5
        case .linking: return 6
        case .ready: return 7
        }
    }

    // MARK: Ending

    private func fail(_ message: String) {
        feedError = message
        stop()
    }

    private func stop() {
        silentOutput?.stop(); silentOutput = nil
        if !stopping { stoppedAt = ProcessInfo.processInfo.systemUptime; log("STEP disconnect") }
        stopping = true
        baselineReady = false
        lock.lock(); forwarding = false; lock.unlock()
        writePhase("stop")
        if preparing && restore == nil && helper == nil {
            finished(feedError)
            return
        }
        if restore?.isRunning == true { restore?.terminate(); return }
        if helper?.isRunning != true { finished(feedError) }
        updateStage()
    }

    private func finished(_ message: String?) {
        log("STEP session ended")
        preparing = false
        signalled = false
        endLidWait()
        silentOutput?.stop(); silentOutput = nil
        CaseAudioGuard.shared.sessionEnded()
        timer?.invalidate(); timer = nil
        stopMotionReader()
        try? helperLog?.close(); helperLog = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        helper = nil; restore = nil
        connected = false; baselineReady = false; stopping = false; confirmed = false; held = false
        lock.lock(); forwarding = false; lock.unlock()
        connectedSince = nil
        let shown = userEnded ? nil : message
        problem = shown
        updateStage()
        onEnded?(shown)
    }

    private func log(_ line: String) {
        let text = String(format: "%@ uptime=%.3f\n", line, ProcessInfo.processInfo.systemUptime)
        try? helperLog?.write(contentsOf: Data(text.utf8))
    }
}

