import Foundation

/// Builds the "Prism Run" beatmaps.
///
/// Rhythm is hand-authored per section and difficulty (one 8-character string per bar,
/// one character per eighth note), so every block lands on the music. Cut directions
/// and positions are then assigned with swing "parity" rules so that each hand
/// alternates naturally between forehand (down) and backhand (up) cuts.
///
/// Rhythm alphabet:  `L` / `R` left or right block, `B` both hands,
///                   lowercase = dot block (any direction), `.` rest.
public enum LevelDesigner {

    public static func beatmap(song: SongDefinition = .prismRun, difficulty: Difficulty, mode: PlayMode) -> Beatmap {
        var slots = rhythmSlots(song: song, difficulty: difficulty)
        if mode == .oneSaber { slots = oneSaberSlots(from: slots, difficulty: difficulty) }

        var rng = SeededRandom(seed: 0x5A1E + UInt64(difficulty.rawValue) * 101 + UInt64(mode.rawValue) * 7)
        var flow = FlowState()
        var notes: [Note] = []
        for slot in slots {
            let section = song.section(atBar: Int(slot.beat) / song.beatsPerBar)
            let placed = flow.place(slot: slot, difficulty: difficulty, mode: mode,
                                    sectionKind: section?.kind ?? .groove, rng: &rng)
            for p in placed {
                notes.append(Note(id: notes.count, beat: slot.beat, time: song.time(ofBeat: slot.beat),
                                  column: p.column, row: p.row, hand: p.hand, direction: p.direction))
            }
        }
        let bombs = placeBombs(song: song, notes: notes, difficulty: difficulty, mode: mode)
        return Beatmap(songTitle: song.title, difficulty: difficulty, mode: mode, bpm: song.bpm,
                       noteSpeed: difficulty.noteSpeed, duration: song.duration, notes: notes,
                       bombs: bombs, lights: LightingDirector.events(for: song))
    }

    // MARK: - Rhythm

    struct Slot {
        var beat: Double
        var hands: [Hand]
        var dot: Bool
    }

    static func rhythmSlots(song: SongDefinition, difficulty: Difficulty) -> [Slot] {
        var slots: [Slot] = []
        for bar in 0..<song.totalBars {
            guard let s = song.section(atBar: bar) else { continue }
            guard let pattern = barPattern(kind: s.kind, rel: bar - s.startBar, occurrence: s.occurrence, difficulty: difficulty) else { continue }
            let chars = Array(pattern)
            for (i, c) in chars.enumerated() {
                let beat = Double(bar * song.beatsPerBar) + Double(i) * 0.5
                switch c {
                case "L": slots.append(Slot(beat: beat, hands: [.left], dot: false))
                case "R": slots.append(Slot(beat: beat, hands: [.right], dot: false))
                case "B": slots.append(Slot(beat: beat, hands: [.left, .right], dot: false))
                case "l": slots.append(Slot(beat: beat, hands: [.left], dot: true))
                case "r": slots.append(Slot(beat: beat, hands: [.right], dot: true))
                case "b": slots.append(Slot(beat: beat, hands: [.left, .right], dot: true))
                default: break
                }
            }
        }
        return slots
    }

