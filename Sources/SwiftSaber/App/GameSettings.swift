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
            return "Two sabers: an AirPod in your main hand, your iPhone (running Saber Controller) in the other. The phone buzzes on every cut."
        case .airpods:
            return "One saber. AirPods stream motion from one bud at a time, so hold a single bud."
        case .phone:
            return "One saber driven by your iPhone running the Saber Controller app."
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
    /// Smooth AirPods motion using the sensor's own timestamps and gyroscope.
    var smoothAirPodMotion = true
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

extension GameSettings {
    /// Tolerates missing keys, so adding a setting doesn't reset everyone's saved settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init()
        let d = self
        inputMode = value(.inputMode, d.inputMode)
        primaryHand = value(.primaryHand, d.primaryHand)
        swapAirPods = value(.swapAirPods, d.swapAirPods)
        sensitivity = value(.sensitivity, d.sensitivity)
        audioOutput = value(.audioOutput, d.audioOutput)
        musicVolume = value(.musicVolume, d.musicVolume)
        sfxVolume = value(.sfxVolume, d.sfxVolume)
        audioOffsetMs = value(.audioOffsetMs, d.audioOffsetMs)
        airPodLatencyMs = value(.airPodLatencyMs, d.airPodLatencyMs)
        smoothAirPodMotion = value(.smoothAirPodMotion, d.smoothAirPodMotion)
        noFail = value(.noFail, d.noFail)
        lenientCuts = value(.lenientCuts, d.lenientCuts)
        autoRecenter = value(.autoRecenter, d.autoRecenter)
        keepAirPodsAwake = value(.keepAirPodsAwake, d.keepAirPodsAwake)
        bloom = value(.bloom, d.bloom)
        cameraShake = value(.cameraShake, d.cameraShake)
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
