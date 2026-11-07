import XCTest
@testable import SaberCore

final class MathTests: XCTestCase {
    func testQuaternionRotation() {
        let q = Quat(axis: .unitX, angle: .pi / 2)
        let v = q.rotate(Vec3(0, 0, -1))
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.y, 1, accuracy: 1e-9)
        XCTAssertEqual(v.z, 0, accuracy: 1e-9)
    }

    func testFromTo() {
        let a = Vec3(0, 0, -1), b = Vec3(1, 1, 0).normalized
        let q = Quat(from: a, to: b)
        let r = q.rotate(a)
        XCTAssertEqual((r - b).length, 0, accuracy: 1e-9)
    }

    func testArrowRotation() {
        // Rotating a downward arrow by the arrow rotation must give the cut direction.
        for d in CutDirection.allCases where d != .any {
            let a = d.arrowRotation
            let x = sin(a), y = -cos(a)
            XCTAssertEqual(x, d.vector.x, accuracy: 1e-6, "\(d)")
            XCTAssertEqual(y, d.vector.y, accuracy: 1e-6, "\(d)")
        }
    }
}

final class CalibrationTests: XCTestCase {
    /// Simulates a sensor held in an arbitrary grip in a z-up world.
    func simulate(deviceToWorld: Bool, grip: Quat, heading: Double) -> (center: [MotionSample], up: [MotionSample], attitude: (Vec3) -> Quat) {
        // Player basis inside the sensor's world frame: heading rotates around world z.
        let headingQ = Quat(axis: .unitZ, angle: heading)
        let fwdWorld = headingQ.rotate(Vec3(0, 1, 0))
        let rightWorld = headingQ.rotate(Vec3(1, 0, 0))
        let upWorld = Vec3(0, 0, 1)
        // Device-to-world rotation for a hand pointing in player direction `p`.
        func w(for p: Vec3) -> Quat {
            let pw = (rightWorld * p.x + upWorld * p.y + (-fwdWorld) * p.z).normalized
            // Grip maps device frame to "hand frame" whose -z points along the hand; then align the hand.
            let align = Quat(from: Vec3(0, 0, -1), to: pw)
            // For pointing straight up the shortest-arc is fine; keep consistent roll by composing.
            return align * grip
        }
        func attitude(_ p: Vec3) -> Quat {
            let W = w(for: p)
            return deviceToWorld ? W : W.conjugate
        }
        func gravity(_ p: Vec3) -> Vec3 {
            let W = w(for: p)
            return W.conjugate.rotate(Vec3(0, 0, -1))
        }
        let center = (0..<10).map { MotionSample(time: Double($0) * 0.04, attitude: attitude(Vec3(0, 0, -1)), gravity: gravity(Vec3(0, 0, -1))) }
        let upDir = Vec3(0, 0.999, -0.04).normalized
        let up = (0..<10).map { MotionSample(time: 2 + Double($0) * 0.04, attitude: attitude(upDir), gravity: gravity(upDir)) }
        return (center, up, attitude)
    }

    func check(deviceToWorld: Bool) {
        let grip = Quat(axis: Vec3(0.3, -0.7, 0.4), angle: 1.1)
        let sim = simulate(deviceToWorld: deviceToWorld, grip: grip, heading: 0.8)
        guard case .success(let cal) = SaberCalibration.solve(center: sim.center, up: sim.up) else {
            return XCTFail("calibration failed")
        }
        XCTAssertEqual(cal.deviceToWorld, deviceToWorld)
        // Pointing right should read as +x, pointing down as -y.
        let targets = [Vec3(1, 0, -1).normalized, Vec3(0, -1, -1).normalized, Vec3(-0.5, 0.3, -1).normalized, Vec3(0, 0, -1)]
        for t in targets {
            let d = cal.direction(for: sim.attitude(t))
            XCTAssertLessThan(d.angle(to: t), radians(4), "target \(t) got \(d)")
        }
    }

    func testCalibrationDeviceToWorld() { check(deviceToWorld: true) }
    func testCalibrationWorldToDevice() { check(deviceToWorld: false) }

    func testCalibrationProcess() {
        let grip = Quat(axis: Vec3(1, 2, 3), angle: 0.7)
        let sim = simulate(deviceToWorld: true, grip: grip, heading: -0.3)
        let p = CalibrationProcess()
        var t = 0.0
        func feed(_ s: MotionSample, seconds: Double) {
            let end = t + seconds
            while t < end {
                p.add(MotionSample(time: t, attitude: s.attitude, gravity: s.gravity))
                t += 0.04
            }
        }
        feed(sim.center[0], seconds: 1.5)
        XCTAssertEqual(p.step, .pointUp)
        feed(sim.up[0], seconds: 1.5)
        XCTAssertEqual(p.step, .confirmCenter)
        feed(sim.center[0], seconds: 1.5)
        XCTAssertEqual(p.step, .done)
        XCTAssertNotNil(p.result)
    }
}