    static func barPattern(kind: SectionKind, rel: Int, occurrence: Int, difficulty: Difficulty) -> String? {
        switch difficulty {
        case .easy:
            switch kind {
            case .intro: return rel < 2 ? nil : "L...R..."
            case .groove: return "L...R..."
            case .build: return rel == 7 ? "B......." : "L...R..."
            case .drop: return ["B.......", "L...R...", "R...L...", "L...R..."][rel % 4]
            case .breakdown: return rel == 0 ? nil : (rel % 2 == 1 ? "l......." : "....r...")
            case .outro: return rel < 4 ? "L...R..." : (rel == 4 ? "B......." : nil)
            }
        case .normal:
            switch kind {
            case .intro: return rel < 2 ? nil : (rel < 6 ? "L...R..." : "L.R.L.R.")
            case .groove: return rel % 2 == 0 ? "L...R..." : "L.R.L.R."
            case .build:
                if rel < 4 { return "L...R..." }
                return rel == 7 ? "B...B..." : "L.R.L.R."
            case .drop: return ["B...L.R.", "L.R.L.R.", "B...R.L.", "R.L.R.L."][rel % 4]
            case .breakdown: return rel == 0 ? nil : "l...r..."
            case .outro:
                if rel < 4 { return "L.R.L.R." }
                if rel < 6 { return "L...R..." }
                return rel == 6 ? "B......." : nil
            }
        case .hard:
            switch kind {
            case .intro: return rel < 2 ? nil : (rel < 4 ? "L...R..." : "L.R.L.R.")
            case .groove: return rel < 4 ? "L.R.L.R." : "L.RLR.L."
            case .build:
                if rel < 4 { return "L.R.L.R." }
                if rel < 6 { return "L.RLR.L." }
                return rel == 6 ? "LRLRLRLR" : "B.B.B..."
            case .drop: return ["B..LR.LR", "L.R.LRL.", "B..RL.RL", "R.L.RLR."][rel % 4]
            case .breakdown: return rel == 0 ? nil : (rel < 4 ? "l...r..." : "L.R.L.R.")
            case .outro:
                if rel < 4 { return "L.R.L.R." }
                if rel < 6 { return "L...R..." }
                return rel == 6 ? "B......." : nil
            }
        case .expert:
            switch kind {
            case .intro:
                if rel < 2 { return nil }
                if rel < 4 { return "L.R.L.R." }
                return rel < 6 ? "L.RLR.L." : (rel == 6 ? "LRLRLRL." : "B.LRLRLR")
            case .groove: return rel % 2 == 0 ? "LRLRLRL." : "B.LRLRLR"
            case .build:
                if rel < 4 { return rel % 2 == 0 ? "LRLRLRL." : "B.LRLRLR" }
                if rel < 6 { return "LRLRLRLR" }
                return rel == 6 ? "LRLRLRL." : "B.B.B..."
            case .drop: return ["B.LRLRLR", "LRLR.B..", "B.RLRLRL", "RLRL.B.."][rel % 4]
            case .breakdown: return rel == 0 ? nil : (rel < 4 ? "l.r.l.r." : "L.RLR.L.")
            case .outro:
                if rel < 2 { return "LRLRLRL." }
                if rel < 4 { return "B.LRLRLR" }
                if rel < 6 { return "L.R.L.R." }
                return rel == 6 ? "B...B..." : nil
            }
        }
    }

    /// Merges both hands into a single stream, keeping a minimum spacing between swings.
    static func oneSaberSlots(from slots: [Slot], difficulty: Difficulty) -> [Slot] {
        let minGap: Double
        switch difficulty {
        case .easy: minGap = 2
        case .normal: minGap = 1.5
        case .hard: minGap = 1
        case .expert: minGap = 1
        }
        var out: [Slot] = []
        var last = -1000.0
        for s in slots where s.beat - last >= minGap - 1e-6 {
            out.append(Slot(beat: s.beat, hands: [.right], dot: s.dot))
            last = s.beat
        }
        return out
    }

    // MARK: - Flow (parity) assignment

    struct Placement {
        var hand: Hand
        var column: Int
        var row: Int
        var direction: CutDirection
    }

    struct HandFlow {
        var lastBeat: Double = -1000
        var lastDirection: CutDirection?
        var lastColumn: Int = -1
    }

    struct FlowState {
        var hands: [Hand: HandFlow] = [.left: HandFlow(), .right: HandFlow()]

        /// After this many beats without a block a hand is assumed to be "reset" (raised, ready to cut down).
        let resetBeats = 2.5

        func expectsDownward(_ hand: Hand, at beat: Double) -> Bool {
            let h = hands[hand]!
            guard let last = h.lastDirection, beat - h.lastBeat < resetBeats else { return true }
            if last.isHorizontal { return true }
            return !last.isDownward
        }

        mutating func place(slot: Slot, difficulty: Difficulty, mode: PlayMode, sectionKind: SectionKind,
                            rng: inout SeededRandom) -> [Placement] {
            if slot.hands.count == 2 {
                return placeDouble(slot: slot, difficulty: difficulty, rng: &rng)
            }
            let hand = slot.hands[0]
            let downward = expectsDownward(hand, at: slot.beat)
            let direction = chooseDirection(hand: hand, downward: downward, beat: slot.beat,
                                            difficulty: difficulty, sectionKind: sectionKind, rng: &rng)
            let row = chooseRow(direction: direction, difficulty: difficulty, rng: &rng)
            let column = chooseColumn(hand: hand, direction: direction, oneSaber: mode == .oneSaber, rng: &rng)
            commit(hand: hand, beat: slot.beat, direction: direction, column: column)
            return [Placement(hand: hand, column: column, row: row, direction: slot.dot ? .any : direction)]
        }

