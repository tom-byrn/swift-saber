import Foundation

/// The arrangement of the built-in original track, "Prism Run".
/// Both the music synthesizer and the level designer read this so the
/// blocks, lights and music always line up.
public enum SectionKind: String, Codable, Sendable {
    case intro, groove, build, drop, breakdown, outro
}

public struct Section: Sendable {
    public var kind: SectionKind
    public var startBar: Int
    public var bars: Int
    /// 1 for the first occurrence of a kind, 2 for the second, ...
    public var occurrence: Int
    public var endBar: Int { startBar + bars }
}

public struct MelodyNote: Sendable {
    /// Beat offset inside the phrase.
    public var beat: Double
    public var midi: Int
    public var length: Double
}

public struct SongDefinition: Sendable {
    public let title: String
    public let artist: String
    public let bpm: Double
    public let beatsPerBar: Int
    public let sections: [Section]
    /// Pad voicing for each chord in the loop (one chord per bar).
    public let chordVoicings: [[Int]]
    /// Bass root (MIDI) per chord.
    public let bassRoots: [Int]
    /// Arp chord tones per chord (MIDI).
    public let arpTones: [[Int]]
    /// Lead melody: 4-bar phrases (16 beats).
    public let leadPhraseA: [MelodyNote]
    public let leadPhraseB: [MelodyNote]
    /// Extra tail after the last bar (reverb / delay ring-out), seconds.
    public let tail: Double

    public var secondsPerBeat: Double { 60.0 / bpm }
    public var totalBars: Int { sections.last.map { $0.endBar } ?? 0 }
    public var totalBeats: Double { Double(totalBars * beatsPerBar) }
    public var duration: Double { totalBeats * secondsPerBeat + tail }

    public func time(ofBeat beat: Double) -> Double { beat * secondsPerBeat }
    public func beat(ofTime t: Double) -> Double { t / secondsPerBeat }

    public func section(atBar bar: Int) -> Section? {
        sections.first { bar >= $0.startBar && bar < $0.endBar }
    }

    public func chordIndex(atBar bar: Int) -> Int { ((bar % 4) + 4) % 4 }

    /// The lead melody notes for an absolute bar range in a drop.
    public func leadNotes(inDropStartingAt startBar: Int, bars: Int) -> [MelodyNote] {
        var out: [MelodyNote] = []
        var phraseIndex = 0
        var bar = startBar
        while bar < startBar + bars {
            let phrase = (phraseIndex % 2 == 0) ? leadPhraseA : leadPhraseB
            let base = Double(bar * beatsPerBar)
            for n in phrase {
                out.append(MelodyNote(beat: base + n.beat, midi: n.midi, length: n.length))
            }
            bar += 4
            phraseIndex += 1
        }
        return out
    }

    public static let prismRun: SongDefinition = {
        var sections: [Section] = []
        var bar = 0
        var counts: [SectionKind: Int] = [:]
        func add(_ kind: SectionKind, _ bars: Int) {
            counts[kind, default: 0] += 1
            sections.append(Section(kind: kind, startBar: bar, bars: bars, occurrence: counts[kind]!))
            bar += bars
        }
        add(.intro, 8)
        add(.groove, 8)
        add(.build, 8)
        add(.drop, 16)
        add(.breakdown, 8)
        add(.build, 8)
        add(.drop, 16)
        add(.outro, 8)

        // A natural minor:  Am - F - C - G
        let voicings = [
            [57, 60, 64, 69], // A3 C4 E4 A4
            [57, 60, 65, 69], // A3 C4 F4 A4
            [55, 60, 64, 67], // G3 C4 E4 G4
            [55, 59, 62, 67], // G3 B3 D4 G4
        ]
        let roots = [33, 29, 36, 31] // A1 F1 C2 G1
        let arps = [
            [69, 72, 76, 81], // A4 C5 E5 A5
            [69, 72, 77, 81], // A4 C5 F5 A5
            [67, 72, 76, 79], // G4 C5 E5 G5
            [67, 71, 74, 79], // G4 B4 D5 G5
        ]

        // Original lead hook (beats inside a 4-bar phrase).
        func n(_ beat: Double, _ midi: Int, _ len: Double) -> MelodyNote { MelodyNote(beat: beat, midi: midi, length: len) }
        let phraseA: [MelodyNote] = [
            // bar 1 (Am)
            n(0.0, 76, 0.75), n(0.75, 72, 0.75), n(1.5, 69, 0.5), n(2.0, 72, 0.5), n(2.5, 76, 0.5), n(3.0, 79, 0.5), n(3.5, 76, 0.5),
            // bar 2 (F)
            n(4.0, 77, 0.75), n(4.75, 76, 0.75), n(5.5, 72, 0.5), n(6.0, 69, 1.0), n(7.0, 72, 0.5), n(7.5, 74, 0.5),
            // bar 3 (C)
            n(8.0, 76, 0.75), n(8.75, 72, 0.75), n(9.5, 67, 0.5), n(10.0, 72, 0.5), n(10.5, 76, 0.5), n(11.0, 79, 0.5), n(11.5, 84, 0.5),
            // bar 4 (G)
            n(12.0, 83, 0.75), n(12.75, 79, 0.75), n(13.5, 74, 0.5), n(14.0, 79, 1.0), n(15.0, 81, 0.5), n(15.5, 83, 0.5),
        ]
        let phraseB: [MelodyNote] = [
            n(0.0, 84, 0.75), n(0.75, 81, 0.75), n(1.5, 76, 0.5), n(2.0, 81, 0.5), n(2.5, 84, 0.5), n(3.0, 88, 0.5), n(3.5, 84, 0.5),
            n(4.0, 84, 0.75), n(4.75, 81, 0.75), n(5.5, 77, 0.5), n(6.0, 81, 1.0), n(7.0, 77, 0.5), n(7.5, 79, 0.5),
            n(8.0, 79, 0.75), n(8.75, 76, 0.75), n(9.5, 72, 0.5), n(10.0, 76, 0.5), n(10.5, 79, 0.5), n(11.0, 84, 0.5), n(11.5, 83, 0.5),
            n(12.0, 79, 0.75), n(12.75, 74, 0.75), n(13.5, 71, 0.5), n(14.0, 74, 0.5), n(14.5, 71, 0.5), n(15.0, 69, 1.0),
        ]

        return SongDefinition(
            title: "Prism Run",
            artist: "Swift Saber Original",
            bpm: 128,
            beatsPerBar: 4,
            sections: sections,
            chordVoicings: voicings,
            bassRoots: roots,
            arpTones: arps,
            leadPhraseA: phraseA,
            leadPhraseB: phraseB,
            tail: 3.0
        )
    }()
}
