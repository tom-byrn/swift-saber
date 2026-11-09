import Foundation
import GameController
import CoreHaptics
import QuartzCore
import SaberCore

/// Game controllers with motion sensors as sabers: DualSense, DualShock 4, Joy-Con and the
/// like, paired with the Mac over Bluetooth. Up to two drive sabers (`.controller1` /
/// `.controller2`); their buttons also work the menus.
///
/// These controllers report raw gyroscope and accelerometer readings, so an
/// `AttitudeEstimator` turns them into an attitude for calibration and the sabers.
final class GameControllerService: ObservableObject {
    /// A connected controller that streams motion.
    struct Pad: Identifiable, Equatable {
        var id: StreamID
        var name: String
        /// Joy-Con (L) / (R) belong in one hand.
        var preferredHand: Hand?
    }

    /// Buttons that work the game, mapped from each controller's own layout.
    enum PadButton {
        /// Menu / Options: pause and resume.
        case menu
        /// A / Cross: confirm (Next during calibration, Play on the menu).
        case confirm
        /// B / Circle: back.
        case back
        /// Y / Triangle: recenter.
        case recenter
    }

    @Published private(set) var pads: [Pad] = []
    /// Controllers that are connected but have no motion sensors (an Xbox pad, say), so the
    /// setup screen can explain why they don't show up as sabers.
    @Published private(set) var withoutMotion: [String] = []

    /// Called on the main thread for each button press.
    var onButton: ((PadButton) -> Void)?

    private let hub: InputHub
    private let queue = DispatchQueue(label: "SwiftSaber.GameControllers", qos: .userInteractive)
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// Main-thread state.
    private var attached: [StreamID: GCController] = [:]
    private var engines: [StreamID: CHHapticEngine] = [:]
    /// Network-queue state (the controllers deliver their handlers on `queue`).
    private var estimators: [StreamID: AttitudeEstimator] = [:]

    init(hub: InputHub) {
        self.hub = hub
    }

    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.detach(c) }
        })
        for c in GCController.controllers() { attach(c) }
    }

    func stop() {
        guard running else { return }
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        for c in Array(attached.values) { detach(c) }
        withoutMotion = []
    }

    /// The controller streaming as `slot`, if any.
    func pad(for slot: StreamID) -> Pad? { pads.first { $0.id == slot } }

    // MARK: Connecting

    private static func name(of c: GCController) -> String {
        c.productCategory.isEmpty ? (c.vendorName ?? "Controller") : c.productCategory
    }

    private func attach(_ c: GCController) {
        guard !attached.values.contains(where: { $0 === c }) else { return }
        let name = Self.name(of: c)
        guard let motion = c.motion, motion.hasRotationRate else {
            NSLog("GameControllers: \(name) has no motion sensors")
            if !withoutMotion.contains(name) { withoutMotion.append(name) }
            installButtons(on: c)
            return
        }
        guard let slot = StreamID.controllers.first(where: { attached[$0] == nil }) else {
            NSLog("GameControllers: \(name) connected, but two controllers are already sabers")
            installButtons(on: c)
            return
        }
        NSLog("GameControllers: \(name) is \(slot)")
        attached[slot] = c
        c.handlerQueue = queue
        queue.async { self.estimators[slot] = AttitudeEstimator() }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        motion.valueChangedHandler = { [weak self] m in self?.handle(m, slot: slot) }
        installButtons(on: c)
        if let engine = c.haptics?.createEngine(withLocality: .default) {
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            try? engine.start()
            engines[slot] = engine
        }
        pads.append(Pad(id: slot, name: name, preferredHand: SaberAssignment.preferredHand(forControllerNamed: name)))
        pads.sort { $0.id < $1.id }
    }

    private func detach(_ c: GCController) {
        withoutMotion.removeAll { $0 == Self.name(of: c) }
        guard let slot = attached.first(where: { $0.value === c })?.key else { return }
        NSLog("GameControllers: \(Self.name(of: c)) disconnected")
        c.motion?.valueChangedHandler = nil
        if c.motion?.sensorsRequireManualActivation == true { c.motion?.sensorsActive = false }
        attached[slot] = nil
        engines[slot]?.stop(completionHandler: nil)
        engines[slot] = nil
        pads.removeAll { $0.id == slot }
        queue.async { self.estimators[slot] = nil }
        hub.forget(slot)
    }

    private func installButtons(on c: GCController) {
        func bind(_ button: GCControllerButtonInput?, _ action: PadButton) {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                DispatchQueue.main.async { self?.onButton?(action) }
            }
        }
        if let pad = c.extendedGamepad {
            bind(pad.buttonMenu, .menu)
            bind(pad.buttonA, .confirm)
            bind(pad.buttonB, .back)
            bind(pad.buttonY, .recenter)
        } else if let pad = c.microGamepad {
            bind(pad.buttonMenu, .menu)
            bind(pad.buttonA, .confirm)
            bind(pad.buttonX, .recenter)
        }
    }

    // MARK: Motion (on `queue`)

    private func handle(_ m: GCMotion, slot: StreamID) {
        let now = CACurrentMediaTime()
        let sample: MotionSample
        if m.hasAttitude && m.hasGravityAndUserAcceleration {
            // Some controllers fuse their sensors themselves.
            let q = m.attitude
            sample = MotionSample(time: now, attitude: Quat(x: q.x, y: q.y, z: q.z, w: q.w),
                                  gravity: Vec3(m.gravity.x, m.gravity.y, m.gravity.z))
        } else {
            guard var estimator = estimators[slot] else { return }
            let r = m.rotationRate
            let a: Vec3
            if m.hasGravityAndUserAcceleration {
                a = Vec3(m.gravity.x + m.userAcceleration.x, m.gravity.y + m.userAcceleration.y, m.gravity.z + m.userAcceleration.z)
            } else {
                a = Vec3(m.acceleration.x, m.acceleration.y, m.acceleration.z)
            }
            estimator.update(rotationRate: Vec3(r.x, r.y, r.z), acceleration: a, time: now)
            estimators[slot] = estimator
            guard estimator.isInitialized else { return }
            sample = MotionSample(time: now, attitude: estimator.attitude, gravity: estimator.gravity)
        }
        hub.ingest(stream: slot, sample: sample)
    }

    // MARK: Feedback

    /// A short rumble when the controller's saber hits something (0...1).
    func sendHaptic(_ intensity: Float, slot: StreamID) {
        DispatchQueue.main.async {
            guard let engine = self.engines[slot] else { return }
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.3, min(1, intensity))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
            ], relativeTime: 0)
            do {
                let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                try? engine.start()
            }
        }
    }

    /// Lights the controller (DualSense / DualShock light bar) in its saber's colour.
    func setLight(_ color: NeonColor?, slot: StreamID) {
        guard let light = attached[slot]?.light else { return }
        if let color {
            light.color = GCColor(red: Float(color.r), green: Float(color.g), blue: Float(color.b))
        } else {
            light.color = GCColor(red: 0.2, green: 0.2, blue: 0.2)
        }
    }
}
