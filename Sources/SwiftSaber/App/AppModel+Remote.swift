import AppKit
import SaberCore

/// The iPhone as a remote: mirrors every menu on the phone and runs its commands, so the
/// whole game can be driven without touching the Mac.
extension AppModel {
    // MARK: Mac → phone

    func sendPhoneState() {
        guard phone.isConnected else { return }
        let mode = settings.inputMode
        let excluded = excludedDevices
        // Each device is told whether it is a saber (or would be, once calibrated) or a remote.
        phone.sendState(remoteState()) { slot in
            guard let slot else { return false }
            return mode.allows(slot.device) && !excluded.contains(slot.device)
        }
    }

    func remoteState() -> RemoteState {
        var s = RemoteState()
        s.screen = remoteScreen
        s.loadingProgress = loadingProgress
        s.songTitle = song.title
        s.songInfo = "\(song.artist) · \(Int(song.bpm)) BPM · \(clock(song.duration))"
        s.difficulties = Difficulty.allCases.map(\.name)
        s.difficulty = selectedDifficulty.rawValue
        let hands = availableHands.count
        let mode: PlayMode = hands < 2 ? .oneSaber : selectedMode
        s.mode = mode.rawValue
        s.twoSabersAvailable = hands >= 2
        s.sabersReady = hands
        s.anyCalibrated = !calibratedStreams.isEmpty
        s.phoneIsSaber = settings.inputMode.usesPhone
        s.sabers = saberSummary().map {
            RemoteState.Saber(hand: $0.hand.rawValue, device: deviceName($0.device), symbol: deviceSymbol($0.device), ready: $0.ready)
        }
        s.canSwapHands = canSwapHands
        s.demo = isDemo
        s.countdown = countdownValue
        s.countdownMessage = countdownMessage

        if screen == .levelSelect || screen == .customize { s.look = remoteLook() }
        switch screen {
        case .levelSelect:
            let map = beatmap(selectedDifficulty, mode)
            s.mapStats = "\(map.notes.count) blocks · \(map.bombs.count) bombs · \(String(format: "%.1f", map.notesPerSecond)) / sec"
            if let best = BestScores.get(selectedDifficulty, mode) {
                s.best = "\(best.score) · \(best.rank.rawValue)" + (best.fullCombo ? " · FC" : "")
            }
        case .countdown, .playing, .paused:
            s.progress = hud.progress
            s.timeText = "\(clock(hud.time)) / \(clock(hud.duration))"
            s.score = hud.score
            s.combo = hud.combo
        case .calibration:
            s.calibration = remoteCalibration()
        case .results:
            if let r = results {
                var out = RemoteState.Results()
                out.headline = r.failed ? "LEVEL FAILED" : (r.fullCombo ? "FULL COMBO!" : "LEVEL CLEARED")
                out.rank = r.rank.rawValue
                out.score = r.score
                out.accuracy = r.percent
                out.failed = r.failed
                out.newRecord = isNewRecord
                out.maxCombo = r.maxCombo
                out.goodCuts = r.goodCuts
                out.totalNotes = r.totalNotes
                out.misses = r.misses
                s.results = out
            }
        default:
            break
        }
        // Settings are small and also feed the No Fail toggle on level select.
        s.settings = remoteSettings()
        return s
    }

    private var remoteScreen: RemoteState.Screen {
        switch screen {
        case .loading: return .loading
        case .menu: return .menu
        case .levelSelect: return .levelSelect
        case .calibration: return .calibration
        case .settings: return .settings
        case .customize: return .customize
        case .countdown: return .countdown
        case .playing: return .playing
        case .paused: return .paused
        case .results: return .results
        }
    }

