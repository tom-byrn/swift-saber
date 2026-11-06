import Foundation

/// Interleaving-free stereo PCM buffer.
public struct StereoAudio: Sendable {
    public var left: [Float]
    public var right: [Float]
    public let sampleRate: Double
    public var frameCount: Int { left.count }
    public var duration: Double { Double(frameCount) / sampleRate }

    public init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left; self.right = right; self.sampleRate = sampleRate
    }

    public init(frames: Int, sampleRate: Double) {
        left = [Float](repeating: 0, count: frames)
        right = [Float](repeating: 0, count: frames)
        self.sampleRate = sampleRate
    }

    public var peak: Float {
        var p: Float = 0
        for v in left { p = max(p, abs(v)) }
        for v in right { p = max(p, abs(v)) }
        return p
    }
}

// MARK: - DSP building blocks

@inline(__always) func midiToFreq(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

/// Fast deterministic white noise.
struct NoiseSource {
    var state: UInt32
    init(seed: UInt32) { state = seed == 0 ? 0x1234_5678 : seed }
    @inline(__always) mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(state) / Double(UInt32.max) * 2 - 1
    }
}

/// Topology-preserving-transform state variable filter (stable under modulation).
struct SVF {
    var ic1 = 0.0
    var ic2 = 0.0
    var g = 0.1
    var k = 1.0
    var a1 = 0.0, a2 = 0.0, a3 = 0.0

    init() { set(cutoff: 1000, q: 0.707, sampleRate: 44100) }

    init(cutoff: Double, q: Double, sampleRate: Double) {
        set(cutoff: cutoff, q: q, sampleRate: sampleRate)
    }

    @inline(__always) mutating func set(cutoff: Double, q: Double, sampleRate: Double) {
        let fc = min(max(cutoff, 20), sampleRate * 0.45)
        g = tan(Double.pi * fc / sampleRate)
        k = 1 / max(q, 0.1)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    /// Returns (lowpass, bandpass, highpass).
    @inline(__always) mutating func process(_ v0: Double) -> (lp: Double, bp: Double, hp: Double) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, v0 - k * v1 - v2)
    }
}

@inline(__always) func polyBlep(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    } else if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

/// Band-limited sawtooth oscillator.
struct SawOsc {
    var phase: Double
    init(phase: Double = 0) { self.phase = phase }
    @inline(__always) mutating func next(freq: Double, sampleRate: Double) -> Double {
        let dt = freq / sampleRate
        let v = 2 * phase - 1 - polyBlep(phase, dt)
        phase += dt
        if phase >= 1 { phase -= 1 }
        return v
    }
}

/// Simple Freeverb-style reverb (mono in, stereo out).
struct Reverb {
    struct Comb {
        var buf: [Double]
        var idx = 0
        var store = 0.0
        init(_ n: Int) { buf = [Double](repeating: 0, count: n) }
        @inline(__always) mutating func process(_ x: Double, feedback: Double, damp: Double) -> Double {
            let out = buf[idx]
            store = out * (1 - damp) + store * damp
            buf[idx] = x + store * feedback
            idx += 1
            if idx == buf.count { idx = 0 }
            return out
        }
    }
    struct AllPass {
        var buf: [Double]
        var idx = 0
        init(_ n: Int) { buf = [Double](repeating: 0, count: n) }
        @inline(__always) mutating func process(_ x: Double) -> Double {
            let b = buf[idx]
            let out = -x + b
            buf[idx] = x + b * 0.5
            idx += 1
            if idx == buf.count { idx = 0 }
            return out
        }
    }

    var combsL: [Comb]
    var combsR: [Comb]
    var apL: [AllPass]
    var apR: [AllPass]

    init(sampleRate: Double) {
        let scale = sampleRate / 44100
        let base = [1116, 1188, 1277, 1356, 1422, 1491]
        combsL = base.map { Comb(Int(Double($0) * scale * 1.35)) }
        combsR = base.map { Comb(Int(Double($0 + 23) * scale * 1.35)) }
        apL = [556, 441].map { AllPass(Int(Double($0) * scale)) }
        apR = [579, 464].map { AllPass(Int(Double($0) * scale)) }
    }

    @inline(__always) mutating func process(_ x: Double) -> (Double, Double) {
        var l = 0.0, r = 0.0
        let input = x * 0.12
        for i in 0..<combsL.count {
            l += combsL[i].process(input, feedback: 0.86, damp: 0.35)
            r += combsR[i].process(input, feedback: 0.86, damp: 0.35)
        }
        for i in 0..<apL.count {
            l = apL[i].process(l)
            r = apR[i].process(r)
        }
        return (l, r)
    }
}

// MARK: - Synth

/// Renders the original track "Prism Run" entirely from code.
/// No samples, no copyrighted audio: every sound is synthesized here.
public final class MusicSynth {
    public let song: SongDefinition
    public let sampleRate: Double
    let frames: Int
    let spb: Double
    var noise = NoiseSource(seed: 0xC0FFEE)

    public init(song: SongDefinition = .prismRun, sampleRate: Double = 44100) {
        self.song = song
        self.sampleRate = sampleRate
        self.spb = song.secondsPerBeat
        self.frames = Int(song.duration * sampleRate)
    }