        mutating func placeDouble(slot: Slot, difficulty: Difficulty, rng: inout SeededRandom) -> [Placement] {
            var leftDown = expectsDownward(.left, at: slot.beat)
            var rightDown = expectsDownward(.right, at: slot.beat)
            // Doubles read best when both hands swing the same way. A hand that has been
            // idle long enough can adapt to the other one; otherwise each keeps its own flow.
            let leftFresh = slot.beat - hands[.left]!.lastBeat >= resetBeats
            let rightFresh = slot.beat - hands[.right]!.lastBeat >= resetBeats
            if leftDown != rightDown {
                if leftFresh && !rightFresh { leftDown = rightDown }
                else if rightFresh && !leftFresh { rightDown = leftDown }
                else if leftFresh && rightFresh { leftDown = true; rightDown = true }
            }
            var wide = rng.chance(0.4)
            let row = (leftDown && rightDown) ? (rng.chance(0.7) ? 0 : 1) : (rng.chance(0.6) ? 0 : 1)
            var leftDir: CutDirection = leftDown ? .down : .up
            var rightDir: CutDirection = rightDown ? .down : .up
            if difficulty != .easy && leftDown == rightDown && rng.chance(0.35) {
                // Mirrored diagonals.
                leftDir = leftDown ? .downLeft : .upLeft
                rightDir = rightDown ? .downRight : .upRight
                // Diagonal doubles on the inner lanes would make the blades cross.
                wide = true
            }
            let lc = wide ? 0 : 1, rc = wide ? 3 : 2
            commit(hand: .left, beat: slot.beat, direction: leftDir, column: lc)
            commit(hand: .right, beat: slot.beat, direction: rightDir, column: rc)
            return [
                Placement(hand: .left, column: lc, row: row, direction: slot.dot ? .any : leftDir),
                Placement(hand: .right, column: rc, row: row, direction: slot.dot ? .any : rightDir),
            ]
        }

        mutating func commit(hand: Hand, beat: Double, direction: CutDirection, column: Int) {
            hands[hand]!.lastBeat = beat
            hands[hand]!.lastDirection = direction
            hands[hand]!.lastColumn = column
        }

        func chooseDirection(hand: Hand, downward: Bool, beat: Double, difficulty: Difficulty,
                             sectionKind: SectionKind, rng: inout SeededRandom) -> CutDirection {
            let h = hands[hand]!
            let fresh = h.lastDirection == nil || beat - h.lastBeat >= resetBeats
            if difficulty == .easy { return downward ? .down : .up }

            // Perfect flow: reverse the previous swing.
            if !fresh, let last = h.lastDirection, !last.isHorizontal, rng.chance(0.55) {
                return last.opposite
            }
            let diagonalChance: Double
            switch difficulty {
            case .easy: diagonalChance = 0
            case .normal: diagonalChance = 0.18
            case .hard: diagonalChance = 0.3
            case .expert: diagonalChance = 0.38
            }
            let outward: CutDirection
            let inward: CutDirection
            if downward {
                outward = hand == .left ? .downLeft : .downRight
                inward = hand == .left ? .downRight : .downLeft
            } else {
                outward = hand == .left ? .upLeft : .upRight
                inward = hand == .left ? .upRight : .upLeft
            }
            var candidate: CutDirection = downward ? .down : .up
            if rng.chance(diagonalChance) {
                candidate = rng.chance(0.7) ? outward : inward
            }
            // Never ask for more than a 45 degree deviation from the natural return swing.
            if !fresh, let last = h.lastDirection, !last.isHorizontal {
                let want = last.opposite.vector
                let got = candidate.vector
                if want.x * got.x + want.y * got.y < 0.7 { candidate = downward ? .down : .up }
            }
            return candidate
        }

        func chooseRow(direction: CutDirection, difficulty: Difficulty, rng: inout SeededRandom) -> Int {
            let r = rng.unit()
            let topChance: Double = difficulty.rawValue >= Difficulty.hard.rawValue ? 0.1 : 0.0
            if direction.isDownward {
                if r < topChance { return 2 }
                return r < topChance + 0.3 ? 1 : 0
            } else {
                if r < topChance * 0.6 { return 2 }
                return r < 0.35 ? 1 : 0
            }
        }