    private func remoteCalibration() -> RemoteState.Calibration {
        var c = RemoteState.Calibration()
        let cal = calibration
        switch cal.phase {
        case .detecting:
            c.phase = .detecting
            c.title = "Get ready"
            c.detail = setupHint()
            c.streams = deviceRows().map {
                RemoteState.Calibration.Stream(id: $0.id, name: $0.name, live: $0.live, progress: 0, done: false,
                                               symbol: $0.symbol, hand: $0.hand?.rawValue,
                                               used: $0.canToggle ? $0.used : nil, note: $0.note)
            }
            c.canStart = plannedDevices.values.contains(where: \.needsCalibration)
            c.failure = cal.failure
            if settings.inputMode.usesAirPods {
                c.airPodGrip = settings.airPodGrip.rawValue
                c.airPodGrips = AirPodGrip.allCases.map { RemoteState.Option(id: $0.rawValue, title: $0.title) }
                if usesAirPodsCase { c.airPodsCase = remoteCase() }
            }
        case .calibrating:
            c.phase = .calibrating
            let active = cal.streams.filter { $0.step != nil }
            let text = CalibrationModel.instruction(for: cal.currentStep, count: active.count, grip: settings.airPodGrip,
                                                    awaitingNext: cal.canAdvance)
            c.title = text.title
            c.detail = text.detail
            let current = CalibrationModel.stepIndex(cal.currentStep)
            let planned = plannedDevices
            c.streams = active.map { s in
                RemoteState.Calibration.Stream(id: "\(s.id.rawValue)", name: streamName(s.id), live: s.live, progress: s.progress,
                      done: s.awaitingNext || CalibrationModel.stepIndex(s.step) > current,
                      symbol: streamSymbol(s.id), hand: planned.first { $0.value == s.id.device }?.key.rawValue)
            }
            c.canAdvance = cal.canAdvance
        case .done:
            c.phase = .done
            c.title = "You're calibrated"
            c.detail = "Your sabers are live — give them a swing. Tap Recenter any time they drift."
        }
        return c
    }

    private func remoteCase() -> RemoteState.Calibration.AirPodsCase {
        let session = airPodsCase
        var c = RemoteState.Calibration.AirPodsCase()
        c.problem = session.problem
        switch session.stage {
        case .off:
            c.step = 1; c.title = "Get the case ready"
            c.detail = "Both AirPods Pro in their case, paired with the Mac. Then tap Connect and open the lid."
            c.action = "connect"; c.actionTitle = session.problem == nil ? "CONNECT CASE" : "CONNECT AGAIN"
        case .preparing, .openLid, .connecting:
            c.step = 2; c.title = "Open the lid"
            c.detail = session.stage == .connecting ? "Connecting — keep the lid open for a moment." : "Swift Saber connects while the lid is open. Keep both AirPods inside."
            c.action = "cancel"; c.actionTitle = "CANCEL"
        case .closeLid:
            c.step = 3; c.title = "Close the lid"
            c.detail = "Keep both AirPods inside. It's noticed by itself, or tap Lid Is Closed."
            c.action = "lidClosed"; c.actionTitle = "LID IS CLOSED"
        case .holdStill, .linking:
            c.step = 4; c.title = "Set it down"
            c.detail = session.holdMoving ? "Movement detected — leave the case still." : "Put the closed case on a flat surface and don't touch it while the ring fills."
            c.progress = session.holdProgress
            c.action = "cancel"; c.actionTitle = "CANCEL"
        case .ready:
            c.step = 6; c.connected = true; c.title = "Case connected"
            c.detail = "Pick it up and hold it like a hilt — calibration starts by itself."
            c.action = "disconnect"; c.actionTitle = "DISCONNECT CASE"
        }
        return c
    }

    private func remoteLook() -> RemoteState.Look {
        func hexes(_ c: SaberColorScheme) -> [String] {
            [c.leftSaber.hex, c.rightSaber.hex, c.leftLights.hex, c.rightLights.hex]
        }
        var l = RemoteState.Look()
        l.arena = settings.stage.rawValue
        l.arenas = StageKind.allCases.map { k in
            RemoteState.Look.Arena(id: k.rawValue, title: k.title, tagline: k.tagline, symbol: k.symbol,
                                   swatch: [k.defaultColors.leftLights.hex, k.defaultColors.rightLights.hex])
        }
        l.customColors = settings.overrideColors
        l.colors = hexes(settings.effectiveColors)
        l.presets = ColorPreset.all.map { RemoteState.Look.Preset(id: $0.id, name: $0.name, colors: hexes($0.scheme)) }
        l.presetID = ColorPreset.matching(settings.effectiveColors)?.id
        return l
    }