    @inline(__always) func sampleIndex(_ t: Double) -> Int { Int((t * sampleRate).rounded()) }
    @inline(__always) func timeOf(beat: Double) -> Double { beat * spb }
    func barBeat(_ bar: Int) -> Double { Double(bar * song.beatsPerBar) }

    func kind(atBar bar: Int) -> SectionKind? { song.section(atBar: bar)?.kind }

    // MARK: Arrangement queries

    /// Beats (absolute) on which a kick drum plays.
    public func kickBeats() -> [Double] {
        var out: [Double] = []
        for bar in 0..<song.totalBars {
            guard let s = song.section(atBar: bar) else { continue }
            let rel = bar - s.startBar
            let play: Bool
            switch s.kind {
            case .intro: play = rel >= 4
            case .groove, .drop: play = true
            case .build: play = rel < 6
            case .breakdown: play = false
            case .outro: play = rel < 4
            }
            if play {
                for b in 0..<song.beatsPerBar { out.append(barBeat(bar) + Double(b)) }
            }
        }
        return out
    }

    // MARK: Render

    public func render(progress: ((Double) -> Void)? = nil) -> StereoAudio {
        var master = StereoAudio(frames: frames, sampleRate: sampleRate)
        var reverbSend = [Float](repeating: 0, count: frames)
        var delaySend = [Float](repeating: 0, count: frames)
        let kicks = kickBeats()
        let sidechain = makeSidechain(kicks: kicks)
        progress?(0.05)

        // Drums (mono)
        do {
            var bus = [Float](repeating: 0, count: frames)
            var clapBus = [Float](repeating: 0, count: frames)
            renderDrums(into: &bus, claps: &clapBus, kicks: kicks)
            mix(mono: bus, into: &master, gain: 1.0, pan: 0.5)
            mix(mono: clapBus, into: &master, gain: 0.55, pan: 0.5)
            addSend(clapBus, into: &reverbSend, amount: 0.35)
        }
        progress?(0.2)

        // Bass (mono, sidechained)
        do {
            var bus = [Float](repeating: 0, count: frames)
            renderBass(into: &bus)
            applySidechain(&bus, sidechain, depth: 0.75)
            mix(mono: bus, into: &master, gain: 0.55, pan: 0.5)
        }
        progress?(0.32)

        // Pads (stereo, filter automation, sidechained)
        do {
            var l = [Float](repeating: 0, count: frames)
            var r = [Float](repeating: 0, count: frames)
            renderPads(l: &l, r: &r)
            filterPads(l: &l, r: &r)
            applySidechain(&l, sidechain, depth: 0.6)
            applySidechain(&r, sidechain, depth: 0.6)
            mix(l: l, r: r, into: &master, gain: 0.26)
            addSend(l, into: &reverbSend, amount: 0.12)
            addSend(r, into: &reverbSend, amount: 0.12)
        }
        progress?(0.48)

        // Arp + bells (stereo)
        do {
            var l = [Float](repeating: 0, count: frames)
            var r = [Float](repeating: 0, count: frames)
            renderArp(l: &l, r: &r)
            renderBells(l: &l, r: &r)
            applySidechain(&l, sidechain, depth: 0.4)
            applySidechain(&r, sidechain, depth: 0.4)
            mix(l: l, r: r, into: &master, gain: 0.2)
            addSend(l, into: &delaySend, amount: 0.1)
            addSend(r, into: &delaySend, amount: 0.1)
            addSend(l, into: &reverbSend, amount: 0.12)
            addSend(r, into: &reverbSend, amount: 0.12)
        }
        progress?(0.62)

        // Lead (stereo)
        do {
            var l = [Float](repeating: 0, count: frames)
            var r = [Float](repeating: 0, count: frames)
            renderLead(l: &l, r: &r)
            applySidechain(&l, sidechain, depth: 0.25)
            applySidechain(&r, sidechain, depth: 0.25)
            mix(l: l, r: r, into: &master, gain: 0.2)
            addSend(l, into: &delaySend, amount: 0.12)
            addSend(r, into: &delaySend, amount: 0.12)
            addSend(l, into: &reverbSend, amount: 0.1)
            addSend(r, into: &reverbSend, amount: 0.1)
        }
        progress?(0.74)

        // FX: risers, impacts, crashes (stereo)
        do {
            var l = [Float](repeating: 0, count: frames)
            var r = [Float](repeating: 0, count: frames)
            renderFX(l: &l, r: &r)
            mix(l: l, r: r, into: &master, gain: 0.5)
            addSend(l, into: &reverbSend, amount: 0.08)
            addSend(r, into: &reverbSend, amount: 0.08)
        }
        progress?(0.82)

        renderDelay(send: delaySend, into: &master)
        delaySend = []
        progress?(0.88)
        renderReverb(send: reverbSend, into: &master)
        reverbSend = []
        progress?(0.96)

        finalize(&master)
        progress?(1.0)
        return master
    }

    // MARK: Mixing helpers

