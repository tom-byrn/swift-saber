import XCTest
@testable import SaberCore

/// Simulated AirPod: swings side to side and up/down, sampled at 25 Hz and delivered over a
/// jittery, clumpy link, then rendered at 120 fps.
private struct SwingSimulation {
    var rate = 25.0
    var duration = 6.0
    var baseLatency = 0.015
    var maxJitter = 0.035
    var sensorClockOffset = -12_345.0
    /// Attitude quaternion convention of the simulated sensor.
    var deviceToWorld = true
    var seed: UInt64 = 7

    /// Device→world attitude at time t.
    func pose(_ t: Double) -> Quat {
        let yaw = 0.9 * sin(2 * .pi * 1.1 * t)
        let pitch = 0.5 * sin(2 * .pi * 0.8 * t + 0.7)
        return Quat(axis: .unitY, angle: yaw) * Quat(axis: .unitX, angle: pitch)
    }

    func direction(_ q: Quat) -> Vec3 { applySensitivity(q.rotate(.forward), gain: 1.15) }

    /// Body-frame angular velocity (rad/s) at time t.
    func bodyRate(_ t: Double) -> Vec3 {
        let e = 1e-5
        let d = pose(t).conjugate * pose(t + e)
        return d.axis * (d.angle / e)
    }

    func samples() -> [MotionSample] {
        var rng = SeededRandom(seed: seed)
        var out: [MotionSample] = []
        var lastArrival = 0.0
        var t = 0.5
        while t < duration {
            // Clumpy delivery: random delay, and samples can't overtake each other.
            let arrival = max(t + baseLatency + rng.unit() * maxJitter, lastArrival)
            lastArrival = arrival
            let q = pose(t)
            out.append(MotionSample(time: arrival,
                                    attitude: deviceToWorld ? q : q.conjugate,
                                    gravity: .zero,
                                    sensorTime: t - sensorClockOffset,
                                    rotationRate: bodyRate(t)))
            t += 1 / rate
        }
        return out
    }

    struct Result { var stutter: Double; var error: Double }

    /// Renders the stream at 120 fps. `smooth` selects the new pipeline.
    func run(smooth: Bool) -> Result {
        let all = samples()
        let filter = smooth ? SaberPoseFilter(maxPrediction: 0.05, smoothing: 0.022, predictionTail: 0.03)
                            : SaberPoseFilter()
        var processor = SensorMotionProcessor()
        let dirFor: (Quat) -> Vec3 = { q in direction(deviceToWorld ? q : q.conjugate) }
        var next = 0
        var frames: [Vec3] = []
        var errorSum = 0.0, errorCount = 0
        var now = 1.0
        while now < duration {
            while next < all.count, all[next].time <= now {
                let s = all[next]
                if smooth {
                    let r = processor.process(s, direction: dirFor)
                    filter.add(time: r.time, direction: dirFor(s.attitude), angularVelocity: r.angularVelocity)
                } else {
                    filter.add(time: s.time, direction: dirFor(s.attitude))
                }
                next += 1
            }
            if let d = filter.direction(at: now) {
                frames.append(d)
                if now > 2 {
                    // Compare with where the blade really was, allowing for the fixed link latency.
                    errorSum += d.angle(to: direction(pose(now - baseLatency)))
                    errorCount += 1
                }
            }
            now += 1.0 / 120
        }
        // Stutter: RMS change in per-frame velocity (a smooth swing changes velocity gradually).
        var sum = 0.0, n = 0
        for i in 2..<frames.count {
            let v1 = frames[i - 1] - frames[i - 2], v2 = frames[i] - frames[i - 1]
            sum += (v2 - v1).lengthSquared
            n += 1
        }
        return Result(stutter: (sum / Double(n)).squareRoot(), error: errorSum / Double(errorCount))
    }
}

final class MotionSmoothingTests: XCTestCase {
    func testSensorClockRecoversEvenSpacing() {
        let sim = SwingSimulation()
        var clock = SensorClock()
        let mapped = sim.samples().map { clock.map(sensorTime: $0.sensorTime, arrival: $0.time) }
        let gaps = zip(mapped.dropFirst(10), mapped.dropFirst(11)).map { $1 - $0 }
        for g in gaps { XCTAssertEqual(g, 1 / sim.rate, accuracy: 0.002) }
        // Never later than arrival, and close to the true measurement time + fastest latency.
        for (m, s) in zip(mapped, sim.samples()) { XCTAssertLessThanOrEqual(m, s.time + 1e-9) }
        XCTAssertEqual(clock.offset ?? 0, sim.sensorClockOffset + sim.baseLatency, accuracy: 0.01)
    }

