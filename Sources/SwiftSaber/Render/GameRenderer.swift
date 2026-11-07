import AppKit
import SceneKit
import QuartzCore
import simd
import SaberCore

struct HUDSnapshot: Equatable {
    var score = 0
    var combo = 0
    var multiplier = 1
    var multiplierFill = 0.0
    var energy = 0.5
    var progress = 0.0
    var accuracy = 1.0
    var rank = "SS"
    var time = 0.0
    var duration = 1.0
    var warning: String?
    var noFail = false
    var autoplay = false
}

/// SCNView that enables mouse-moved events for its window.
final class GameSCNView: SCNView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.backgroundColor = .black
    }
    override var acceptsFirstResponder: Bool { false }
}

/// Keeps a smooth song clock locked to the audio hardware clock.
struct SongClock {
    var time: Double = 0
    var running = false
    var synced = false

    mutating func advance(dt: Double, audioTime: Double?) -> Double {
        guard running else { return time }
        time += dt
        if let a = audioTime {
            let err = a - time
            if !synced || abs(err) > 0.08 {
                time = a
                synced = true
            } else {
                time += err * 0.1
            }
        }
        return time
    }
}

/// Drives the game every frame on SceneKit's render thread.
final class GameRenderer: NSObject, SCNSceneRendererDelegate {
    enum Mode { case menu, countdown, playing, paused, ended }