    func mix(mono: [Float], into master: inout StereoAudio, gain: Float, pan: Float) {
        let gl = gain * cos(pan * .pi / 2) * 1.4142
        let gr = gain * sin(pan * .pi / 2) * 1.4142
        mono.withUnsafeBufferPointer { src in
            master.left.withUnsafeMutableBufferPointer { l in
                master.right.withUnsafeMutableBufferPointer { r in
                    for i in 0..<min(src.count, l.count) {
                        let v = src[i]
                        l[i] += v * gl
                        r[i] += v * gr
                    }
                }
            }
        }
    }

    func mix(l srcL: [Float], r srcR: [Float], into master: inout StereoAudio, gain: Float) {
        srcL.withUnsafeBufferPointer { sl in
            srcR.withUnsafeBufferPointer { sr in
                master.left.withUnsafeMutableBufferPointer { l in
                    master.right.withUnsafeMutableBufferPointer { r in
                        for i in 0..<min(sl.count, l.count) {
                            l[i] += sl[i] * gain
                            r[i] += sr[i] * gain
                        }
                    }
                }
            }
        }
    }

    func addSend(_ src: [Float], into send: inout [Float], amount: Float) {
        src.withUnsafeBufferPointer { s in
            send.withUnsafeMutableBufferPointer { d in
                for i in 0..<min(s.count, d.count) { d[i] += s[i] * amount }
            }
        }
    }

    func makeSidechain(kicks: [Double]) -> [Float] {
        var sc = [Float](repeating: 0, count: frames)
        let attack = 0.004, release = 0.16
        sc.withUnsafeMutableBufferPointer { buf in
            for kb in kicks {
                let start = sampleIndex(timeOf(beat: kb))
                let len = Int((attack + release * 4) * sampleRate)
                for i in 0..<len {
                    let j = start + i
                    if j < 0 { continue }
                    if j >= buf.count { break }
                    let t = Double(i) / sampleRate
                    let env = t < attack ? t / attack : exp(-(t - attack) / release)
                    buf[j] = max(buf[j], Float(env))
                }
            }
        }
        return sc
    }

    func applySidechain(_ bus: inout [Float], _ sc: [Float], depth: Float) {
        sc.withUnsafeBufferPointer { s in
            bus.withUnsafeMutableBufferPointer { b in
                for i in 0..<min(s.count, b.count) { b[i] *= 1 - depth * s[i] }
            }
        }
    }

    // MARK: Drums

