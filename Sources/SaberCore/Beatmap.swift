import Foundation

public enum Hand: Int, Codable, CaseIterable, Sendable {
    case left = 0
    case right = 1

    public var other: Hand { self == .left ? .right : .left }
    public var name: String { self == .left ? "Left" : "Right" }
}

/// Direction the block must be cut in, as seen by the player.
public enum CutDirection: Int, Codable, CaseIterable, Sendable {
    case up, down, left, right, upLeft, upRight, downLeft, downRight, any

    /// Unit direction in the screen plane (x right, y up). `.any` returns zero.
    public var vector: (x: Double, y: Double) {
        let d = 0.70710678118
        switch self {
        case .up: return (0, 1)
        case .down: return (0, -1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .upLeft: return (-d, d)
        case .upRight: return (d, d)
        case .downLeft: return (-d, -d)
        case .downRight: return (d, -d)
        case .any: return (0, 0)
        }
    }

    /// Counter-clockwise rotation (radians, around +z facing the player) that turns
    /// a downward-pointing arrow into this direction.
    public var arrowRotation: Double {
        if self == .any { return 0 }
        let v = vector
        return atan2(v.x, -v.y)
    }

    public var opposite: CutDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        case .upLeft: return .downRight
        case .upRight: return .downLeft
        case .downLeft: return .upRight
        case .downRight: return .upLeft
        case .any: return .any
        }
    }

    public var isDownward: Bool { self == .down || self == .downLeft || self == .downRight }
    public var isUpward: Bool { self == .up || self == .upLeft || self == .upRight }
    public var isHorizontal: Bool { self == .left || self == .right }
}

public enum Difficulty: Int, Codable, CaseIterable, Sendable, Identifiable {
    case easy, normal, hard, expert
    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        case .expert: return "Expert"
        }
    }

    /// How fast blocks travel towards the player, in metres per second.
    public var noteSpeed: Double {
        switch self {
        case .easy: return 9
        case .normal: return 10.5
        case .hard: return 12
        case .expert: return 13.5
        }
    }
}

public enum PlayMode: Int, Codable, CaseIterable, Sendable, Identifiable {
    /// One saber per hand, red (left) and blue (right).
    case twoSabers
    /// A single saber cuts every block.
    case oneSaber
    public var id: Int { rawValue }
    public var name: String { self == .twoSabers ? "Two Sabers" : "One Saber" }
}

/// Grid layout: 4 columns (0 = far left) and 3 rows (0 = bottom).
public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var beat: Double
    public var time: Double
    public var column: Int
    public var row: Int
    public var hand: Hand
    public var direction: CutDirection

    public init(id: Int, beat: Double, time: Double, column: Int, row: Int, hand: Hand, direction: CutDirection) {
        self.id = id; self.beat = beat; self.time = time
        self.column = column; self.row = row; self.hand = hand; self.direction = direction
    }
}

public struct Bomb: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var beat: Double
    public var time: Double
    public var column: Int
    public var row: Int

    public init(id: Int, beat: Double, time: Double, column: Int, row: Int) {
        self.id = id; self.beat = beat; self.time = time; self.column = column; self.row = row
    }
}

public enum LightColor: Int, Codable, Sendable {
    case off, red, blue, white
}

public enum LightGroup: Int, Codable, CaseIterable, Sendable {
    /// Big horizon strip and emblem at the far end of the track.
    case back
    /// The receding prism rings around the track.
    case rings
    /// Laser fans on the left / right.
    case leftLasers
    case rightLasers
    /// Floor runway lines and player platform trim.
    case floor
}

public enum LightAction: Codable, Equatable, Sendable {
    /// Turn on at steady brightness.
    case on(LightColor)
    /// Flash bright, then settle at steady brightness.
    case flash(LightColor)
    /// Flash bright, then fade to black.
    case fade(LightColor)
    case off
    /// Laser sweep speed (0 = still).
    case speed(Double)
    /// Spin the rings (direction +1 / -1).
    case spin(Double)
    /// Toggle ring spacing (zoom).
    case zoom
}

public struct LightEvent: Codable, Equatable, Sendable {
    public var beat: Double
    public var time: Double
    public var group: LightGroup
    public var action: LightAction

    public init(beat: Double, time: Double, group: LightGroup, action: LightAction) {
        self.beat = beat; self.time = time; self.group = group; self.action = action
    }
}

public struct Beatmap: Codable, Sendable {
    public var songTitle: String
    public var difficulty: Difficulty
    public var mode: PlayMode
    public var bpm: Double
    public var noteSpeed: Double
    public var duration: Double
    public var notes: [Note]
    public var bombs: [Bomb]
    public var lights: [LightEvent]

    public init(songTitle: String, difficulty: Difficulty, mode: PlayMode, bpm: Double, noteSpeed: Double,
                duration: Double, notes: [Note], bombs: [Bomb], lights: [LightEvent]) {
        self.songTitle = songTitle; self.difficulty = difficulty; self.mode = mode; self.bpm = bpm
        self.noteSpeed = noteSpeed; self.duration = duration; self.notes = notes; self.bombs = bombs
        self.lights = lights
    }

    public var notesPerSecond: Double {
        guard let first = notes.first, let last = notes.last, last.time > first.time else { return 0 }
        return Double(notes.count) / (last.time - first.time)
    }
}
