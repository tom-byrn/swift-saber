import Foundation
import QuartzCore
import SaberCore

/// Where a saber gets its motion from.
enum SaberSource: Equatable {
    case stream(StreamID)
    /// Whichever calibrated AirPod bud is currently streaming. AirPods deliver motion from
    /// one bud at a time and can hand the stream over to the other bud.
    case anyAirPod
    case mouse
}

struct StreamInfo: Identifiable, Equatable {
    var id: StreamID
    var rate: Double
    var isLive: Bool
    var isCalibrated: Bool
}

/// Thread-safe hub that turns raw AirPods / mouse input into saber directions.
///
/// - AirPods samples arrive on the motion queue.
/// - Mouse targets arrive on the main thread.
/// - The renderer reads saber poses on the SceneKit render thread.
final class InputHub {
    private struct Stream {
        var filter = SaberPoseFilter()
        var calibration: SaberCalibration?
        var lastRaw: MotionSample?
        var arrivals: [Double] = []
    }

    private let lock = NSLock()
    private var streams: [StreamID: Stream] = [:]
    private var mouseTarget: Vec3?
    private var mouseTime: Double = 0
    private var mouseFilters: [Hand: SaberPoseFilter] = [
        .left: SaberPoseFilter(maxPrediction: 0, smoothing: 0.012),
        .right: SaberPoseFilter(maxPrediction: 0, smoothing: 0.012),
    ]
    private var assignment: [Hand: SaberSource] = [:]
    private var sensitivity: Double = 1
    private var airPodLatency: Double = 0.04
    /// The phone streams over Wi-Fi at ~100 Hz, so it arrives sooner than AirPods motion.
    private let phoneLatency: Double = 0.025
    private var rawObserver: ((StreamID, MotionSample) -> Void)?

    /// A stream counts as live if it delivered a sample within this window.
    static let liveWindow: Double = 0.6

    // MARK: Configuration

    func configure(sensitivity: Double, airPodLatency: Double) {
        lock.lock(); defer { lock.unlock() }
        self.sensitivity = sensitivity
        self.airPodLatency = airPodLatency
    }

    func setAssignment(_ a: [Hand: SaberSource]) {
        lock.lock(); defer { lock.unlock() }
        assignment = a
        for k in streams.keys { streams[k]!.filter.reset() }
    }

    func currentAssignment() -> [Hand: SaberSource] {
        lock.lock(); defer { lock.unlock() }
        return assignment
    }

    /// Receives every raw AirPods sample (on the motion queue). Used by calibration.
    func setRawObserver(_ observer: ((StreamID, MotionSample) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        rawObserver = observer
    }

    func setCalibration(_ c: SaberCalibration?, for id: StreamID) {
        lock.lock(); defer { lock.unlock() }
        streams[id, default: Stream()].calibration = c
        streams[id]!.filter.reset()
    }

    func calibration(for id: StreamID) -> SaberCalibration? {
        lock.lock(); defer { lock.unlock() }
        return streams[id]?.calibration
    }

    func clearCalibrations() {
        lock.lock(); defer { lock.unlock() }
        for k in streams.keys { streams[k]!.calibration = nil }
    }

    /// Re-centres every calibrated stream to its current pose ("point at the screen and press R").
    func recenter() {
        lock.lock(); defer { lock.unlock() }
        for (k, s) in streams {
            guard var c = s.calibration, let raw = s.lastRaw else { continue }
            c.recenter(to: raw.attitude)
            streams[k]!.calibration = c
            streams[k]!.filter.reset()
        }
    }

    // MARK: Input

    func ingest(stream id: StreamID, sample: MotionSample) {
        var observer: ((StreamID, MotionSample) -> Void)?
        lock.lock()
        var s = streams[id] ?? Stream()
        s.lastRaw = sample
        s.arrivals.append(sample.time)
        if s.arrivals.count > 40 { s.arrivals.removeFirst(s.arrivals.count - 40) }
        if let c = s.calibration {
            let dir = applySensitivity(c.direction(for: sample.attitude), gain: sensitivity)
            s.filter.add(time: sample.time, direction: dir)
        }
        streams[id] = s
        observer = rawObserver
        lock.unlock()
        observer?(id, sample)
    }

    /// Mouse/trackpad aim point in world space (on the plane in front of the player).
    func setMouseTarget(_ p: Vec3) {
        lock.lock(); defer { lock.unlock() }
        mouseTarget = p
        mouseTime = CACurrentMediaTime()
    }

    // MARK: Queries

    func streamInfos(now: Double = CACurrentMediaTime()) -> [StreamInfo] {
        lock.lock(); defer { lock.unlock() }
        return streams.map { id, s in
            let recent = s.arrivals.filter { now - $0 < 1.0 }
            let live = (s.arrivals.last.map { now - $0 < Self.liveWindow } ?? false)
            return StreamInfo(id: id, rate: Double(recent.count), isLive: live, isCalibrated: s.calibration != nil)
        }.sorted { $0.id < $1.id }
    }

    func liveStreams(now: Double = CACurrentMediaTime()) -> [StreamID] {
        streamInfos(now: now).filter { $0.isLive }.map { $0.id }
    }

    /// Saber states for the simulation / renderer at time `now`.
    func saberInputs(now: Double) -> [SaberInput] {
        lock.lock(); defer { lock.unlock() }
        var out: [SaberInput] = []
        for hand in Hand.allCases {
            guard let source = assignment[hand] else {
                out.append(SaberInput(hand: hand, direction: Vec3.forward, active: false))
                continue
            }
            var resolved = source
            if source == .anyAirPod {
                // Most recently active calibrated bud.
                let candidates = StreamID.airPods.compactMap { id -> (StreamID, Double)? in
                    guard let s = streams[id], s.calibration != nil, let t = s.filter.lastSampleTime else { return nil }
                    return (id, t)
                }
                if let best = candidates.max(by: { $0.1 < $1.1 }) {
                    resolved = .stream(best.0)
                } else {
                    out.append(SaberInput(hand: hand, direction: Vec3.forward, active: false))
                    continue
                }
            }
            switch resolved {
            case .anyAirPod:
                out.append(SaberInput(hand: hand, direction: Vec3.forward, active: false))
            case .stream(let id):
                // `filter` is a reference type, so querying it advances its smoothing state in place.
                guard let s = streams[id], s.calibration != nil,
                      let last = s.filter.lastSampleTime, now - last < Self.liveWindow,
                      let dir = s.filter.direction(at: now) else {
                    out.append(SaberInput(hand: hand, direction: Vec3.forward, active: false))
                    continue
                }
                out.append(SaberInput(hand: hand, direction: dir, active: true, latency: id == .phone ? phoneLatency : airPodLatency))
            case .mouse:
                guard let target = mouseTarget else {
                    out.append(SaberInput(hand: hand, direction: Vec3.forward, active: false))
                    continue
                }
                let filter = mouseFilters[hand]!
                let pivot = Arena.pivot(for: hand)
                filter.add(time: now, direction: (target - pivot).normalized)
                let dir = filter.direction(at: now) ?? (target - pivot).normalized
                out.append(SaberInput(hand: hand, direction: dir, active: true, latency: 0.008))
            }
        }
        return out
    }
}