        func chooseColumn(hand: Hand, direction: CutDirection, oneSaber: Bool, rng: inout SeededRandom) -> Int {
            if oneSaber { return rng.chance(0.7) ? (rng.chance(0.5) ? 1 : 2) : (rng.chance(0.5) ? 0 : 3) }
            let h = hands[hand]!
            let inner = hand == .left ? 1 : 2
            let outer = hand == .left ? 0 : 3
            let isOutwardDiagonal = hand == .left
                ? (direction == .downLeft || direction == .upLeft)
                : (direction == .downRight || direction == .upRight)
            if isOutwardDiagonal { return rng.chance(0.7) ? outer : inner }
            // Gentle column persistence so hands do not jump around.
            if h.lastColumn >= 0, rng.chance(0.5) { return h.lastColumn }
            return rng.chance(0.6) ? inner : outer
        }
    }

    // MARK: - Bombs

    static func placeBombs(song: SongDefinition, notes: [Note], difficulty: Difficulty, mode: PlayMode) -> [Bomb] {
        guard difficulty != .easy else { return [] }
        var bombs: [Bomb] = []
        func occupied(column: Int, row: Int, beat: Double, window: Double) -> Bool {
            notes.contains { $0.column == column && $0.row == row && abs($0.beat - beat) < window }
        }
        func columnBusy(_ column: Int, beat: Double, window: Double) -> Bool {
            notes.contains { $0.column == column && abs($0.beat - beat) < window }
        }
        for s in song.sections {
            var candidateBars: [Int] = []
            switch s.kind {
            case .drop:
                let bars = difficulty == .normal ? [6, 14] : [5, 6, 13, 14]
                candidateBars = bars.map { s.startBar + $0 }
            case .breakdown:
                candidateBars = [s.startBar + 2, s.startBar + 3]
            default: continue
            }
            for bar in candidateBars {
                for beatInBar in [0.0, 2.0] {
                    let beat = Double(bar * song.beatsPerBar) + beatInBar
                    // Find blocks on this beat and put a bomb on the opposite side, top row.
                    let here = notes.filter { abs($0.beat - beat) < 0.01 }
                    guard here.count == 1, let n = here.first else { continue }
                    let column: Int
                    if mode == .oneSaber {
                        column = n.column <= 1 ? 3 : 0
                    } else {
                        column = n.hand == .left ? 3 : 0
                    }
                    let row = 2
                    if occupied(column: column, row: row, beat: beat, window: 1.5) { continue }
                    if columnBusy(column, beat: beat, window: 0.75) { continue }
                    bombs.append(Bomb(id: bombs.count, beat: beat, time: song.time(ofBeat: beat), column: column, row: row))
                }
            }
        }
        return bombs
    }
}

