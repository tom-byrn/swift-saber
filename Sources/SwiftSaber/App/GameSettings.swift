import Foundation
import SaberCore

enum InputMode: String, Codable, CaseIterable, Identifiable {
    case airpods
    case mouse
    case airpodAndMouse

    var id: String { rawValue }
    var title: String {
        switch self {
        case .airpods: return "AirPods"
        case .mouse: return "Mouse / Trackpad"
        case .airpodAndMouse: return "AirPod + Mouse"
        }
    }
    var detail: String {
        switch self {
        case .airpods: return "One AirPod in each fist. Falls back to one saber if only one bud streams motion."
        case .mouse: return "Aim and swing with the pointer. Great for testing without AirPods."
        case .airpodAndMouse: return "One AirPod controls your main hand, the mouse controls the other saber."
        }
    }
    var usesAirPods: Bool { self != .mouse }
}

struct GameSettings: Codable, Equatable {
    var inputMode: InputMode = .airpods
    /// Hand that holds the AirPod (or mouse) when only one saber is available.
    var primaryHand: Hand = .right
    /// Swap which bud drives which saber in two-saber mode.
    var swapAirPods = false
    /// Multiplies AirPod rotation (1 = natural).
    var sensitivity: Double = 1.15
    /// "auto" (Mac speakers), "system" (system default) or a CoreAudio device UID.
    var audioOutput: String = "auto"
    var musicVolume: Double = 0.85
    var sfxVolume: Double = 0.7
    /// Audio/visual sync offset in milliseconds (positive = blocks arrive later).
    var audioOffsetMs: Double = 0
    /// How late AirPods motion arrives, in milliseconds.
    var airPodLatencyMs: Double = 45
    var noFail = false
    var lenientCuts = true
    var autoRecenter = true
    var keepAirPodsAwake = true
    var bloom = true
    var cameraShake = true

    static let storageKey = "SwiftSaber.settings.v1"

    static func load() -> GameSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(GameSettings.self, from: data) else { return GameSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

enum BestScores {
    static func key(_ d: Difficulty, _ m: PlayMode) -> String { "SwiftSaber.best.\(d.rawValue).\(m.rawValue)" }

    static func get(_ d: Difficulty, _ m: PlayMode) -> GameResults? {
        guard let data = UserDefaults.standard.data(forKey: key(d, m)) else { return nil }
        return try? JSONDecoder().decode(GameResults.self, from: data)
    }

    /// Stores the result if it beats the previous best. Returns true for a new record.
    @discardableResult
    static func submit(_ r: GameResults, _ d: Difficulty, _ m: PlayMode) -> Bool {
        if r.failed { return false }
        if let old = get(d, m), old.score >= r.score { return false }
        if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: key(d, m)) }
        return true
    }
}
