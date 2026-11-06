import Foundation

public enum Rank: String, Codable, Sendable {
    case ss = "SS", s = "S", a = "A", b = "B", c = "C", d = "D", e = "E"

    public static func from(percent: Double) -> Rank {
        switch percent {
        case 0.9...: return .ss
        case 0.8..<0.9: return .s
        case 0.65..<0.8: return .a
        case 0.5..<0.65: return .b
        case 0.35..<0.5: return .c
        case 0.2..<0.35: return .d
        default: return .e
        }
    }
}

/// Points for a single cut (max 115 = 70 swing-in + 30 follow-through + 15 accuracy).
public struct CutScore: Equatable, Sendable {
    public var preSwing: Int
    public var postSwing: Int
    public var accuracy: Int
    public var total: Int { preSwing + postSwing + accuracy }

    public static let maxPre = 70
    public static let maxPost = 30
    public static let maxAccuracy = 15
    public static let max = maxPre + maxPost + maxAccuracy

    /// Swing angles (degrees) that earn full points.
    public static let fullPreSwingDegrees: Double = 90
    public static let fullPostSwingDegrees: Double = 50

    public init(preSwing: Int, postSwing: Int, accuracy: Int) {
        self.preSwing = preSwing; self.postSwing = postSwing; self.accuracy = accuracy
    }

    public init(preAngle: Double, postAngle: Double, planeDistance: Double) {
        preSwing = Int((clamp(preAngle / Self.fullPreSwingDegrees, 0, 1) * Double(Self.maxPre)).rounded())
        postSwing = Int((clamp(postAngle / Self.fullPostSwingDegrees, 0, 1) * Double(Self.maxPost)).rounded())
        accuracy = Int((clamp(1 - planeDistance / 0.3, 0, 1) * Double(Self.maxAccuracy)).rounded())
    }
}

/// Combo, multiplier, energy and score book-keeping.
public struct ScoreKeeper: Sendable {
    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var multiplier = 1
    public private(set) var multiplierProgress = 0
    public private(set) var energy = 0.5
    public private(set) var goodCuts = 0
    public private(set) var badCuts = 0
    public private(set) var misses = 0
    public private(set) var bombHits = 0
    /// Max score achievable over the notes judged so far (for live accuracy %).
    public private(set) var maxScoreSoFar = 0
    public private(set) var notesJudged = 0
    public private(set) var cutScoreSum = 0
    public private(set) var preSum = 0
    public private(set) var postSum = 0
    public private(set) var accSum = 0
    public private(set) var scoredCuts = 0

    public init() {}

    /// Hits needed at the current multiplier to reach the next one.
    public var hitsForNextMultiplier: Int { multiplier >= 8 ? 0 : multiplier * 2 }
    public var multiplierFill: Double {
        multiplier >= 8 ? 1 : Double(multiplierProgress) / Double(hitsForNextMultiplier)
    }

    public var accuracyPercent: Double {
        maxScoreSoFar > 0 ? Double(score) / Double(maxScoreSoFar) : 1
    }

    /// Multiplier a perfect player would have on the n-th note (0-based).
    public static func perfectMultiplier(forNoteIndex n: Int) -> Int {
        if n < 2 { return 1 }
        if n < 6 { return 2 }
        if n < 14 { return 4 }
        return 8
    }

    public static func maxScore(noteCount: Int) -> Int {
        (0..<noteCount).reduce(0) { $0 + CutScore.max * perfectMultiplier(forNoteIndex: $1) }
    }

    private mutating func judge() {
        maxScoreSoFar += CutScore.max * Self.perfectMultiplier(forNoteIndex: notesJudged)
        notesJudged += 1
    }

    /// A correct cut happened; returns the multiplier the eventual points will use.
    public mutating func registerGoodCut() -> Int {
        let m = multiplier
        combo += 1
        maxCombo = max(maxCombo, combo)
        goodCuts += 1
        energy = min(1, energy + 0.012)
        if multiplier < 8 {
            multiplierProgress += 1
            if multiplierProgress >= hitsForNextMultiplier {
                multiplier *= 2
                multiplierProgress = 0
            }
        }
        judge()
        return m
    }

    public mutating func addCutScore(_ s: CutScore, multiplier m: Int) {
        score += s.total * m
        cutScoreSum += s.total
        preSum += s.preSwing
        postSum += s.postSwing
        accSum += s.accuracy
        scoredCuts += 1
    }

    private mutating func breakCombo(energyLoss: Double) {
        combo = 0
        multiplier = max(1, multiplier / 2)
        multiplierProgress = 0
        energy = max(0, energy - energyLoss)
    }

    public mutating func registerBadCut() {
        badCuts += 1
        breakCombo(energyLoss: 0.1)
        judge()
    }

    public mutating func registerMiss() {
        misses += 1
        breakCombo(energyLoss: 0.15)
        judge()
    }

    public mutating func registerBomb() {
        bombHits += 1
        breakCombo(energyLoss: 0.15)
    }
}

public struct GameResults: Codable, Equatable, Sendable {
    public var score: Int
    public var maxScore: Int
    public var rank: Rank
    public var percent: Double
    public var maxCombo: Int
    public var goodCuts: Int
    public var totalNotes: Int
    public var misses: Int
    public var badCuts: Int
    public var bombHits: Int
    public var averageCut: Double
    public var averagePre: Double
    public var averagePost: Double
    public var averageAccuracy: Double
    public var failed: Bool
    public var fullCombo: Bool { misses == 0 && badCuts == 0 && bombHits == 0 && !failed && goodCuts == totalNotes }
}