    /// Writes a colour change as the custom scheme (switching custom colours on), like the
    /// Mac's Arena & Colors screen.
    private func editColors(_ change: (inout SaberColorScheme) -> Void) {
        var s = settings
        var c = s.effectiveColors
        change(&c)
        s.customColors = c
        s.overrideColors = true
        settings = s
    }

    private func remoteSettings() -> RemoteState.Settings {
        var r = RemoteState.Settings()
        let g = settings
        r.inputMode = g.inputMode.rawValue
        r.inputModes = InputMode.allCases.map { RemoteState.Option(id: $0.rawValue, title: $0.title) }
        r.inputDetail = g.inputMode.detail
        r.primaryHand = g.primaryHand.rawValue
        r.sensitivity = g.sensitivity
        r.airPodLatencyMs = g.airPodLatencyMs
        r.lenientCuts = g.lenientCuts
        r.autoRecenter = g.autoRecenter
        r.keepAirPodsAwake = g.keepAirPodsAwake
        r.audioOutput = g.audioOutput
        var outputs = [RemoteState.Option(id: "auto", title: "Mac speakers (recommended)"),
                       RemoteState.Option(id: "system", title: "System default output")]
        for d in outputDevices {
            outputs.append(RemoteState.Option(id: d.uid, title: d.name + (d.isBluetooth ? " (Bluetooth)" : "")))
        }
        r.audioOutputs = outputs
        r.musicVolume = g.musicVolume
        r.sfxVolume = g.sfxVolume
        r.audioOffsetMs = g.audioOffsetMs
        r.bloom = g.bloom
        r.cameraShake = g.cameraShake
        r.noFail = g.noFail
        return r
    }