    let view = GameSCNView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), options: nil)
    let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let camera = SCNCamera()
    private let stage = StageEnvironment()
    private let effects = EffectsLayer()
    private let factory = NoteFactory()
    private let notesRoot = SCNNode()
    private var sabers: [Hand: SaberVisual] = [:]

    private let input: InputHub
    private let audio: GameAudio

    /// Called on the main thread.
    var onHUD: ((HUDSnapshot) -> Void)?
    var onGameOver: ((GameResults) -> Void)?
    /// Called on the render thread when a saber cuts a block or hits a bomb (hand, strength 0...1).
    var onSaberContact: ((Hand, Float) -> Void)?

    private let lock = NSLock()
    private var mode: Mode = .menu
    private var session: GameSession?
    private var primaryHand: Hand = .right
    private var noteNodes: [Int: SCNNode] = [:]
    private var missedNotes: Set<Int> = []
    private var bombNodes: [Int: SCNNode] = [:]
    private var nextNote = 0
    private var nextBomb = 0
    private var nextLight = 0
    private var clock = SongClock()
    private var frozenTime: Double = 0
    private var lastFrame: Double = 0
    private var lastHUD: Double = 0
    private var shake: Float = 0
    private var cameraShakeEnabled = true
    private var gameOverSent = false
    private var noFail = false
    private var autoplay: AutoplayDriver?
    /// Hides both sabers (e.g. during calibration, where their motion is meaningless).
    private var sabersHidden = false
    private let cameraBase = Arena.cameraPosition.simd

    init(input: InputHub, audio: GameAudio) {
        self.input = input
        self.audio = audio
        super.init()

        scene.background.contents = NSColor.black
        scene.fogStartDistance = 28
        scene.fogEndDistance = 150
        scene.fogDensityExponent = 1.3
        scene.fogColor = Palette.fog

        camera.fieldOfView = 64
        camera.zNear = 0.05
        camera.zFar = 400
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 1.35
        camera.bloomThreshold = 0.72
        camera.bloomBlurRadius = 14
        camera.vignettingPower = 0.7
        camera.vignettingIntensity = 0.9
        camera.colorFringeStrength = 0.35
        camera.colorFringeIntensity = 0.5
        camera.saturation = 1.12
        camera.contrast = 0.08
        cameraNode.camera = camera
        cameraNode.simdPosition = cameraBase
        cameraNode.simdLook(at: Arena.cameraTarget.simd)

        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(stage.root)
        scene.rootNode.addChildNode(notesRoot)
        scene.rootNode.addChildNode(effects.root)
        for hand in Hand.allCases {
            sabers[hand] = SaberVisual(hand: hand, root: scene.rootNode)
        }

        view.scene = scene
        view.pointOfView = cameraNode
        view.delegate = self
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 120
        view.rendersContinuously = true
        view.isPlaying = true
        view.allowsCameraControl = false
    }

    // MARK: Settings

    func setVisualOptions(bloom: Bool, cameraShake: Bool) {
        lock.lock(); defer { lock.unlock() }
        camera.bloomIntensity = bloom ? 1.35 : 0
        camera.colorFringeStrength = bloom ? 0.35 : 0
        cameraShakeEnabled = cameraShake
    }

    func setSabersHidden(_ hidden: Bool) {
        lock.lock(); defer { lock.unlock() }
        sabersHidden = hidden
    }

    // MARK: Mouse aiming (main thread)

    /// Converts a point in view coordinates to an aim point on a plane in front of the player.
    func aimPoint(viewPoint p: CGPoint) -> Vec3? {
        let near = view.unprojectPoint(SCNVector3(p.x, p.y, 0))
        let far = view.unprojectPoint(SCNVector3(p.x, p.y, 1))
        let o = Vec3(Double(near.x), Double(near.y), Double(near.z))
        let d = Vec3(Double(far.x - near.x), Double(far.y - near.y), Double(far.z - near.z))
        let planeZ = Arena.hitPlaneZ - 0.3
        guard abs(d.z) > 1e-6 else { return nil }
        let t = (planeZ - o.z) / d.z
        guard t > 0 else { return nil }
        return o + d * t
    }

    // MARK: Game control (main thread)

    func prepare(beatmap: Beatmap, config: SessionConfig, primaryHand: Hand, autoplay useAutoplay: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        autoplay = useAutoplay ? AutoplayDriver(beatmap: beatmap, primaryHand: primaryHand) : nil
        clearNotes()
        effects.clear()
        session = GameSession(beatmap: beatmap, config: config)
        self.primaryHand = primaryHand
        noFail = config.noFail
        nextNote = 0; nextBomb = 0; nextLight = 0
        clock = SongClock()
        frozenTime = 0
        gameOverSent = false
        stage.blackout()
        stage.apply(.on(.blue), to: .floor)
        stage.apply(.on(.blue), to: .back)
        mode = .countdown
    }

    func beginPlayback() {
        lock.lock(); defer { lock.unlock() }
        guard session != nil else { return }
        session?.resetTracking()
        audio.playMusicFromStart()
        clock = SongClock()
        clock.running = true
        mode = .playing
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard mode == .playing else { return }
        audio.pauseMusic()
        clock.running = false
        frozenTime = clock.time
        mode = .paused
    }

    /// Re-arms the clock after a pause (call after the resume countdown).
    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard mode == .paused || mode == .countdown, session != nil else { return }
        session?.resetTracking()
        audio.resumeMusic()
        clock.running = true
        clock.synced = false
        mode = .playing
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return mode == .paused
    }

    func returnToMenu() {
        lock.lock(); defer { lock.unlock() }
        audio.stopMusic()
        clearNotes()
        effects.clear()
        session = nil
        autoplay = nil
        mode = .menu
        stage.idle()
    }

    /// Called after the input was recentred mid-song.
    func inputTeleported() {
        lock.lock(); defer { lock.unlock() }
        session?.resetTracking()
    }

    /// Results of the level in progress (used by automated captures).
    func currentResults() -> GameResults? {
        lock.lock(); defer { lock.unlock() }
        return session?.results()
    }

    /// Renders the 3D scene (without the SwiftUI overlay) to an image. Main thread only.
    func snapshot() -> NSImage { view.snapshot() }

    private func clearNotes() {
        for n in noteNodes.values { n.removeFromParentNode() }
        for n in bombNodes.values { n.removeFromParentNode() }
        noteNodes.removeAll()
        bombNodes.removeAll()
        missedNotes.removeAll()
    }

    // MARK: Frame loop (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime _: TimeInterval) {
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.05, max(0.0001, now - lastFrame))
        lastFrame = now
        var inputs = input.saberInputs(now: now)

        lock.lock()
        defer { lock.unlock() }

        // Song time for this frame.
        var songTime: Double?
        switch mode {
        case .playing: songTime = clock.advance(dt: dt, audioTime: audio.songTime())
        case .countdown, .paused: songTime = frozenTime
        case .menu, .ended: songTime = nil
        }
        if let ap = autoplay, let t = songTime {
            inputs = ap.inputs(time: mode == .playing ? t : max(t, 0))
        }
        if let s = session, s.isOneSaber, mode != .menu {
            inputs = inputs.map { $0.hand == primaryHand ? $0 : SaberInput(hand: $0.hand, direction: $0.direction, active: false) }
        }
        if sabersHidden {
            inputs = inputs.map { SaberInput(hand: $0.hand, direction: $0.direction, active: false) }
        }
        for i in inputs { sabers[i.hand]?.update(input: i, time: now, dt: dt) }

        switch mode {
        case .menu, .ended:
            break
        case .countdown, .paused:
            positionObjects(at: frozenTime)
        case .playing:
            stepGame(t: songTime ?? clock.time, inputs: inputs, now: now)
        }

        stage.update(dt: dt)
        effects.update(dt: dt)
        updateCamera(dt: dt)
    }

    private func stepGame(t: Double, inputs: [SaberInput], now: Double) {
        guard let session else { return }
        let map = session.beatmap

        // Lighting events.
        while nextLight < map.lights.count && map.lights[nextLight].time <= t {
            let e = map.lights[nextLight]
            stage.apply(e.action, to: e.group)
            nextLight += 1
        }

        spawn(upTo: t, session: session)
        let events = session.update(songTime: t, sabers: inputs)
        for e in events { handle(e, session: session, time: t) }
        positionObjects(at: t)

        if now - lastHUD > 1.0 / 30 {
            lastHUD = now
            let s = session.scores
            var warning: String?
            let needed: [Hand] = session.isOneSaber ? [primaryHand] : Hand.allCases
            let missing = needed.filter { h in !(inputs.first { $0.hand == h }?.active ?? false) }
            if !missing.isEmpty {
                warning = missing.count == 2 ? "No saber input — check your AirPods" : "\(missing[0].name) saber has no input"
            }
            let snap = HUDSnapshot(score: s.score, combo: s.combo, multiplier: s.multiplier, multiplierFill: s.multiplierFill,
                                   energy: s.energy, progress: session.progress(at: t), accuracy: s.accuracyPercent,
                                   rank: Rank.from(percent: s.accuracyPercent).rawValue, time: max(0, t),
                                   duration: map.duration, warning: autoplay == nil ? warning : nil, noFail: noFail,
                                   autoplay: autoplay != nil)
            DispatchQueue.main.async { [weak self] in self?.onHUD?(snap) }
        }
    }

    private func spawn(upTo t: Double, session: GameSession) {
        let map = session.beatmap
        let lead = (Arena.hitPlaneZ - Arena.spawnZ) / map.noteSpeed
        while nextNote < map.notes.count && map.notes[nextNote].time - t < lead {
            let n = map.notes[nextNote]
            let colorHand = session.isOneSaber ? primaryHand : n.hand
            let node = factory.block(for: n, colorHand: colorHand)
            notesRoot.addChildNode(node)
            noteNodes[n.id] = node
            nextNote += 1
        }
        while nextBomb < map.bombs.count && map.bombs[nextBomb].time - t < lead {
            let b = map.bombs[nextBomb]
            let node = factory.bomb()
            notesRoot.addChildNode(node)
            bombNodes[b.id] = node
            nextBomb += 1
        }
    }

    private func positionObjects(at t: Double) {
        guard let session else { return }
        let motion = session.motion
        let map = session.beatmap
        for (id, node) in noteNodes {
            let n = map.notes[id]
            let p = motion.position(column: n.column, row: n.row, beatTime: n.time, now: t)
            if p.z > Arena.despawnZ {
                node.removeFromParentNode()
                noteNodes[id] = nil
                missedNotes.remove(id)
                continue
            }
            node.simdPosition = p.simd
            let angle = n.direction.arrowRotation + motion.spin(beatTime: n.time, now: t)
            node.simdOrientation = simd_quatf(angle: Float(angle), axis: SIMD3<Float>(0, 0, 1))
            let s = Float(motion.appearScale(beatTime: n.time, now: t))
            node.simdScale = SIMD3<Float>(repeating: s)
            if missedNotes.contains(id) {
                node.opacity = max(0, node.opacity - 0.05)
            }
        }
        for (id, node) in bombNodes {
            let b = map.bombs[id]
            let p = motion.position(column: b.column, row: b.row, beatTime: b.time, now: t)
            if p.z > Arena.despawnZ {
                node.removeFromParentNode()
                bombNodes[id] = nil
                continue
            }
            node.simdPosition = p.simd
            node.simdOrientation = simd_quatf(angle: Float(t * 1.3), axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
        }
    }

    private func handle(_ e: GameEvent, session: GameSession, time: Double) {
        switch e {
        case .cut(let info):
            guard let node = noteNodes.removeValue(forKey: info.noteID) else { break }
            slice(node: node, info: info, speed: Float(session.beatmap.noteSpeed))
            onSaberContact?(info.hand, 0.7)
            let alt = info.noteID % 2 == 0
            audio.play(alt ? .slice : .sliceAlt, pan: Float(clamp(info.position.x / 1.2, -1, 1)), volume: 0.75)
        case .scored(_, let score, _, let position):
            let color: NSColor
            switch score.total {
            case 110...: color = Palette.white
            case 100..<110: color = Palette.mix(Palette.white, NSColor.systemYellow, 0.35)
            case 80..<100: color = Palette.mix(Palette.white, NSColor.systemOrange, 0.5)
            default: color = Palette.mix(Palette.white, NSColor.systemRed, 0.5)
            }
            let p = SIMD3<Float>(Float(position.x), Float(min(position.y, 1.3)) + 0.28, Float(Arena.hitPlaneZ) - 0.4)
            effects.addPopup("\(score.total)", at: p, color: color, scale: score.total >= 110 ? 1.15 : 1)
        case .badCut(let info, let reason):
            if let node = noteNodes.removeValue(forKey: info.noteID) {
                slice(node: node, info: info, speed: Float(session.beatmap.noteSpeed), quiet: true)
            }
            let p = SIMD3<Float>(Float(info.position.x), Float(info.position.y) + 0.35, Float(Arena.hitPlaneZ) + 0.2)
            effects.addPopup(reason == .wrongDirection ? "✕" : (reason == .tooSlow ? "SLOW" : "✕"), at: p, color: Palette.mix(Palette.red, .white, 0.2), scale: 0.9)
            audio.play(.badCut, volume: 0.8)
            onSaberContact?(info.hand, 0.4)
            shake = max(shake, 0.4)
        case .miss(let id):
            missedNotes.insert(id)
            let n = session.beatmap.notes[id]
            let g = Arena.gridPosition(column: n.column, row: n.row)
            effects.addPopup("MISS", at: SIMD3<Float>(Float(g.x), Float(g.y) + 0.3, Float(Arena.hitPlaneZ) + 0.6),
                             color: NSColor(calibratedWhite: 0.6, alpha: 1), scale: 0.8)
            audio.play(.miss, volume: 0.6)
        case .bombHit(let id, let hand, let position):
            if let node = bombNodes.removeValue(forKey: id) {
                effects.addBurst(at: position.simd, template: node)
                node.removeFromParentNode()
            }
            effects.addParticles(factory.sparks(for: hand), at: position.simd)
            audio.play(.bomb, volume: 0.9)
            onSaberContact?(hand, 1.0)
            shake = 1
        case .multiplierUp:
            break
        case .failed:
            mode = .ended
            audio.fadeOutMusic()
            audio.play(.fail)
            stage.blackout()
            stage.apply(.fade(.red), to: .rings)
            stage.apply(.fade(.red), to: .back)
            sendGameOver(session: session, delay: 1.6)
        case .finished:
            mode = .ended
            audio.play(.clear)
            stage.apply(.flash(.white), to: .back)
            stage.apply(.flash(.blue), to: .rings)
            sendGameOver(session: session, delay: 1.0)
        }
    }

    private func slice(node: SCNNode, info: CutInfo, speed: Float, quiet: Bool = false) {
        let normal = simd_normalize(info.planeNormal.simd)
        if let halves = factory.halves(of: node, worldNormal: normal) {
            effects.addHalves(halves.0, halves.1, normal: normal, motion: SIMD2<Float>(Float(info.motion.x), Float(info.motion.y)), forwardSpeed: speed)
        }
        if !quiet {
            effects.addParticles(factory.sparks(for: info.hand), at: node.simdPosition)
            sabers[info.hand]?.flash()
        }
        node.removeFromParentNode()
    }

    private func sendGameOver(session: GameSession, delay: Double) {
        guard !gameOverSent else { return }
        gameOverSent = true
        let results = session.results()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.onGameOver?(results)
        }
    }

    private func updateCamera(dt: Double) {
        shake *= Float(exp(-dt * 7))
        if cameraShakeEnabled && shake > 0.01 {
            let a = shake * 0.035
            cameraNode.simdPosition = cameraBase + SIMD3<Float>(Float.random(in: -a...a), Float.random(in: -a...a), 0)
        } else {
            cameraNode.simdPosition = cameraBase
        }
    }
}
