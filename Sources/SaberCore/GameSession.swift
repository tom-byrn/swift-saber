import Foundation

/// State of one saber for a simulation step.
public struct SaberInput: Sendable {
    public var hand: Hand
    public var direction: Vec3
    public var active: Bool
    /// Input latency for this saber (seconds). Collisions are evaluated against where the
    /// blocks were when the motion actually happened.
    public var latency: Double

    public init(hand: Hand, direction: Vec3, active: Bool, latency: Double = 0) {
        self.hand = hand; self.direction = direction; self.active = active; self.latency = latency
    }
}

public struct SessionConfig: Sendable {
    public var noFail: Bool
    /// Allowed deviation from the arrow direction, degrees.
    public var cutTolerance: Double
    /// Minimum blade speed for a valid cut, degrees per second.
    public var minimumSwingSpeed: Double

    public init(noFail: Bool = false, cutTolerance: Double = 60, minimumSwingSpeed: Double = 40) {
        self.noFail = noFail; self.cutTolerance = cutTolerance; self.minimumSwingSpeed = minimumSwingSpeed
    }
}

public enum BadCutReason: String, Sendable {
    case wrongColor = "Wrong saber"
    case wrongDirection = "Wrong direction"
    case tooSlow = "Too slow"
}

public struct CutInfo: Sendable {
    public var noteID: Int
    public var hand: Hand
    /// Note centre at the moment of the cut (simulation time).
    public var position: Vec3
    /// Normal of the cut plane (player space).
    public var planeNormal: Vec3
    /// Direction the blade was moving through the block, screen plane (x, y).
    public var motion: (x: Double, y: Double)
    /// Blade speed, degrees per second.
    public var speed: Double
}

public enum GameEvent: Sendable {
    case cut(CutInfo)
    case scored(noteID: Int, score: CutScore, multiplier: Int, position: Vec3)
    case badCut(CutInfo, BadCutReason)
    case miss(noteID: Int)
    case bombHit(bombID: Int, hand: Hand, position: Vec3)
    case multiplierUp(Int)
    case failed
    case finished
}

/// The rhythm game simulation. Pure logic; the renderer and audio layers drive it.
public final class GameSession {
    public enum NoteState: Sendable { case pending, cut, bad, missed }

    public let beatmap: Beatmap
    public let config: SessionConfig
    public let motion: NoteMotion
    public private(set) var scores = ScoreKeeper()
    public private(set) var noteStates: [NoteState]
    public private(set) var bombHitFlags: [Bool]
    public private(set) var hasFailed = false
    public private(set) var hasFinished = false
    public private(set) var lastTime: Double = -10
    public let maxScore: Int

    private var trackers: [Hand: SwingTracker] = [.left: SwingTracker(), .right: SwingTracker()]
    private var previousDirections: [Hand: Vec3] = [:]
    private var windowStart = 0
    private var bombWindowStart = 0

    private struct PendingCut {
        var noteID: Int
        var hand: Hand
        var axis: Vec3
        var preAngle: Double
        var postAngle: Double
        var planeDistance: Double
        var startTime: Double
        var multiplier: Int
        var position: Vec3
    }
    private var pending: [PendingCut] = []

    public init(beatmap: Beatmap, config: SessionConfig = SessionConfig()) {
        self.beatmap = beatmap
        self.config = config
        self.motion = NoteMotion(speed: beatmap.noteSpeed)
        self.noteStates = Array(repeating: .pending, count: beatmap.notes.count)
        self.bombHitFlags = Array(repeating: false, count: beatmap.bombs.count)
        self.maxScore = ScoreKeeper.maxScore(noteCount: beatmap.notes.count)
    }

    public var isOneSaber: Bool { beatmap.mode == .oneSaber }

    public func swingTracker(for hand: Hand) -> SwingTracker { trackers[hand]! }

    /// Forget previous saber poses (after a pause or recenter) so the next frame does not
    /// register a giant sweep through the field.
    public func resetTracking() {
        previousDirections.removeAll()
        for h in Hand.allCases { trackers[h]!.reset() }
    }

