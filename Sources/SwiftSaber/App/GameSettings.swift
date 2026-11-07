import Foundation
import SaberCore

enum InputMode: String, Codable, CaseIterable, Identifiable {
    case airpodAndPhone
    case airpods
    case phone
    case airpodAndMouse
    case mouse

    var id: String { rawValue }
    var title: String {
        switch self {
        case .airpodAndPhone: return "AirPod + iPhone"
        case .airpods: return "AirPod only"
        case .phone: return "iPhone only"
        case .airpodAndMouse: return "AirPod + Mouse"
        case .mouse: return "Mouse / Trackpad"
        }
    }
    var detail: String {
        switch self {
        case .airpodAndPhone:
            return "Two sabers: an AirPod in your main hand, your iPhone (running Swift Saber) in the other. The phone buzzes on every cut."
        case .airpods:
            return "One saber. AirPods stream motion from one bud at a time, so hold a single bud."
        case .phone:
            return "One saber driven by your iPhone running the Swift Saber app."
        case .airpodAndMouse:
            return "An AirPod drives your main hand, the mouse or trackpad drives the other saber."
        case .mouse:
            return "Aim and swing with the pointer. Great for testing without any devices."
        }
    }
    var usesAirPods: Bool { self == .airpods || self == .airpodAndPhone || self == .airpodAndMouse }
    var usesPhone: Bool { self == .phone || self == .airpodAndPhone }
    var usesMotionDevices: Bool { usesAirPods || usesPhone }
}

struct GameSettings: Codable, Equatable {
    var inputMode: InputMode = .airpodAndPhone
    /// Hand that holds the AirPod (or the only device). The iPhone / mouse takes the other hand.
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
