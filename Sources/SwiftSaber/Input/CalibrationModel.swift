import Foundation
import QuartzCore
import SaberCore

/// Drives the AirPods calibration screen.
/// Each live AirPod stream runs its own `CalibrationProcess`; all of them advance together.
/// After each pose is captured the run waits for the player to press Next (on screen,
/// Return / Space on the keyboard, or the Next button on the iPhone).
final class CalibrationModel: ObservableObject {
    enum Phase: Equatable {
        case detecting
        case calibrating
        case done
    }

    /// Live sensor readout shown while calibrating.
    struct Reading: Equatable {
        /// Raw attitude as yaw / pitch / roll in degrees (sensor's own reference frame).
        var yaw: Double
        var pitch: Double
        var roll: Double
        /// Gravity in the device frame (g).
        var gravity: Vec3
        /// Angle from the captured screen pose, once captured.
        var fromScreen: Double?
        /// How much the hand moved over the last ~0.6 s (degrees).
        var motion: Double?
        /// Why the hold isn't counting, if the hand is steady but in the wrong place.
        var hint: String?
    }

    struct StreamState: Identifiable, Equatable {
        var id: StreamID
        var live: Bool
        var rate: Double
        var step: CalibrationProcess.Step?
        var progress: Double
        /// This stream's pose for the current step is captured; waiting for Next.
        var awaitingNext: Bool = false
        var reading: Reading?
    }

    @Published private(set) var phase: Phase = .detecting {
        didSet { if phase != oldValue { onPhaseChanged?(phase) } }
    }
    @Published private(set) var streams: [StreamState] = []
    @Published private(set) var failure: String?
    /// The step every calibrating stream is (at least) on.
    @Published private(set) var currentStep: CalibrationProcess.Step = .pointAtScreen
    /// Every stream has captured the current pose: the Next button is enabled.
    @Published private(set) var canAdvance = false

    var onStepCompleted: (() -> Void)?
    var onFinished: (([StreamID: SaberCalibration]) -> Void)?
    var onPhaseChanged: ((Phase) -> Void)?

    private let hub: InputHub
    private let lock = NSLock()
    private var processes: [StreamID: CalibrationProcess] = [:]
    private var latestSamples: [StreamID: MotionSample] = [:]
    private var timer: Timer?
    private var lastSteps: [StreamID: CalibrationProcess.Step] = [:]
    private var lastAwaiting: [StreamID: Bool] = [:]

    init(hub: InputHub) {
        self.hub = hub
    }

