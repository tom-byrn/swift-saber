import Foundation

/// Synthesized one-shot sound effects (all generated in code).
public enum SoundEffect: String, CaseIterable, Sendable {
    case slice
    case sliceAlt
    case badCut
    case miss
    case bomb
    case click
    case hover
    case countdown
    case go
    case fail
    case clear
    case calibrationStep
}

public enum SoundEffectSynth {
    public static func render(_ effect: SoundEffect, sampleRate: Double = 44100) -> StereoAudio {
        switch effect {
        case .slice: return slice(sampleRate: sampleRate, pitch: 1.0)
        case .sliceAlt: return slice(sampleRate: sampleRate, pitch: 1.12)
        case .badCut: return badCut(sampleRate: sampleRate)
        case .miss: return miss(sampleRate: sampleRate)
        case .bomb: return bomb(sampleRate: sampleRate)
        case .click: return tone(sampleRate: sampleRate, freq: 1800, length: 0.05, decay: 80, level: 0.35)
        case .hover: return tone(sampleRate: sampleRate, freq: 2600, length: 0.03, decay: 120, level: 0.15)
        case .countdown: return tone(sampleRate: sampleRate, freq: 880, length: 0.18, decay: 18, level: 0.45)
        case .go: return tone(sampleRate: sampleRate, freq: 1320, length: 0.35, decay: 9, level: 0.5)
        case .fail: return fail(sampleRate: sampleRate)
        case .clear: return clear(sampleRate: sampleRate)
        case .calibrationStep: return chime(sampleRate: sampleRate)
        }
    }

    static func make(_ seconds: Double, _ sr: Double, _ body: (Int, Double) -> (Double, Double)) -> StereoAudio {
        let n = Int(seconds * sr)
        var out = StereoAudio(frames: n, sampleRate: sr)
        for i in 0..<n {
            let (l, r) = body(i, Double(i) / sr)
            out.left[i] = Float(l)
            out.right[i] = Float(r)
        }
        return out
    }

    /// Bright "shing" with an airy swoosh.
    static func slice(sampleRate sr: Double, pitch: Double) -> StereoAudio {
        var noiseL = NoiseSource(seed: 11), noiseR = NoiseSource(seed: 12)
        var bpL = SVF(), bpR = SVF()
        let partials: [(Double, Double, Double)] = [(2150, 1.0, 22), (3420, 0.6, 28), (5230, 0.35, 34), (7900, 0.2, 40)]
        return make(0.32, sr) { i, t in
            if i % 16 == 0 {
                let c = 9000 * exp(-t * 9) + 1800
                bpL.set(cutoff: c, q: 1.3, sampleRate: sr)
                bpR.set(cutoff: c * 1.1, q: 1.3, sampleRate: sr)
            }
            let swooshEnv = min(1, t / 0.004) * exp(-t * 16)
            let nl = bpL.process(noiseL.next()).bp * swooshEnv
            let nr = bpR.process(noiseR.next()).bp * swooshEnv
            var ring = 0.0
            for (f, a, d) in partials { ring += sin(2 * .pi * f * pitch * t) * a * exp(-t * d) }
            ring *= min(1, t / 0.002) * 0.22
            return (nl * 0.9 + ring, nr * 0.9 + ring)
        }
    }

    static func badCut(sampleRate sr: Double) -> StereoAudio {
        var saw = SawOsc()
        var lp = SVF(cutoff: 900, q: 1.5, sampleRate: sr)
        var noise = NoiseSource(seed: 5)
        return make(0.28, sr) { _, t in
            let env = min(1, t / 0.003) * exp(-t * 11)
            let s = lp.process(saw.next(freq: 92 - 30 * t, sampleRate: sr) + noise.next() * 0.3).lp * env * 0.55
            return (s, s)
        }
    }

    static func miss(sampleRate sr: Double) -> StereoAudio {
        make(0.18, sr) { _, t in
            let s = sin(2 * .pi * (220 - 300 * t) * t) * exp(-t * 20) * 0.18
            return (s, s)
        }
    }

    static func bomb(sampleRate sr: Double) -> StereoAudio {
        var noise = NoiseSource(seed: 77)
        var lp = SVF()
        var phase = 0.0
        return make(0.9, sr) { i, t in
            if i % 16 == 0 { lp.set(cutoff: 3000 * exp(-t * 6) + 120, q: 0.9, sampleRate: sr) }
            phase += 2 * .pi * (40 + 120 * exp(-t * 9)) / sr
            let boom = sin(phase) * exp(-t * 4) * 0.8
            let crack = lp.process(noise.next()).lp * exp(-t * 5) * 0.9
            let s = tanh((boom + crack) * 1.4) * 0.7 * min(1, t / 0.002)
            return (s, s)
        }
    }

    static func tone(sampleRate sr: Double, freq: Double, length: Double, decay: Double, level: Double) -> StereoAudio {
        make(length, sr) { _, t in
            let env = min(1, t / 0.003) * exp(-t * decay)
            let s = (sin(2 * .pi * freq * t) + 0.3 * sin(4 * .pi * freq * t)) * env * level
            return (s, s)
        }
    }

    static func chime(sampleRate sr: Double) -> StereoAudio {
        make(0.6, sr) { _, t in
            let a = sin(2 * .pi * 1046.5 * t) * exp(-t * 7)
            let b = t > 0.08 ? sin(2 * .pi * 1568 * (t - 0.08)) * exp(-(t - 0.08) * 6) : 0
            let s = (a + b) * 0.25 * min(1, t / 0.003)
            return (s, s * 0.9)
        }
    }

    static func fail(sampleRate sr: Double) -> StereoAudio {
        var saw = SawOsc()
        var lp = SVF()
        return make(1.4, sr) { i, t in
            if i % 16 == 0 { lp.set(cutoff: 2400 * exp(-t * 2.5) + 100, q: 2, sampleRate: sr) }
            let f = 330 * exp(-t * 1.6)
            let s = lp.process(saw.next(freq: f, sampleRate: sr)).lp * exp(-t * 1.8) * 0.5
            return (s, s)
        }
    }

    static func clear(sampleRate sr: Double) -> StereoAudio {
        let notes: [(Double, Double)] = [(0, 69), (0.09, 72), (0.18, 76), (0.27, 81)]
        return make(1.4, sr) { _, t in
            var s = 0.0
            for (start, m) in notes where t >= start {
                let tt = t - start
                let f = midiToFreq(m)
                s += (sin(2 * .pi * f * tt) + 0.4 * sin(4 * .pi * f * tt)) * exp(-tt * 3.2) * min(1, tt / 0.003)
            }
            s *= 0.18
            return (s, s)
        }
    }
}