final class LevelTests: XCTestCase {
    func testAllDifficultiesGenerate() {
        for mode in PlayMode.allCases {
            for d in Difficulty.allCases {
                let map = LevelDesigner.beatmap(difficulty: d, mode: mode)
                XCTAssertGreaterThan(map.notes.count, 40, "\(d) \(mode)")
                // Notes sorted by time
                XCTAssertEqual(map.notes.map { $0.time }, map.notes.map { $0.time }.sorted())
                // Valid grid
                for n in map.notes {
                    XCTAssert((0...3).contains(n.column))
                    XCTAssert((0...2).contains(n.row))
                }
                // No two blocks in the same cell at the same time.
                var seen = Set<String>()
                for n in map.notes {
                    let key = "\(n.beat)-\(n.column)-\(n.row)"
                    XCTAssertFalse(seen.contains(key), "overlap \(key) in \(d)")
                    seen.insert(key)
                }
                print("\(map.difficulty.name) \(mode.name): \(map.notes.count) notes, \(map.bombs.count) bombs, \(String(format: "%.2f", map.notesPerSecond)) nps")
            }
        }
    }

    func testParity() {
        // Within a short gap, the same hand never asks for two downward cuts in a row.
        let map = LevelDesigner.beatmap(difficulty: .expert, mode: .twoSabers)
        let spb = 60.0 / map.bpm
        for hand in Hand.allCases {
            let ns = map.notes.filter { $0.hand == hand }
            for (a, b) in zip(ns, ns.dropFirst()) where (b.time - a.time) / spb < 2.0 {
                if a.direction.isDownward && b.direction != .any {
                    XCTAssertFalse(b.direction.isDownward, "double down at beat \(b.beat)")
                }
                if a.direction.isUpward && b.direction != .any {
                    XCTAssertFalse(b.direction.isUpward, "double up at beat \(b.beat)")
                }
            }
        }
    }
}

final class SessionTests: XCTestCase {
    /// Drives a saber in a perfect arc through every block and checks everything gets cut.
    func testAutoplayCutsEverything() {
        for d in Difficulty.allCases {
            for m in PlayMode.allCases { autoplay(LevelDesigner.beatmap(difficulty: d, mode: m)) }
        }
    }

    func autoplay(_ map: Beatmap) {
        let session = GameSession(beatmap: map)
        let fps = 120.0
        var t = 0.0
        var cuts = 0, bad = 0, missed = 0, scored = 0
        var totalScore = 0
        let driver = AutoplayDriver(beatmap: map)
        while t < map.duration && !session.hasFinished {
            let inputs = driver.inputs(time: t)
            for e in session.update(songTime: t, sabers: inputs) {
                switch e {
                case .cut: cuts += 1
                case .badCut(let info, let r): bad += 1; let n = map.notes[info.noteID]; print("bad \(r) note beat \(n.beat) hand \(n.hand) col \(n.column) row \(n.row) dir \(n.direction) by \(info.hand); same-beat:", map.notes.filter { abs($0.beat - n.beat) < 1.01 }.map { "\($0.beat) \($0.hand) c\($0.column)r\($0.row) \($0.direction)" })
                case .miss: missed += 1
                case .scored(_, let s, _, _): scored += 1; totalScore += s.total
                default: break
                }
            }
            t += 1 / fps
        }
        let res = session.results()
        print("autoplay \(map.difficulty.name) \(map.mode.name): cuts \(cuts) bad \(bad) missed \(missed) avg \(totalScore / max(scored, 1)) rank \(res.rank.rawValue) \(String(format: "%.1f%%", res.percent * 100))")
        XCTAssertEqual(cuts, map.notes.count)
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(missed, 0)
        XCTAssertEqual(scored, map.notes.count)
        XCTAssertGreaterThan(res.percent, 0.75)
    }