    /// Advances the simulation to `songTime` with the current saber poses.
    public func update(songTime: Double, sabers: [SaberInput]) -> [GameEvent] {
        var events: [GameEvent] = []
        guard !hasFinished else { return events }
        lastTime = songTime

        for saber in sabers {
            guard saber.active else {
                previousDirections[saber.hand] = nil
                trackers[saber.hand]!.reset()
                continue
            }
            let simTime = songTime - saber.latency
            let dir = saber.direction.normalized
            let prevDir = previousDirections[saber.hand] ?? dir
            trackers[saber.hand]!.update(direction: dir, time: songTime)
            let tracker = trackers[saber.hand]!

            updatePending(for: saber.hand, tracker: tracker, time: songTime, events: &events)
            collide(saber: saber, from: prevDir, to: dir, simTime: simTime, tracker: tracker, events: &events)
            previousDirections[saber.hand] = dir
        }

        // Misses: blocks that went past the player.
        let maxLatency = sabers.filter { $0.active }.map { $0.latency }.max() ?? 0
        let missTime = songTime - maxLatency
        var i = windowStart
        while i < beatmap.notes.count {
            let n = beatmap.notes[i]
            let z = motion.z(beatTime: n.time, now: missTime)
            if z < Arena.missZ { break }
            if noteStates[i] == .pending {
                noteStates[i] = .missed
                scores.registerMiss()
                events.append(.miss(noteID: n.id))
            }
            i += 1
        }
        windowStart = i

        // Finalise any follow-through that has gone on long enough.
        for idx in pending.indices.reversed() where songTime - pending[idx].startTime > 0.4 {
            finalize(pendingIndex: idx, events: &events)
        }

        if !config.noFail && !hasFailed && scores.energy <= 0 {
            hasFailed = true
            events.append(.failed)
        }
        if songTime >= beatmap.duration - 1.0 {
            for idx in pending.indices.reversed() { finalize(pendingIndex: idx, events: &events) }
            hasFinished = true
            events.append(.finished)
        }
        return events
    }

    // MARK: - Collision

    private func collide(saber: SaberInput, from prev: Vec3, to cur: Vec3, simTime: Double,
                         tracker: SwingTracker, events: inout [GameEvent]) {
        let pivot = Arena.pivot(for: saber.hand)
        let sweep = prev.angle(to: cur)
        // A jump this large in one frame is a teleport (recenter / reconnect), not a swing.
        if sweep > 2.2 { return }
        let steps = max(1, min(16, Int(degrees(sweep) / 3) + 1))
        let lookAhead = 1.2, lookBehind = 0.6

        // Notes
        var i = windowStart
        while i < beatmap.notes.count {
            let n = beatmap.notes[i]
            if n.time - simTime > lookAhead { break }
            defer { i += 1 }
            guard noteStates[i] == .pending, simTime - n.time < lookBehind else { continue }
            let center = motion.position(column: n.column, row: n.row, beatTime: n.time, now: simTime)
            var hit = false
            for s in 0...steps {
                let d = prev.slerpDirection(to: cur, Double(s) / Double(steps))
                let g = SaberGeometry(pivot: pivot, direction: d)
                if Intersection.segmentHitsBox(g.hilt, g.tip, center: center, halfExtents: Arena.hitHalfExtents) {
                    hit = true
                    break
                }
            }
            if hit { resolveCut(note: n, index: i, saber: saber, center: center, pivot: pivot, tracker: tracker, time: lastTime, events: &events) }
        }

        // Bombs
        var b = bombWindowStart
        while b < beatmap.bombs.count {
            let bomb = beatmap.bombs[b]
            if bomb.time - simTime > lookAhead { break }
            if motion.z(beatTime: bomb.time, now: simTime) > Arena.despawnZ, b == bombWindowStart {
                bombWindowStart += 1
                b += 1
                continue
            }
            defer { b += 1 }
            guard !bombHitFlags[b], simTime - bomb.time < lookBehind else { continue }
            let center = motion.position(column: bomb.column, row: bomb.row, beatTime: bomb.time, now: simTime)
            for s in 0...steps {
                let d = prev.slerpDirection(to: cur, Double(s) / Double(steps))
                let g = SaberGeometry(pivot: pivot, direction: d)
                if Intersection.distancePointSegment(center, g.hilt, g.tip) < Arena.bombRadius {
                    bombHitFlags[b] = true
                    scores.registerBomb()
                    events.append(.bombHit(bombID: bomb.id, hand: saber.hand, position: center))
                    break
                }
            }
        }
    }