    func activate() {
        hub.setRawObserver { [weak self] id, sample in
            guard let self else { return }
            self.lock.lock()
            self.latestSamples[id] = sample
            self.processes[id]?.add(sample)
            self.lock.unlock()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func deactivate() {
        hub.setRawObserver(nil)
        timer?.invalidate()
        timer = nil
    }

    var liveStreamIDs: [StreamID] { streams.filter { $0.live }.map { $0.id } }

    /// Starts calibrating the given streams (the devices about to become sabers; see
    /// `AppModel.beginCalibration()`).
    func begin(streams ids: [StreamID]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        processes = Dictionary(uniqueKeysWithValues: ids.map { ($0, CalibrationProcess()) })
        lastSteps = [:]
        lastAwaiting = [:]
        lock.unlock()
        failure = nil
        canAdvance = false
        phase = .calibrating
        currentStep = .pointAtScreen
    }

    /// Moves every stream on to the next pose once they have all captured the current one.
    func next() {
        guard phase == .calibrating else { return }
        lock.lock()
        let ready = !processes.isEmpty && processes.values.allSatisfy { $0.isAwaitingNext }
        if ready { for p in processes.values { p.advance() } }
        lock.unlock()
        if ready {
            canAdvance = false
            refresh()
        }
    }

    func restart() {
        lock.lock()
        processes.removeAll()
        lock.unlock()
        failure = nil
        canAdvance = false
        phase = .detecting
        currentStep = .pointAtScreen
    }

    private struct ProcessSnapshot {
        var step: CalibrationProcess.Step
        var progress: Double
        var result: SaberCalibration?
        var awaiting: Bool
        var fromScreen: Double?
        var motion: Double
        var hint: String?
    }

    private func refresh() {
        let infos = hub.streamInfos()
        lock.lock()
        let snapshot = processes.mapValues {
            ProcessSnapshot(step: $0.step, progress: $0.holdProgress, result: $0.result, awaiting: $0.isAwaitingNext,
                            fromScreen: $0.degreesFromScreen, motion: $0.motionDegrees, hint: $0.poseHint)
        }
        let samples = latestSamples
        lock.unlock()

        var states: [StreamState] = []
        var ids = Set(infos.map { $0.id })
        ids.formUnion(snapshot.keys)
        for id in ids.sorted() {
            let info = infos.first { $0.id == id }
            let p = snapshot[id]
            var reading: Reading?
            if let sample = samples[id] {
                let e = Self.euler(sample.attitude)
                reading = Reading(yaw: e.yaw, pitch: e.pitch, roll: e.roll, gravity: sample.gravity,
                                  fromScreen: p?.fromScreen, motion: p?.motion, hint: p?.hint)
            }
            states.append(StreamState(id: id, live: info?.isLive ?? false, rate: info?.rate ?? 0,
                                      step: p?.step, progress: p?.progress ?? 0,
                                      awaitingNext: p?.awaiting ?? false, reading: reading))
        }
        if states != streams { streams = states }

        guard phase == .calibrating, !snapshot.isEmpty else { return }

        // Any failure stops the run.
        for (_, v) in snapshot {
            if case .failed(let msg) = v.step {
                failure = msg
                lock.lock()
                processes.removeAll()
                lock.unlock()
                canAdvance = false
                phase = .detecting
                return
            }
        }

        // Sound a chime when a stream captures a pose (or finishes).
        for (id, v) in snapshot {
            let captured = (v.awaiting && lastAwaiting[id] != true) || (v.step == .done && lastSteps[id] != .done)
            if captured { onStepCompleted?() }
            lastSteps[id] = v.step
            lastAwaiting[id] = v.awaiting
        }

        let order: [CalibrationProcess.Step] = [.pointAtScreen, .pointUp, .confirmCenter, .done]
        let minIndex = snapshot.values.map { v in order.firstIndex(of: v.step) ?? 0 }.min() ?? 0
        let step = order[minIndex]
        if step != currentStep { currentStep = step }
        let ready = snapshot.values.allSatisfy { $0.awaiting }
        if ready != canAdvance { canAdvance = ready }

        if step == .done {
            var results: [StreamID: SaberCalibration] = [:]
            for (id, v) in snapshot { if let r = v.result { results[id] = r } }
            lock.lock()
            processes.removeAll()
            lock.unlock()
            canAdvance = false
            phase = .done
            onFinished?(results)
        }
    }

    /// Yaw / pitch / roll (degrees) of a quaternion, Z-Y-X order.
    static func euler(_ attitude: Quat) -> (yaw: Double, pitch: Double, roll: Double) {
        let q = attitude.normalized
        let roll = atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
        let pitch = asin(clamp(2 * (q.w * q.y - q.z * q.x), -1, 1))
        let yaw = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        return (degrees(yaw), degrees(pitch), degrees(roll))
    }

    /// What the setup screen says about the devices it can see.
    static func setupHint(mode: InputMode, planned: [Hand: SaberDevice], live: Set<SaberDevice>,
                          grip: AirPodGrip, name: (SaberDevice) -> String) -> String {
        let pod = grip == .closedCase ? "AirPods case" : "AirPod"
        let wake = grip == .closedCase ? "connect the case" : "move the bud around to wake it"
        let motion = planned.filter { $0.value != .mouse }
        let hasPod = live.contains(.airPod) || live.contains(.airPodCase)
        let hasPhone = live.contains(.iOS1) || live.contains(.iOS2)
        let phone = "open Swift Saber on your iPhone or iPad (same Wi-Fi)"
        switch mode {
        case .airpodAndPhone:
            if hasPhone && hasPod {
                let phoneName = planned.values.first(where: \.isPhone).map { name($0) } ?? "phone"
                return "\(pod) and \(phoneName) are both streaming — you'll get two sabers."
            }
            if hasPhone { return "Phone connected. Waiting for \(pod) motion — \(wake)." }
            if hasPod { return "\(pod) streaming. Waiting for an iPhone or iPad — \(phone)." }
            return "Waiting for your \(pod) and iPhone or iPad…"
        case .twoPhones:
            switch motion.count {
            case 2: return "Two devices streaming — you'll get two sabers."
            case 1: return "One device connected. For the second saber, \(phone)."
            default: return "Waiting for two iPhones or iPads — \(phone)."
            }
        case .phone:
            return hasPhone ? "\(name(motion.values.first ?? .iOS1)) connected." : "To start, \(phone)."
        case .controllers:
            switch motion.count {
            case 2: return "Two controllers streaming — you'll get two sabers."
            case 1: return "One controller streaming. Pair another for a second saber (System Settings › Bluetooth)."
            default: return "Pair a DualSense, DualShock 4 or Joy-Con with this Mac (System Settings › Bluetooth), then press any button on it."
            }
        case .automatic:
            switch motion.count {
            case 2: return "Two sabers ready to calibrate. Not the right hands? Swap them."
            case 1: return "One saber so far. Add a second device for two sabers — an iPhone or iPad running Swift Saber, an AirPod or a motion controller."
            default: return "Connect AirPods, \(phone), or pair a motion controller. Each device shows up here as it starts streaming."
            }
        default:
            if hasPod { return "\(pod) streaming — you're ready to calibrate." }
            return grip == .closedCase ? "Connect the case to start its motion stream." : "Move the AirPod around a little to wake it up."
        }
    }

    /// Position of a calibration step, for "has this stream finished the current step" checks.
    static func stepIndex(_ s: CalibrationProcess.Step?) -> Int {
        switch s {
        case .pointAtScreen: return 0
        case .pointUp: return 1
        case .confirmCenter: return 2
        case .done: return 3
        default: return 0
        }
    }

    /// Instruction text for the current step.
    static func instruction(for step: CalibrationProcess.Step, count: Int, grip: AirPodGrip = .bud, awaitingNext: Bool = false) -> (title: String, detail: String) {
        let both = count > 1
        let thing = grip == .closedCase ? "case" : "device"
        if awaitingNext {
            switch step {
            case .pointAtScreen:
                return ("Screen pose captured",
                        "Take your time. Press Next (Return / Space, or NEXT on your phone or controller), then raise \(both ? "both fists" : "your fist") to point at the ceiling.")
            case .pointUp:
                return ("Ceiling pose captured",
                        "Press Next (Return / Space, or NEXT on your phone or controller), then point back at the centre of the screen.")
            default:
                break
            }
        }
        switch step {
        case .pointAtScreen:
            return ("Point at the screen",
                    both ? "Hold a device in each fist, arms relaxed in front of you, and point both fists at the centre of the screen. Hold still."
                         : "Hold the \(thing) in your fist and point it at the centre of the screen like a sword hilt. Hold still.")
        case .pointUp:
            return ("Now point at the ceiling",
                    both ? "Raise both fists so they point straight up, without twisting your wrists. Hold still."
                         : "Raise your fist so it points straight up, without twisting your wrist. Hold still.")
        case .confirmCenter:
            return ("Back to the centre", "Point at the centre of the screen once more and hold still.")
        case .done:
            return ("Calibrated", "Your saber\(both ? "s are" : " is") live. Give it a swing!")
        case .failed(let msg):
            return ("Let's try that again", msg)
        }
    }
}
