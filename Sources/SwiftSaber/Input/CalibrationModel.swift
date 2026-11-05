import Foundation
import QuartzCore
import SaberCore

/// Drives the AirPods calibration screen.
/// Each live AirPod stream runs its own `CalibrationProcess`; all of them advance together.
final class CalibrationModel: ObservableObject {
    enum Phase: Equatable {
        case detecting
        case calibrating
        case done
    }

    struct StreamState: Identifiable, Equatable {
        var id: StreamID
        var live: Bool
        var rate: Double
        var step: CalibrationProcess.Step?
        var progress: Double
    }

    @Published private(set) var phase: Phase = .detecting
    @Published private(set) var streams: [StreamState] = []
    @Published private(set) var failure: String?
    /// The step every calibrating stream is (at least) on.
    @Published private(set) var currentStep: CalibrationProcess.Step = .pointAtScreen

    var onStepCompleted: (() -> Void)?
    var onFinished: (([StreamID: SaberCalibration]) -> Void)?

    private let hub: InputHub
    private let lock = NSLock()
    private var processes: [StreamID: CalibrationProcess] = [:]
    private var timer: Timer?
    private var lastSteps: [StreamID: CalibrationProcess.Step] = [:]

    init(hub: InputHub) {
        self.hub = hub
    }

    func activate() {
        hub.setRawObserver { [weak self] id, sample in
            guard let self else { return }
            self.lock.lock()
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

    /// Starts calibrating every stream that is currently live.
    func begin() {
        let ids = hub.liveStreams()
        guard !ids.isEmpty else { return }
        lock.lock()
        processes = Dictionary(uniqueKeysWithValues: ids.map { ($0, CalibrationProcess()) })
        lastSteps = [:]
        lock.unlock()
        failure = nil
        phase = .calibrating
        currentStep = .pointAtScreen
    }

    func restart() {
        lock.lock()
        processes.removeAll()
        lock.unlock()
        failure = nil
        phase = .detecting
        currentStep = .pointAtScreen
    }

    private func refresh() {
        let infos = hub.streamInfos()
        lock.lock()
        let snapshot = processes.mapValues { ($0.step, $0.holdProgress, $0.result) }
        lock.unlock()

        var states: [StreamState] = []
        var ids = Set(infos.map { $0.id })
        ids.formUnion(snapshot.keys)
        for id in ids.sorted() {
            let info = infos.first { $0.id == id }
            let p = snapshot[id]
            states.append(StreamState(id: id, live: info?.isLive ?? false, rate: info?.rate ?? 0,
                                      step: p?.0, progress: p?.1 ?? 0))
        }
        if states != streams { streams = states }

        guard phase == .calibrating, !snapshot.isEmpty else { return }

        // Any failure stops the run.
        for (_, v) in snapshot {
            if case .failed(let msg) = v.0 {
                failure = msg
                lock.lock()
                processes.removeAll()
                lock.unlock()
                phase = .detecting
                return
            }
        }

        // Sound a chime when a stream advances.
        for (id, v) in snapshot where lastSteps[id] != v.0 {
            if lastSteps[id] != nil { onStepCompleted?() }
            lastSteps[id] = v.0
        }

        let order: [CalibrationProcess.Step] = [.pointAtScreen, .pointUp, .confirmCenter, .done]
        let minIndex = snapshot.values.map { v in order.firstIndex(of: v.0) ?? 0 }.min() ?? 0
        let step = order[minIndex]
        if step != currentStep { currentStep = step }

        if step == .done {
            var results: [StreamID: SaberCalibration] = [:]
            for (id, v) in snapshot { if let r = v.2 { results[id] = r } }
            lock.lock()
            processes.removeAll()
            lock.unlock()
            phase = .done
            onFinished?(results)
        }
    }

    /// Instruction text for the current step.
    static func instruction(for step: CalibrationProcess.Step, count: Int) -> (title: String, detail: String) {
        let both = count > 1
        switch step {
        case .pointAtScreen:
            return ("Point at the screen",
                    both ? "Hold an AirPod in each fist, arms relaxed in front of you, and point both fists at the centre of the screen. Hold still."
                         : "Hold the AirPod in your fist and point it at the centre of the screen like a sword hilt. Hold still.")
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