    private func resolveCut(note: Note, index: Int, saber: SaberInput, center: Vec3, pivot: Vec3,
                            tracker: SwingTracker, time: Double, events: inout [GameEvent]) {
        let axis = tracker.frameAxis ?? tracker.swingAxis ?? Vec3.unitX
        let lever = center - pivot
        let m = axis.cross(lever)
        let ml = (m.x * m.x + m.y * m.y).squareRoot()
        let motion2D = ml > 1e-6 ? (x: m.x / ml, y: m.y / ml) : (x: 0.0, y: 0.0)
        let info = CutInfo(noteID: note.id, hand: saber.hand, position: center, planeNormal: axis,
                           motion: motion2D, speed: tracker.angularSpeed)

        var reason: BadCutReason?
        if !isOneSaber && note.hand != saber.hand {
            reason = .wrongColor
        } else if tracker.angularSpeed < config.minimumSwingSpeed || ml < 1e-6 {
            reason = .tooSlow
        } else if note.direction != .any {
            let want = note.direction.vector
            let dot = motion2D.x * want.x + motion2D.y * want.y
            if dot < cos(radians(config.cutTolerance)) { reason = .wrongDirection }
        }

        if let r = reason {
            noteStates[index] = .bad
            scores.registerBadCut()
            events.append(.badCut(info, r))
            return
        }

        noteStates[index] = .cut
        let previousMultiplier = scores.multiplier
        let mult = scores.registerGoodCut()
        if scores.multiplier > previousMultiplier { events.append(.multiplierUp(scores.multiplier)) }
        let planeDistance = abs(lever.dot(axis))
        pending.append(PendingCut(noteID: note.id, hand: saber.hand, axis: axis, preAngle: tracker.swingAngle,
                                  postAngle: 0, planeDistance: planeDistance, startTime: time,
                                  multiplier: mult, position: center))
        events.append(.cut(info))
    }

    // MARK: - Follow-through

    private func updatePending(for hand: Hand, tracker: SwingTracker, time: Double, events: inout [GameEvent]) {
        for idx in pending.indices.reversed() where pending[idx].hand == hand && pending[idx].startTime < time {
            var p = pending[idx]
            let continuing = (tracker.frameAxis.map { $0.dot(p.axis) > 0.2 } ?? false)
                && tracker.angularSpeed >= SwingTracker.stillSpeed
            if continuing {
                p.postAngle += tracker.frameAngle
                pending[idx] = p
                if p.postAngle >= CutScore.fullPostSwingDegrees {
                    finalize(pendingIndex: idx, events: &events)
                }
            } else {
                finalize(pendingIndex: idx, events: &events)
            }
        }
    }

    private func finalize(pendingIndex idx: Int, events: inout [GameEvent]) {
        let p = pending.remove(at: idx)
        let s = CutScore(preAngle: p.preAngle, postAngle: p.postAngle, planeDistance: p.planeDistance)
        scores.addCutScore(s, multiplier: p.multiplier)
        events.append(.scored(noteID: p.noteID, score: s, multiplier: p.multiplier, position: p.position))
    }

    // MARK: - Results

    public func results() -> GameResults {
        let n = Double(max(scores.scoredCuts, 1))
        let percent = maxScore > 0 ? Double(scores.score) / Double(maxScore) : 0
        return GameResults(
            score: scores.score,
            maxScore: maxScore,
            rank: hasFailed ? .e : Rank.from(percent: percent),
            percent: percent,
            maxCombo: scores.maxCombo,
            goodCuts: scores.goodCuts,
            totalNotes: beatmap.notes.count,
            misses: scores.misses,
            badCuts: scores.badCuts,
            bombHits: scores.bombHits,
            averageCut: Double(scores.cutScoreSum) / n,
            averagePre: Double(scores.preSum) / n,
            averagePost: Double(scores.postSum) / n,
            averageAccuracy: Double(scores.accSum) / n,
            failed: hasFailed
        )
    }

    /// Song progress 0...1.
    public func progress(at t: Double) -> Double {
        clamp(t / max(beatmap.duration, 1), 0, 1)
    }
}