    func testSensorClockFallsBackWithoutTimestamps() {
        var clock = SensorClock()
        XCTAssertEqual(clock.map(sensorTime: nil, arrival: 3.5), 3.5)
        XCTAssertEqual(clock.map(sensorTime: 0, arrival: 4.5), 4.5)
    }

    func testSensorClockResyncsAfterJump() {
        var clock = SensorClock()
        for i in 0..<20 { _ = clock.map(sensorTime: 100 + Double(i) * 0.04, arrival: 10 + Double(i) * 0.04) }
        // Sensor clock restarts (e.g. the other bud takes over).
        let t = clock.map(sensorTime: 5, arrival: 11)
        XCTAssertEqual(t, 11, accuracy: 1e-9)
        XCTAssertEqual(clock.map(sensorTime: 5.04, arrival: 11.04), 11.04, accuracy: 1e-6)
    }

    func testDetectsGyroConvention() {
        for deviceToWorld in [true, false] {
            var sim = SwingSimulation()
            sim.deviceToWorld = deviceToWorld
            var processor = SensorMotionProcessor()
            for s in sim.samples() { _ = processor.process(s, direction: { $0.rotate(.forward) }) }
            XCTAssertEqual(processor.gyro.convention, deviceToWorld ? .rightPositive : .leftNegative)
        }
    }

    func testIgnoresUselessGyro() {
        var processor = SensorMotionProcessor()
        var last: Vec3? = .zero
        for s in SwingSimulation().samples() {
            var z = s
            z.rotationRate = .zero
            last = processor.process(z, direction: { $0.rotate(.forward) }).angularVelocity
        }
        XCTAssertNil(processor.gyro.convention)
        XCTAssertNil(last)
    }

    func testGyroVelocityMatchesMotion() {
        let sim = SwingSimulation()
        var processor = SensorMotionProcessor()
        var checked = 0
        for s in sim.samples() {
            let dirFor: (Quat) -> Vec3 = { sim.direction($0) }
            guard let w = processor.process(s, direction: dirFor).angularVelocity, w.length > 0.5 else { continue }
            let t = s.sensorTime! + sim.sensorClockOffset
            let d0 = sim.direction(sim.pose(t)), d1 = sim.direction(sim.pose(t + 0.001))
            let truth = d0.cross(d1).normalized * (d0.angle(to: d1) / 0.001)
            XCTAssertLessThan((w - truth).length / truth.length, 0.05)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)
    }

    func testSmoothPipelineStuttersLess() {
        for seed: UInt64 in [1, 7, 42] {
            var sim = SwingSimulation()
            sim.seed = seed
            let old = sim.run(smooth: false)
            let new = sim.run(smooth: true)
            print(String(format: "seed %llu  stutter old %.5f new %.5f (%.0f%%)  error old %.1f° new %.1f°",
                         seed, old.stutter, new.stutter, 100 * new.stutter / old.stutter,
                         degrees(old.error), degrees(new.error)))
            XCTAssertLessThan(new.stutter, old.stutter * 0.6, "seed \(seed)")
            XCTAssertLessThan(new.error, old.error * 1.1, "seed \(seed)")
        }
    }

    func testFilterDropsOutOfOrderSamples() {
        let f = SaberPoseFilter(maxPrediction: 0, smoothing: 0)
        f.add(time: 1.0, direction: Vec3(1, 0, 0))
        f.add(time: 0.9, direction: Vec3(0, 1, 0))
        XCTAssertEqual(f.direction(at: 1.0)!.x, 1, accuracy: 1e-9)
        XCTAssertEqual(f.lastSampleTime, 1.0)
    }

    func testPredictionTailIsContinuous() {
        let f = SaberPoseFilter(maxPrediction: 0.05, predictionTail: 0.03)
        XCTAssertEqual(f.lookAhead(0.03), 0.03, accuracy: 1e-12)
        XCTAssertEqual(f.lookAhead(0.05), 0.05, accuracy: 1e-12)
        XCTAssertEqual(f.lookAhead(0.0501), 0.0501, accuracy: 1e-6)
        XCTAssertLessThan(f.lookAhead(1), 0.08 + 1e-9)
        // Old behaviour without a tail.
        XCTAssertEqual(SaberPoseFilter().lookAhead(0.2), 0.045)
    }
}
