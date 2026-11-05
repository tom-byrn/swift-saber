import Foundation

/// Plays a beatmap perfectly: each saber winds up, swings through its next block along the
/// arrow, follows through, then glides into position for the next one.
/// Used for the in-game demo and the automated tests.
public struct AutoplayDriver: Sendable {
    public static let swingBefore = 0.11
    public static let swingAfter = 0.08
    static let angleBefore = radians(-100)
    static let angleAfter = radians(65)

    private let notesByHand: [Hand: [Note]]
    private let speed: Double

    /// `primaryHand` takes every block in one-saber maps.
    public init(beatmap: Beatmap, primaryHand: Hand = .right) {
        speed = beatmap.noteSpeed
        if beatmap.mode == .oneSaber {
            notesByHand = [primaryHand: beatmap.notes, primaryHand.other: []]
        } else {
            notesByHand = [
                .left: beatmap.notes.filter { $0.hand == .left },
                .right: beatmap.notes.filter { $0.hand == .right },
            ]
        }
    }

    func swingDirection(note: Note, hand: Hand, phase p: Double) -> Vec3 {
        let pivot = Arena.pivot(for: hand)
        let target = NoteMotion(speed: speed).position(column: note.column, row: note.row, beatTime: note.time, now: note.time)
        var d = note.direction.vector
        if note.direction == .any { d = (0, -1) }
        let toTarget = (target - pivot).normalized
        let axis = toTarget.cross(Vec3(d.x, d.y, 0)).normalized
        let angle = Self.angleBefore + (Self.angleAfter - Self.angleBefore) * p
        return Quat(axis: axis, angle: angle).rotate(toTarget)
    }

    public func direction(hand: Hand, time t: Double) -> Vec3 {
        let idle = Vec3(hand == .left ? -0.3 : 0.3, -0.6, -1).normalized
        guard let mine = notesByHand[hand], !mine.isEmpty else { return idle }
        // First note whose swing has not finished yet (binary search).
        var lo = 0, hi = mine.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if mine[mid].time + Self.swingAfter > t { hi = mid } else { lo = mid + 1 }
        }
        guard lo < mine.count else { return idle }
        let next = mine[lo]
        let swingStart = next.time - Self.swingBefore
        if t >= swingStart {
            let p = (t - swingStart) / (Self.swingBefore + Self.swingAfter)
            return swingDirection(note: next, hand: hand, phase: clamp(p, 0, 1))
        }
        let startDir = swingDirection(note: next, hand: hand, phase: 0)
        guard lo > 0 else { return idle.slerpDirection(to: startDir, clamp(1 - (swingStart - t) / 0.6, 0, 1)) }
        let prev = mine[lo - 1]
        let endDir = swingDirection(note: prev, hand: hand, phase: 1)
        let returnStart = prev.time + Self.swingAfter
        let p = clamp((t - returnStart) / max(swingStart - returnStart, 1e-3), 0, 1)
        let s = p * p * (3 - 2 * p)
        // Long resets go through a neutral pose on the hand's own side instead of
        // taking a near-180-degree shortcut across the other lanes.
        if endDir.angle(to: startDir) > radians(100) {
            let neutral = Vec3(hand == .left ? -0.35 : 0.35, -0.15, -1).normalized
            return s < 0.5
                ? endDir.slerpDirection(to: neutral, s * 2)
                : neutral.slerpDirection(to: startDir, (s - 0.5) * 2)
        }
        return endDir.slerpDirection(to: startDir, s)
    }

    public func inputs(time t: Double) -> [SaberInput] {
        Hand.allCases.compactMap { hand in
            guard let ns = notesByHand[hand], !ns.isEmpty else {
                return SaberInput(hand: hand, direction: .forward, active: false)
            }
            return SaberInput(hand: hand, direction: direction(hand: hand, time: t), active: true)
        }
    }
}