    func renderDrums(into bus: inout [Float], claps: inout [Float], kicks: [Double]) {
        for kb in kicks {
            let bar = Int(kb) / song.beatsPerBar
            var vel: Float = 1
            if let s = song.section(atBar: bar), s.kind == .intro { vel = 0.75 }
            kick(&bus, at: timeOf(beat: kb), vel: vel)
        }

        for bar in 0..<song.totalBars {
            guard let s = song.section(atBar: bar) else { continue }
            let rel = bar - s.startBar
            let b0 = barBeat(bar)
            switch s.kind {
            case .intro:
                if rel >= 6 {
                    for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.5), open: false, vel: 0.5) }
                }
            case .groove:
                for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.5), open: false, vel: 0.8) }
                if rel >= 4 {
                    clap(&claps, at: timeOf(beat: b0 + 1), vel: 0.9)
                    clap(&claps, at: timeOf(beat: b0 + 3), vel: 0.9)
                }
                if rel >= 6 {
                    for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.25), open: false, vel: 0.35) }
                    for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.75), open: false, vel: 0.35) }
                }
            case .build:
                // Snare roll that speeds up through the build.
                let step: Double
                switch rel {
                case 0, 1: step = 2
                case 2, 3: step = 1
                case 4, 5: step = 0.5
                default: step = 0.25
                }
                var b = 0.0
                while b < 4 - 1e-9 {
                    let progressInBuild = (Double(rel) + b / 4) / Double(s.bars)
                    let isLastBeat = rel == s.bars - 1 && b >= 3.5
                    if !isLastBeat {
                        snare(&claps, at: timeOf(beat: b0 + b), vel: Float(0.35 + 0.65 * progressInBuild))
                    }
                    b += step
                }
                if rel < 6 {
                    for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.5), open: false, vel: 0.6) }
                }
            case .drop:
                clap(&claps, at: timeOf(beat: b0 + 1), vel: 1)
                clap(&claps, at: timeOf(beat: b0 + 3), vel: 1)
                for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.5), open: true, vel: 0.55) }
                for sx in 0..<16 where sx % 2 == 1 || sx % 4 == 0 {
                    let accent: Float = sx % 4 == 2 ? 0.5 : 0.3
                    if sx % 4 == 2 { continue } // open hat covers this slot
                    hat(&bus, at: timeOf(beat: b0 + Double(sx) * 0.25), open: false, vel: accent)
                }
                if rel % 8 == 7 {
                    // Fill on the last beat of each 8 bars.
                    for f in 0..<4 { snare(&claps, at: timeOf(beat: b0 + 3 + Double(f) * 0.25), vel: 0.5 + Float(f) * 0.12) }
                }
            case .breakdown:
                if rel >= 4 {
                    for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.5), open: false, vel: 0.4) }
                    if rel >= 6 { clap(&claps, at: timeOf(beat: b0 + 3), vel: 0.6) }
                }
            case .outro:
                if rel < 4 {
                    clap(&claps, at: timeOf(beat: b0 + 1), vel: 0.8)
                    clap(&claps, at: timeOf(beat: b0 + 3), vel: 0.8)
                    for e in 0..<4 { hat(&bus, at: timeOf(beat: b0 + Double(e) + 0.5), open: rel < 2, vel: 0.45) }
                }
            }
        }
    }

    func kick(_ bus: inout [Float], at t0: Double, vel: Float) {
        let start = sampleIndex(t0)
        let len = Int(0.45 * sampleRate)
        var phase = 0.0
        bus.withUnsafeMutableBufferPointer { buf in
            for i in 0..<len {
                let j = start + i
                if j >= buf.count { break }
                let tt = Double(i) / sampleRate
                let f = 46 + 135 * exp(-tt * 38) + 30 * exp(-tt * 9)
                phase += 2 * Double.pi * f / sampleRate
                var amp = exp(-tt * 5.2)
                if tt < 0.0015 { amp *= tt / 0.0015 }
                if tt > 0.38 { amp *= max(0, 1 - (tt - 0.38) / 0.07) }
                var s = tanh(1.9 * sin(phase)) * amp
                s += noise.next() * exp(-tt * 500) * 0.22
                if j >= 0 { buf[j] += Float(s * 0.9) * vel }
            }
        }
    }

    func clap(_ bus: inout [Float], at t0: Double, vel: Float) {
        let start = sampleIndex(t0)
        let len = Int(0.35 * sampleRate)
        var bp = SVF(cutoff: 1250, q: 1.4, sampleRate: sampleRate)
        var hp = SVF(cutoff: 2500, q: 0.7, sampleRate: sampleRate)
        bus.withUnsafeMutableBufferPointer { buf in
            for i in 0..<len {
                let j = start + i
                if j >= buf.count { break }
                let tt = Double(i) / sampleRate
                var env = 0.0
                for k in 0..<3 {
                    let off = Double(k) * 0.0105
                    if tt >= off { env = max(env, exp(-(tt - off) * 320)) }
                }
                if tt >= 0.021 { env = max(env, 0.85 * exp(-(tt - 0.021) * 15)) }
                let n = noise.next() * env
                let s = bp.process(n).bp * 2.4 + hp.process(n).hp * 0.35 + sin(2 * .pi * 185 * tt) * exp(-tt * 30) * 0.25
                if j >= 0 { buf[j] += Float(s * 0.8) * vel }
            }
        }
    }

    func snare(_ bus: inout [Float], at t0: Double, vel: Float) {
        let start = sampleIndex(t0)
        let len = Int(0.2 * sampleRate)
        var bp = SVF(cutoff: 1900, q: 0.8, sampleRate: sampleRate)
        bus.withUnsafeMutableBufferPointer { buf in
            for i in 0..<len {
                let j = start + i
                if j >= buf.count { break }
                let tt = Double(i) / sampleRate
                let n = noise.next() * exp(-tt * 24)
                let f = bp.process(n)
                let s = f.bp * 1.6 + f.hp * 0.4 + sin(2 * .pi * 205 * tt) * exp(-tt * 38) * 0.45
                if j >= 0 { buf[j] += Float(s * 0.6) * vel }
            }
        }
    }

    func hat(_ bus: inout [Float], at t0: Double, open: Bool, vel: Float) {
        let start = sampleIndex(t0)
        let len = Int((open ? 0.32 : 0.07) * sampleRate)
        let decay = open ? 9.0 : 60.0
        var hp = SVF(cutoff: 7800, q: 0.9, sampleRate: sampleRate)
        var bp = SVF(cutoff: 10500, q: 2.5, sampleRate: sampleRate)
        bus.withUnsafeMutableBufferPointer { buf in
            for i in 0..<len {
                let j = start + i
                if j >= buf.count { break }
                let tt = Double(i) / sampleRate
                let n = noise.next() * exp(-tt * decay) * min(1, tt / 0.0008)
                let s = hp.process(n).hp * 0.8 + bp.process(n).bp * 0.6
                if j >= 0 { buf[j] += Float(s * 0.35) * vel }
            }
        }
    }

    // MARK: Bass

    func renderBass(into bus: inout [Float]) {
        for bar in 0..<song.totalBars {
            guard let s = song.section(atBar: bar) else { continue }
            let rel = bar - s.startBar
            let root = Double(song.bassRoots[song.chordIndex(atBar: bar)])
            let b0 = barBeat(bar)
            switch s.kind {
            case .intro:
                if rel >= 6 {
                    for e in 0..<4 { bassNote(&bus, beat: b0 + Double(e) + 0.5, len: 0.4, midi: root + 12, vel: 0.6, bright: 0.4) }
                }
            case .groove:
                for e in 0..<4 { bassNote(&bus, beat: b0 + Double(e) + 0.5, len: 0.42, midi: root + 12, vel: 0.85, bright: 0.6) }
            case .build:
                if rel < 6 {
                    for e in 0..<4 { bassNote(&bus, beat: b0 + Double(e) + 0.5, len: 0.42, midi: root + 12, vel: 0.85, bright: 0.5 + Double(rel) * 0.08) }
                }
            case .drop:
                // Rolling 16ths that skip the kick.
                for sx in 0..<16 where sx % 4 != 0 {
                    let octave: Double = (sx % 4 == 2) ? 12 : 0
                    bassNote(&bus, beat: b0 + Double(sx) * 0.25, len: 0.2, midi: root + 12 + octave, vel: 0.9, bright: 0.85)
                }
            case .breakdown:
                // Long sub notes.
                subNote(&bus, beat: b0, len: 4, midi: root + 12, vel: 0.9)
            case .outro:
                if rel < 4 {
                    for e in 0..<4 { bassNote(&bus, beat: b0 + Double(e) + 0.5, len: 0.42, midi: root + 12, vel: 0.8, bright: 0.5) }
                } else if rel < 7 {
                    subNote(&bus, beat: b0, len: 4, midi: root + 12, vel: 0.7 - Double(rel - 4) * 0.15)
                }
            }
        }
    }

    func bassNote(_ bus: inout [Float], beat: Double, len: Double, midi: Double, vel: Double, bright: Double) {
        let t0 = timeOf(beat: beat)
        let dur = len * spb
        let start = sampleIndex(t0)
        let total = Int((dur + 0.02) * sampleRate)
        let f = midiToFreq(midi)
        var saw = SawOsc(phase: 0)
        var subPhase = 0.0
        var lp = SVF()
        bus.withUnsafeMutableBufferPointer { buf in
            for i in 0..<total {
                let j = start + i
                if j >= buf.count { break }
                let tt = Double(i) / sampleRate
                if i % 16 == 0 {
                    lp.set(cutoff: 140 + 1500 * bright * exp(-tt * 16), q: 1.2, sampleRate: sampleRate)
                }
                var amp = min(1, tt / 0.004)
                if tt > dur { amp *= max(0, 1 - (tt - dur) / 0.02) }
                let raw = saw.next(freq: f, sampleRate: sampleRate)
                subPhase += 2 * Double.pi * f / sampleRate
                let s = lp.process(raw).lp * 0.75 + sin(subPhase) * 0.55
                if j >= 0 { buf[j] += Float(s * amp * vel) }
            }
        }
    }

    func subNote(_ bus: inout [Float], beat: Double, len: Double, midi: Double, vel: Double) {
        let t0 = timeOf(beat: beat)
        let dur = len * spb
        let start = sampleIndex(t0)
        let total = Int((dur + 0.1) * sampleRate)
        let f = midiToFreq(midi)
        var phase = 0.0
        bus.withUnsafeMutableBufferPointer { buf in
            for i in 0..<total {
                let j = start + i
                if j >= buf.count { break }
                let tt = Double(i) / sampleRate
                var amp = min(1, tt / 0.08)
                if tt > dur - 0.1 { amp *= max(0, 1 - (tt - (dur - 0.1)) / 0.2) }
                phase += 2 * Double.pi * f / sampleRate
                let s = sin(phase) + 0.15 * sin(2 * phase)
                if j >= 0 { buf[j] += Float(s * amp * vel * 0.8) }
            }
        }
    }

    // MARK: Pads

    func renderPads(l: inout [Float], r: inout [Float]) {
        var rng = SeededRandom(seed: 99)
        let barLen = Double(song.beatsPerBar) * spb
        for bar in 0..<song.totalBars {
            guard let s = song.section(atBar: bar) else { continue }
            let rel = bar - s.startBar
            var vel = 1.0
            switch s.kind {
            case .intro: vel = 0.55 + 0.05 * Double(rel)
            case .outro: vel = max(0.15, 1 - Double(rel) * 0.1)
            case .build: vel = 0.85
            default: vel = 1
            }
            let voicing = song.chordVoicings[song.chordIndex(atBar: bar)]
            let t0 = timeOf(beat: barBeat(bar))
            let isLast = bar == song.totalBars - 1
            let dur = isLast ? barLen + 1.0 : barLen
            for m in voicing {
                padVoice(l: &l, r: &r, t0: t0, dur: dur, midi: Double(m), vel: vel * 0.22, rng: &rng)
            }
            // Add a low root for weight in the drops and breakdown.
            if s.kind == .drop || s.kind == .breakdown {
                padVoice(l: &l, r: &r, t0: t0, dur: dur, midi: Double(song.bassRoots[song.chordIndex(atBar: bar)] + 24), vel: vel * 0.16, rng: &rng)
            }
        }
    }

    func padVoice(l: inout [Float], r: inout [Float], t0: Double, dur: Double, midi: Double, vel: Double, rng: inout SeededRandom) {
        let attack = 0.3, release = 0.55
        let start = sampleIndex(t0)
        let total = Int((dur + release) * sampleRate)
        let detunes = [-0.09, 0.0, 0.09]
        var oscs = detunes.map { _ in SawOsc(phase: rng.unit()) }
        let freqs = detunes.map { midiToFreq(midi + $0) }
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let tt = Double(i) / sampleRate
                    var amp = min(1, tt / attack)
                    if tt > dur { amp *= max(0, 1 - (tt - dur) / release) }
                    let a = oscs[0].next(freq: freqs[0], sampleRate: sampleRate)
                    let b = oscs[1].next(freq: freqs[1], sampleRate: sampleRate)
                    let c = oscs[2].next(freq: freqs[2], sampleRate: sampleRate)
                    if j >= 0 {
                        lb[j] += Float((a + 0.6 * b) * amp * vel)
                        rb[j] += Float((c + 0.6 * b) * amp * vel)
                    }
                }
            }
        }
    }

    /// Cutoff automation for the pad bus.
    func padCutoff(at t: Double) -> Double {
        let beat = t / spb
        let bar = Int(beat) / song.beatsPerBar
        guard let s = song.section(atBar: bar) else { return 600 }
        let p = (beat - barBeat(s.startBar)) / Double(s.bars * song.beatsPerBar)
        switch s.kind {
        case .intro: return 500 + 1100 * p
        case .groove: return 1600 + 400 * p
        case .build: return 700 * pow(9, p)
        case .drop: return 4200
        case .breakdown: return 1400 + 1200 * sin(p * .pi)
        case .outro: return max(350, 3000 * (1 - p))
        }
    }

    func filterPads(l: inout [Float], r: inout [Float]) {
        var fl = SVF(), fr = SVF()
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<lb.count {
                    if i % 32 == 0 {
                        let c = padCutoff(at: Double(i) / sampleRate)
                        fl.set(cutoff: c, q: 0.9, sampleRate: sampleRate)
                        fr.set(cutoff: c, q: 0.9, sampleRate: sampleRate)
                    }
                    lb[i] = Float(fl.process(Double(lb[i])).lp)
                    rb[i] = Float(fr.process(Double(rb[i])).lp)
                }
            }
        }
    }

    // MARK: Arp & bells

    func renderArp(l: inout [Float], r: inout [Float]) {
        let pattern = [0, 1, 2, 3, 2, 1, 2, 3, 0, 2, 1, 3, 2, 1, 3, 2]
        for bar in 0..<song.totalBars {
            guard let s = song.section(atBar: bar) else { continue }
            let rel = bar - s.startBar
            let tones = song.arpTones[song.chordIndex(atBar: bar)]
            let b0 = barBeat(bar)
            var step = 0.25
            var vel = 1.0
            var bright = 1.0
            switch s.kind {
            case .intro:
                if rel < 2 { continue }
                step = 0.5; vel = 0.5 + 0.06 * Double(rel); bright = 0.3 + 0.08 * Double(rel)
            case .groove: vel = 0.75; bright = 0.6 + 0.03 * Double(rel)
            case .build: vel = 0.7 + 0.04 * Double(rel); bright = 0.5 + 0.07 * Double(rel)
            case .drop: vel = 0.75; bright = 1.0
            case .breakdown: continue // bells take over
            case .outro:
                if rel >= 6 { continue }
                vel = 0.7 - 0.1 * Double(rel); bright = 0.7 - 0.08 * Double(rel)
            }
            let count = Int(4 / step)
            for k in 0..<count {
                let tone = Double(tones[pattern[k % pattern.count]])
                let pan = k % 2 == 0 ? 0.3 : 0.7
                pluck(l: &l, r: &r, beat: b0 + Double(k) * step, midi: tone, vel: vel * (k % 4 == 0 ? 1.0 : 0.75), bright: bright, pan: pan)
            }
        }
    }

    func pluck(l: inout [Float], r: inout [Float], beat: Double, midi: Double, vel: Double, bright: Double, pan: Double) {
        let start = sampleIndex(timeOf(beat: beat))
        let total = Int(0.32 * sampleRate)
        var o1 = SawOsc(phase: 0), o2 = SawOsc(phase: 0.5)
        let f1 = midiToFreq(midi - 0.06), f2 = midiToFreq(midi + 0.06)
        var lp = SVF()
        let gl = cos(pan * .pi / 2), gr = sin(pan * .pi / 2)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let tt = Double(i) / sampleRate
                    if i % 16 == 0 {
                        lp.set(cutoff: 400 + 5200 * bright * exp(-tt * 26), q: 1.6, sampleRate: sampleRate)
                    }
                    let amp = min(1, tt / 0.002) * exp(-tt * 10)
                    let raw = o1.next(freq: f1, sampleRate: sampleRate) + o2.next(freq: f2, sampleRate: sampleRate)
                    let s = lp.process(raw).lp * amp * vel * 0.5
                    if j >= 0 {
                        lb[j] += Float(s * gl)
                        rb[j] += Float(s * gr)
                    }
                }
            }
        }
    }

    func renderBells(l: inout [Float], r: inout [Float]) {
        let pattern = [0, 2, 1, 3, 2, 1, 3, 2]
        for s in song.sections where s.kind == .breakdown {
            for bar in s.startBar..<s.endBar {
                let tones = song.arpTones[song.chordIndex(atBar: bar)]
                let b0 = barBeat(bar)
                for k in 0..<8 {
                    let pan = 0.2 + 0.6 * Double(k % 4) / 3
                    bell(l: &l, r: &r, beat: b0 + Double(k) * 0.5, midi: Double(tones[pattern[k]]), vel: k == 0 ? 0.9 : 0.6, pan: pan)
                }
            }
        }
    }

    func bell(l: inout [Float], r: inout [Float], beat: Double, midi: Double, vel: Double, pan: Double) {
        let start = sampleIndex(timeOf(beat: beat))
        let total = Int(1.6 * sampleRate)
        let f = midiToFreq(midi)
        let gl = cos(pan * .pi / 2), gr = sin(pan * .pi / 2)
        var pc = 0.0, pm = 0.0
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let tt = Double(i) / sampleRate
                    pm += 2 * Double.pi * f * 2 / sampleRate
                    pc += 2 * Double.pi * f / sampleRate
                    let index = 1.8 * exp(-tt * 5)
                    let amp = min(1, tt / 0.002) * exp(-tt * 2.6)
                    let s = sin(pc + index * sin(pm)) * amp * vel * 0.35
                    if j >= 0 {
                        lb[j] += Float(s * gl)
                        rb[j] += Float(s * gr)
                    }
                }
            }
        }
    }

    // MARK: Lead

    func renderLead(l: inout [Float], r: inout [Float]) {
        for s in song.sections {
            switch s.kind {
            case .drop:
                for n in song.leadNotes(inDropStartingAt: s.startBar, bars: s.bars) {
                    leadNote(l: &l, r: &r, beat: n.beat, len: n.length, midi: Double(n.midi), vel: 1.0)
                    if s.occurrence >= 2 {
                        leadNote(l: &l, r: &r, beat: n.beat, len: n.length, midi: Double(n.midi - 12), vel: 0.55)
                    }
                }
            case .breakdown:
                // A soft, filtered statement of the hook in the second half of the break.
                let start = s.startBar + 4
                for n in song.leadNotes(inDropStartingAt: start, bars: 4) {
                    leadNote(l: &l, r: &r, beat: n.beat, len: n.length, midi: Double(n.midi - 12), vel: 0.4)
                }
            default: break
            }
        }
    }

    func leadNote(l: inout [Float], r: inout [Float], beat: Double, len: Double, midi: Double, vel: Double) {
        let start = sampleIndex(timeOf(beat: beat))
        let dur = len * spb
        let release = 0.12
        let total = Int((dur + release) * sampleRate)
        let detunes = [-0.22, -0.11, 0.0, 0.11, 0.22]
        let pans = [0.0, 0.25, 0.5, 0.75, 1.0]
        var oscs = (0..<5).map { SawOsc(phase: Double($0) * 0.21) }
        var lpL = SVF(), lpR = SVF()
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let tt = Double(i) / sampleRate
                    if i % 16 == 0 {
                        let c = 1300 + 4200 * exp(-tt * 7)
                        lpL.set(cutoff: c, q: 0.8, sampleRate: sampleRate)
                        lpR.set(cutoff: c, q: 0.8, sampleRate: sampleRate)
                    }
                    let vib = tt > 0.18 ? 0.12 * sin(2 * .pi * 5.5 * tt) * min(1, (tt - 0.18) / 0.2) : 0
                    var amp = min(1, tt / 0.008)
                    amp *= 0.75 + 0.25 * exp(-tt * 8)
                    if tt > dur { amp *= max(0, 1 - (tt - dur) / release) }
                    var sl = 0.0, sr = 0.0
                    for v in 0..<5 {
                        let o = oscs[v].next(freq: midiToFreq(midi + detunes[v] + vib), sampleRate: sampleRate)
                        sl += o * (1 - pans[v])
                        sr += o * pans[v]
                    }
                    let outL = lpL.process(sl).lp * amp * vel * 0.32
                    let outR = lpR.process(sr).lp * amp * vel * 0.32
                    if j >= 0 {
                        lb[j] += Float(outL)
                        rb[j] += Float(outR)
                    }
                }
            }
        }
    }

    // MARK: FX

    func renderFX(l: inout [Float], r: inout [Float]) {
        for s in song.sections {
            switch s.kind {
            case .build:
                riser(l: &l, r: &r, fromBeat: barBeat(s.startBar), toBeat: barBeat(s.endBar) - 0.5)
            case .drop:
                impact(l: &l, r: &r, beat: barBeat(s.startBar))
                crash(l: &l, r: &r, beat: barBeat(s.startBar), vel: 1)
                crash(l: &l, r: &r, beat: barBeat(s.startBar + 8), vel: 0.8)
            case .groove:
                crash(l: &l, r: &r, beat: barBeat(s.startBar), vel: 0.6)
            case .breakdown:
                crash(l: &l, r: &r, beat: barBeat(s.startBar), vel: 0.7)
                riser(l: &l, r: &r, fromBeat: barBeat(s.endBar - 2), toBeat: barBeat(s.endBar), level: 0.5)
            case .outro:
                crash(l: &l, r: &r, beat: barBeat(s.startBar), vel: 0.8)
                impact(l: &l, r: &r, beat: barBeat(s.startBar + 4), level: 0.6)
            case .intro:
                riser(l: &l, r: &r, fromBeat: barBeat(s.endBar - 2), toBeat: barBeat(s.endBar), level: 0.4)
            }
        }
    }

    func riser(l: inout [Float], r: inout [Float], fromBeat: Double, toBeat: Double, level: Double = 1) {
        let t0 = timeOf(beat: fromBeat), t1 = timeOf(beat: toBeat)
        let start = sampleIndex(t0)
        let total = Int((t1 - t0) * sampleRate)
        var bl = SVF(), br = SVF()
        var nr = NoiseSource(seed: 0xBEEF)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let p = Double(i) / Double(max(total, 1))
                    if i % 32 == 0 {
                        let c = 300 * pow(30, p)
                        bl.set(cutoff: c, q: 2.2, sampleRate: sampleRate)
                        br.set(cutoff: c * 1.05, q: 2.2, sampleRate: sampleRate)
                    }
                    let amp = p * p * 0.55 * level
                    let a = bl.process(noise.next()).bp
                    let b = br.process(nr.next()).bp
                    if j >= 0 {
                        lb[j] += Float(a * amp)
                        rb[j] += Float(b * amp)
                    }
                }
            }
        }
    }

    func impact(l: inout [Float], r: inout [Float], beat: Double, level: Double = 1) {
        let start = sampleIndex(timeOf(beat: beat))
        let total = Int(1.8 * sampleRate)
        var phase = 0.0
        var lp = SVF(cutoff: 900, q: 0.7, sampleRate: sampleRate)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let tt = Double(i) / sampleRate
                    let f = 28 + 60 * exp(-tt * 3)
                    phase += 2 * Double.pi * f / sampleRate
                    let boom = sin(phase) * exp(-tt * 1.8) * min(1, tt / 0.003)
                    let n = lp.process(noise.next()).lp * exp(-tt * 6) * 0.8
                    let s = (boom * 0.9 + n) * level * 0.8
                    if j >= 0 {
                        lb[j] += Float(s)
                        rb[j] += Float(s)
                    }
                }
            }
        }
    }

    func crash(l: inout [Float], r: inout [Float], beat: Double, vel: Double) {
        let start = sampleIndex(timeOf(beat: beat))
        let total = Int(3.0 * sampleRate)
        var hl = SVF(cutoff: 4200, q: 0.7, sampleRate: sampleRate)
        var hr = SVF(cutoff: 4400, q: 0.7, sampleRate: sampleRate)
        var nr = NoiseSource(seed: 0xFACE)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                for i in 0..<total {
                    let j = start + i
                    if j >= lb.count { break }
                    let tt = Double(i) / sampleRate
                    let amp = min(1, tt / 0.002) * exp(-tt * 1.5) * vel * 0.3
                    let a = hl.process(noise.next()).hp
                    let b = hr.process(nr.next()).hp
                    if j >= 0 {
                        lb[j] += Float(a * amp)
                        rb[j] += Float(b * amp)
                    }
                }
            }
        }
    }

    // MARK: Delay & reverb

    func renderDelay(send: [Float], into master: inout StereoAudio) {
        let delaySamples = Int(0.75 * spb * sampleRate)
        var bufL = [Double](repeating: 0, count: delaySamples)
        var bufR = [Double](repeating: 0, count: delaySamples)
        var idx = 0
        var lpL = SVF(cutoff: 3200, q: 0.6, sampleRate: sampleRate)
        var lpR = SVF(cutoff: 3200, q: 0.6, sampleRate: sampleRate)
        let fb = 0.38
        send.withUnsafeBufferPointer { s in
            master.left.withUnsafeMutableBufferPointer { l in
                master.right.withUnsafeMutableBufferPointer { r in
                    for i in 0..<min(s.count, l.count) {
                        let x = Double(s[i])
                        let dl = bufL[idx], dr = bufR[idx]
                        // Ping-pong: left feeds right and vice versa.
                        bufL[idx] = x + lpR.process(dr).lp * fb
                        bufR[idx] = lpL.process(dl).lp * fb
                        idx += 1
                        if idx == delaySamples { idx = 0 }
                        l[i] += Float(dl * 0.9)
                        r[i] += Float(dr * 0.9)
                    }
                }
            }
        }
    }

    func renderReverb(send: [Float], into master: inout StereoAudio) {
        var rev = Reverb(sampleRate: sampleRate)
        send.withUnsafeBufferPointer { s in
            master.left.withUnsafeMutableBufferPointer { l in
                master.right.withUnsafeMutableBufferPointer { r in
                    for i in 0..<min(s.count, l.count) {
                        let (a, b) = rev.process(Double(s[i]))
                        l[i] += Float(a * 0.55)
                        r[i] += Float(b * 0.55)
                    }
                }
            }
        }
    }

    func finalize(_ master: inout StereoAudio) {
        let p = max(master.peak, 1e-6)
        let drive: Float = 1.25
        let norm = 1 / tanh(drive)
        let scale = 1 / p
        // Gentle fade-out over the final second.
        let fadeStart = master.frameCount - Int(1.0 * sampleRate)
        for i in 0..<master.frameCount {
            var g: Float = 1
            if i > fadeStart { g = Float(master.frameCount - i) / Float(master.frameCount - fadeStart) }
            master.left[i] = tanh(master.left[i] * scale * drive) * norm * 0.9 * g
            master.right[i] = tanh(master.right[i] * scale * drive) * norm * 0.9 * g
        }
    }
}