    func testWrongColorIsBadCut() {
        let note = Note(id: 0, beat: 4, time: 2, column: 1, row: 1, hand: .left, direction: .down)
        let map = Beatmap(songTitle: "t", difficulty: .easy, mode: .twoSabers, bpm: 120, noteSpeed: 10,
                          duration: 10, notes: [note], bombs: [], lights: [])
        let session = GameSession(beatmap: map)
        let pivot = Arena.pivot(for: .right)
        let target = NoteMotion(speed: 10).position(column: 1, row: 1, beatTime: 2, now: 2)
        var gotBad = false
        var t = 1.8
        while t < 2.3 {
            let p = clamp((t - 1.95) / 0.1, 0, 1)
            let point = Vec3(target.x, target.y + 1 - 2 * p, target.z)
            for e in session.update(songTime: t, sabers: [SaberInput(hand: .right, direction: (point - pivot).normalized, active: true)]) {
                if case .badCut(_, let r) = e { XCTAssertEqual(r, .wrongColor); gotBad = true }
            }
            t += 1 / 120
        }
        XCTAssertTrue(gotBad)
    }
}

final class AudioTests: XCTestCase {
    func testSoundEffectsRender() {
        for e in SoundEffect.allCases {
            let a = SoundEffectSynth.render(e)
            XCTAssertGreaterThan(a.frameCount, 100)
            XCTAssertFalse(a.left.contains { !$0.isFinite })
            XCTAssertLessThan(a.peak, 1.5)
        }
    }
}

final class MusicTests: XCTestCase {
    func testMusicRenders() throws {
        let start = Date()
        let audio = MusicSynth().render()
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "music: %.1fs of audio rendered in %.2fs, peak %.3f", audio.duration, elapsed, audio.peak))
        XCTAssertGreaterThan(audio.duration, 140)
        XCTAssertFalse(audio.left.contains { !$0.isFinite })
        XCTAssertLessThanOrEqual(audio.peak, 1.0)
        // Per-section loudness (RMS) to sanity-check the arrangement.
        let song = SongDefinition.prismRun
        for s in song.sections {
            let a = Int(song.time(ofBeat: Double(s.startBar * 4)) * audio.sampleRate)
            let b = min(audio.frameCount, Int(song.time(ofBeat: Double(s.endBar * 4)) * audio.sampleRate))
            var sum: Double = 0
            for i in stride(from: a, to: b, by: 4) { sum += Double(audio.left[i] * audio.left[i]) }
            let rms = (sum / Double((b - a) / 4)).squareRoot()
            print("  \(s.kind.rawValue) bars \(s.startBar)-\(s.endBar): rms \(String(format: "%.3f", rms))")
        }
        if let path = ProcessInfo.processInfo.environment["SABER_WAV"] {
            try writeWAV(audio, to: path)
        }
    }

    func writeWAV(_ a: StereoAudio, to path: String) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let n = a.frameCount
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
        for i in 0..<n {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, a.left[i])) * 32767)))
            u16(UInt16(bitPattern: Int16(max(-1, min(1, a.right[i])) * 32767)))
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

final class ControllerProtocolTests: XCTestCase {
    func testRoundTrip() {
        let msgs: [ControllerMessage] = [
            .motion(sequence: 123_456, attitude: Quat(x: 0.1, y: -0.2, z: 0.3, w: 0.927), gravity: Vec3(0, -1, 0.02)),
            .hello(name: "Tom’s iPhone"),
            .button(.recenter),
            .button(.pause),
            .status(hand: 1, calibrated: true, macName: "MacBook Pro"),
            .status(hand: -1, calibrated: false, macName: ""),
            .haptic(intensity: 0.75),
        ]
        for m in msgs {
            let decoded = ControllerMessage.decode(m.encoded())
            switch (m, decoded) {
            case let (.motion(s1, q1, g1), .motion(s2, q2, g2)?):
                XCTAssertEqual(s1, s2)
                XCTAssertEqual(q1.x, q2.x, accuracy: 1e-6); XCTAssertEqual(q1.w, q2.w, accuracy: 1e-6)
                XCTAssertEqual(g1.y, g2.y, accuracy: 1e-6)
            default:
                XCTAssertEqual(decoded, m)
            }
        }
    }

    func testRejectsGarbage() {
        XCTAssertNil(ControllerMessage.decode(Data()))
        XCTAssertNil(ControllerMessage.decode(Data([0x53, 0x53, 9, 1])))
        XCTAssertNil(ControllerMessage.decode(Data([0x53, 0x53, 1, 1, 0, 0])))
        var bad = ControllerMessage.hello(name: "x").encoded()
        bad[0] = 0
        XCTAssertNil(ControllerMessage.decode(bad))
    }