    private func clock(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: Phone → Mac

    /// Runs a command from the phone. Each one is only accepted on the screen whose Mac
    /// button does the same thing, so a stale tap can't jump the game somewhere odd.
    func handleRemote(_ command: RemoteCommand) {
        switch command {
        case .openLevelSelect:
            if screen == .menu || screen == .results { goToLevelSelect() }
        case .openCalibration:
            if screen == .menu { openCalibration() }
        case .openSettings:
            if screen == .menu {
                refreshOutputDevices()
                screen = .settings
            }
        case .openCustomize:
            if screen == .menu || screen == .levelSelect { screen = .customize }
        case .quitGame:
            if screen == .menu { NSApp.terminate(nil) }
        case .back:
            switch screen {
            case .levelSelect, .settings, .customize: screen = .menu
            case .results: quitToMenu()
            case .calibration: closeCalibration()
            default: break
            }

        case .selectDifficulty(let raw):
            if screen == .levelSelect, let d = Difficulty(rawValue: raw) {
                selectedDifficulty = d
                audio.play(.click, volume: 0.5)
            }
        case .selectMode(let raw):
            if screen == .levelSelect, let m = PlayMode(rawValue: raw), m == .oneSaber || availableHands.count >= 2 {
                selectedMode = m
                audio.play(.click, volume: 0.5)
            }
        case .start:
            if screen == .levelSelect && !availableHands.isEmpty { startLevel() }
        case .watchDemo:
            if screen == .levelSelect { startDemo() }

        case .pause:
            pauseGame()
        case .resume:
            resumeGame()
        case .restart:
            if screen == .paused || screen == .results { restartLevel() }
        case .quitToMenu:
            if screen == .paused || screen == .results { quitToMenu() }
        case .recenter:
            recenter()

        case .beginCalibration:
            if screen == .calibration && calibration.phase == .detecting { beginCalibration() }
        case .calibrationNext:
            if screen == .calibration && calibration.phase == .calibrating { calibrationNext() }
        case .restartCalibration:
            if screen == .calibration { calibration.restart() }
        case .finishCalibration:
            if screen == .calibration { closeCalibration() }
        case .calibrationPlayNow:
            if screen == .calibration && calibration.phase == .done {
                calibration.deactivate()
                goToLevelSelect()
            }
        case .setAirPodGrip(let raw):
            if let grip = AirPodGrip(rawValue: raw), screen == .calibration || screen == .settings {
                settings.airPodGrip = grip
                audio.play(.click, volume: 0.5)
            }
        case .connectCase:
            if usesAirPodsCase { airPodsCase.connect() }
        case .caseLidClosed:
            airPodsCase.confirmLidClosed()
        case .disconnectCase:
            airPodsCase.disconnect()
        case .swapHands:
            if screen != .playing && screen != .countdown { swapHands() }
        case let .setDeviceUsed(id, used):
            if let device = SaberDevice(rawValue: id), device != .mouse, screen == .calibration || screen == .settings {
                setDevice(device, used: used)
            }
        case .useMouseInstead:
            if screen == .calibration {
                settings.inputMode = .mouse
                closeCalibration()
            }

        case .setArena(let raw):
            if let k = StageKind(rawValue: raw), screen == .levelSelect || screen == .customize {
                settings.stage = k
                audio.play(.click, volume: 0.5)
            }
        case .setCustomColors(let on):
            guard screen == .customize else { break }
            var s = settings
            if on && !s.overrideColors && s.customColors == .classic {
                s.customColors = s.stage.defaultColors // first time: start from what's on screen
            }
            s.overrideColors = on
            settings = s
        case .applyColorPreset(let id):
            if screen == .customize, let preset = ColorPreset.preset(id: id) {
                editColors { $0 = preset.scheme }
                audio.play(.click, volume: 0.5)
            }
        case let .setColor(slot, hex):
            if screen == .customize, let slot = SaberColorScheme.Slot(rawValue: slot), let color = NeonColor(hex: hex) {
                editColors { $0[slot] = color }
            }
        case .swapColors:
            if screen == .customize { editColors { $0 = $0.swapped } }
        case .lightsMatchSabers:
            if screen == .customize { editColors { $0.leftLights = $0.leftSaber; $0.rightLights = $0.rightSaber } }
        case .resetColors:
            if screen == .customize {
                var s = settings
                s.overrideColors = false
                s.customColors = s.stage.defaultColors
                settings = s
            }
        case .previewLights:
            if screen == .customize { renderer.previewLights() }

        case let .setFlag(flag, on):
            switch flag {
            case .lenientCuts: settings.lenientCuts = on
            case .autoRecenter: settings.autoRecenter = on
            case .keepAirPodsAwake: settings.keepAirPodsAwake = on
            case .bloom: settings.bloom = on
            case .cameraShake: settings.cameraShake = on
            case .noFail: settings.noFail = on
            }
        case let .setValue(key, value):
            guard value.isFinite else { break }
            switch key {
            case .sensitivity: settings.sensitivity = min(max(value, 0.6), 2.0)
            case .airPodLatencyMs: settings.airPodLatencyMs = min(max(value, 0), 150)
            case .musicVolume: settings.musicVolume = min(max(value, 0), 1)
            case .sfxVolume: settings.sfxVolume = min(max(value, 0), 1)
            case .audioOffsetMs: settings.audioOffsetMs = min(max(value, -200), 300)
            }
        case .setInputMode(let raw):
            if let m = InputMode(rawValue: raw) { settings.inputMode = m }
        case .setPrimaryHand(let raw):
            if let h = Hand(rawValue: raw) { settings.primaryHand = h }
        case .setAudioOutput(let id):
            if id == "auto" || id == "system" || outputDevices.contains(where: { $0.uid == id }) {
                settings.audioOutput = id
            }
        }
        // Answer right away so the phone doesn't wait for the next periodic update.
        DispatchQueue.main.async { [weak self] in self?.sendPhoneState() }
    }
}