/// Generates the light show from the song arrangement.
public enum LightingDirector {
    public static func events(for song: SongDefinition) -> [LightEvent] {
        var ev: [LightEvent] = []
        func add(_ beat: Double, _ group: LightGroup, _ action: LightAction) {
            ev.append(LightEvent(beat: beat, time: song.time(ofBeat: beat), group: group, action: action))
        }
        let bpb = Double(song.beatsPerBar)

        for s in song.sections {
            let start = Double(s.startBar) * bpb
            switch s.kind {
            case .intro:
                add(start, .back, .on(.blue))
                add(start, .floor, .on(.blue))
                add(start, .rings, .off)
                add(start, .leftLasers, .off)
                add(start, .rightLasers, .off)
                for bar in 4..<s.bars {
                    let b0 = start + Double(bar) * bpb
                    if bar == 4 {
                        add(b0, .rings, .on(.blue))
                        add(b0, .rings, .spin(1))
                    }
                    for k in 0..<4 { add(b0 + Double(k), .floor, .flash(.blue)) }
                }
            case .groove:
                add(start, .leftLasers, .on(.red))
                add(start, .rightLasers, .on(.blue))
                add(start, .leftLasers, .speed(1.5))
                add(start, .rightLasers, .speed(1.5))
                add(start, .back, .flash(.white))
                for bar in 0..<s.bars {
                    let b0 = start + Double(bar) * bpb
                    let color: LightColor = bar % 2 == 0 ? .red : .blue
                    for k in 0..<4 {
                        add(b0 + Double(k), .rings, .flash(color))
                        add(b0 + Double(k), .floor, .flash(color))
                    }
                    if bar >= 4 {
                        add(b0 + 1, .back, .flash(.red))
                        add(b0 + 3, .back, .flash(.blue))
                    }
                    if bar % 4 == 0 { add(b0, .rings, .spin(bar % 8 == 0 ? 1 : -1)) }
                }
            case .build:
                add(start, .leftLasers, .speed(0.4))
                add(start, .rightLasers, .speed(0.4))
                add(start, .leftLasers, .fade(.blue))
                add(start, .rightLasers, .fade(.blue))
                add(start, .rings, .zoom)
                add(start, .back, .on(.blue))
                for bar in 0..<s.bars {
                    let b0 = start + Double(bar) * bpb
                    let step: Double = bar < 2 ? 2 : (bar < 4 ? 1 : (bar < 6 ? 0.5 : 0.25))
                    var b = 0.0
                    var i = 0
                    while b < bpb - 1e-9 {
                        let lastBeat = bar == s.bars - 1 && b >= 3.5
                        if !lastBeat {
                            let color: LightColor = bar >= 6 ? .white : (i % 2 == 0 ? .blue : .red)
                            add(b0 + b, .rings, .fade(color))
                            if bar >= 4 { add(b0 + b, .floor, .fade(color)) }
                        }
                        b += step
                        i += 1
                    }
                    if bar == s.bars - 1 {
                        // Blackout right before the drop.
                        for g in LightGroup.allCases { add(b0 + 3.5, g, .off) }
                    }
                }
            case .drop:
                for g in LightGroup.allCases { add(start, g, .flash(.white)) }
                add(start, .rings, .spin(1))
                add(start, .rings, .zoom)
                add(start, .leftLasers, .speed(4))
                add(start, .rightLasers, .speed(4))
                for bar in 0..<s.bars {
                    let b0 = start + Double(bar) * bpb
                    let a: LightColor = (bar / 2) % 2 == 0 ? .red : .blue
                    let b: LightColor = a == .red ? .blue : .red
                    for k in 0..<4 {
                        let beat = b0 + Double(k)
                        if !(bar == 0 && k == 0) {
                            add(beat, .rings, .flash(s.occurrence >= 2 && k % 2 == 1 ? b : a))
                            add(beat, .floor, .flash(a))
                        }
                        add(beat, k % 2 == 0 ? .leftLasers : .rightLasers, .flash(k % 2 == 0 ? .red : .blue))
                    }
                    add(b0 + 1, .back, .flash(b))
                    add(b0 + 3, .back, .flash(a))
                    if bar % 4 == 3 { add(b0 + 3, .rings, .spin(bar % 8 == 3 ? -1 : 1)) }
                    if bar % 8 == 7 { add(b0 + 3.5, .rings, .zoom) }
                }
            case .breakdown:
                add(start, .rings, .fade(.blue))
                add(start, .back, .on(.blue))
                add(start, .floor, .on(.blue))
                add(start, .leftLasers, .on(.blue))
                add(start, .rightLasers, .on(.blue))
                add(start, .leftLasers, .speed(0.6))
                add(start, .rightLasers, .speed(0.6))
                add(start, .rings, .spin(-1))
                for bar in 1..<s.bars {
                    let b0 = start + Double(bar) * bpb
                    add(b0, .rings, .fade(.blue))
                    if bar >= 4 {
                        add(b0 + 2, .rings, .fade(.red))
                    }
                    if bar >= 6 { add(b0 + 3, .back, .flash(.white)) }
                }
            case .outro:
                add(start, .back, .flash(.white))
                add(start, .leftLasers, .speed(1.2))
                add(start, .rightLasers, .speed(1.2))
                for bar in 0..<s.bars {
                    let b0 = start + Double(bar) * bpb
                    if bar < 4 {
                        let color: LightColor = bar % 2 == 0 ? .red : .blue
                        for k in 0..<4 { add(b0 + Double(k), .rings, .flash(color)) }
                    } else if bar == 4 {
                        add(b0, .rings, .fade(.blue))
                        add(b0, .leftLasers, .fade(.red))
                        add(b0, .rightLasers, .fade(.blue))
                        add(b0, .floor, .on(.blue))
                    } else if bar == 6 {
                        add(b0, .floor, .fade(.blue))
                        add(b0, .back, .fade(.blue))
                    }
                }
            }
        }
        return ev.sorted { $0.time < $1.time }
    }
}