    func testRemoteMessagesRoundTrip() {
        var state = RemoteState()
        state.screen = .levelSelect
        state.songTitle = "Prism Run"
        state.difficulties = ["Easy", "Normal", "Hard", "Expert"]
        state.difficulty = 3
        state.calibration.streams = [.init(id: "phone", name: "iPhone", live: true, progress: 0.4, done: false)]
        state.settings.inputModes = [.init(id: "airpodAndPhone", title: "AirPod + iPhone")]
        state.settings.sensitivity = 1.25
        var results = RemoteState.Results()
        results.rank = "SS"; results.score = 123_456
        state.results = results
        // A full Arena & Colors payload: every arena and template.
        var look = RemoteState.Look()
        look.arena = "orbit"
        look.arenas = (0..<5).map { .init(id: "arena\($0)", title: "Neon Skyline \($0)",
                                           tagline: "Rooftop runway above a glowing city, searchlights in the sky.",
                                           symbol: "building.2", swatch: ["#FF2640", "#2E8CFF"]) }
        look.colors = ["#FF2640", "#2E8CFF", "#FF2640", "#2E8CFF"]
        look.presets = ColorPreset.all.map { p in
            .init(id: p.id, name: p.name, colors: [p.scheme.leftSaber.hex, p.scheme.rightSaber.hex,
                                                   p.scheme.leftLights.hex, p.scheme.rightLights.hex])
        }
        look.presetID = "classic"
        state.look = look
        let msgs: [ControllerMessage] = [
            .remoteState(state),
            .command(id: 7, .start),
            .command(id: 0xDEAD_BEEF, .selectDifficulty(2)),
            .command(id: 1, .setFlag(.noFail, true)),
            .command(id: 2, .setValue(.musicVolume, 0.5)),
            .command(id: 3, .setInputMode("mouse")),
            .command(id: 4, .setColor(slot: 2, hex: "#12AB9F")),
            .command(id: 5, .applyColorPreset("toxic")),
        ]
        for m in msgs {
            XCTAssertEqual(ControllerMessage.decode(m.encoded()), m)
        }
        // A full state must fit comfortably in one datagram.
        XCTAssertLessThan(ControllerMessage.remoteState(state).encoded().count, 8_000)
    }

    func testRejectsTruncatedRemoteMessage() {
        let d = ControllerMessage.command(id: 9, .pause).encoded()
        XCTAssertNil(ControllerMessage.decode(d.prefix(d.count - 1)))
    }

    func testMotionPacketIsSmall() {
        let d = ControllerMessage.motion(sequence: 1, attitude: .identity, gravity: Vec3(0, 0, -1)).encoded()
        XCTAssertEqual(d.count, 4 + 4 + 28)
    }
}

final class ColorSchemeTests: XCTestCase {
    func testHexRoundTrip() {
        let c = NeonColor(hex: "#1A7FFF")
        XCTAssertEqual(c?.r255, 0x1A)
        XCTAssertEqual(c?.g255, 0x7F)
        XCTAssertEqual(c?.b255, 0xFF)
        XCTAssertEqual(c?.hex, "#1A7FFF")
        XCTAssertEqual(NeonColor(hex: "f0a")?.hex, "#FF00AA")
        XCTAssertEqual(NeonColor(hex: " 00ff00 ")?.hex, "#00FF00")
        XCTAssertNil(NeonColor(hex: "#12345"))
        XCTAssertNil(NeonColor(hex: "zzzzzz"))
    }

    func testComponentsAreClamped() {
        let c = NeonColor(1.5, -0.2, 0.5)
        XCTAssertEqual(c.r, 1)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0.5)
    }

    func testSlotsAndSwap() {
        var s = SaberColorScheme.classic
        s[.rightLights] = .white
        XCTAssertEqual(s.rightLights, .white)
        let w = s.swapped
        XCTAssertEqual(w.leftSaber, s.rightSaber)
        XCTAssertEqual(w.leftLights, .white)
        XCTAssertEqual(w.swapped, s)
    }

    func testSchemeCodableRoundTrip() throws {
        let s = ColorPreset.all[3].scheme
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SaberColorScheme.self, from: data), s)
    }

    func testPresetsAreUniqueAndReadable() {
        XCTAssertEqual(Set(ColorPreset.all.map(\.id)).count, ColorPreset.all.count)
        XCTAssertEqual(ColorPreset.preset(id: "classic")?.scheme, .classic)
        for p in ColorPreset.all {
            XCTAssertEqual(ColorPreset.matching(p.scheme)?.id, p.id)
            // The two sabers must be easy to tell apart.
            let a = p.scheme.leftSaber, b = p.scheme.rightSaber
            let distance = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
            XCTAssertGreaterThan(distance, 0.5, p.name)
            // Blocks are dark versions of the saber colours.
            XCTAssertLessThan(a.deepened.luminance, a.luminance + 1e-9, p.name)
        }
    }
}
