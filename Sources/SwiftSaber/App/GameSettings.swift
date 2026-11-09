import Foundation
import SaberCore

enum InputMode: String, Codable, CaseIterable, Identifiable {
    /// Uses whatever is connected: the first two motion devices become the sabers.
    case automatic
    case airpodAndPhone
    case twoPhones
    case phone
    case airpods
    case controllers
    case airpodAndMouse
    case mouse

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .airpodAndPhone: return "AirPod + iPhone / iPad"
        case .twoPhones: return "Two iPhones / iPads"
        case .phone: return "iPhone / iPad only"
        case .airpods: return "AirPod only"
        case .controllers: return "Game controllers"
        case .airpodAndMouse: return "AirPod + Mouse"
        case .mouse: return "Mouse / Trackpad"
        }
    }
    var detail: String {
        switch self {
        case .automatic:
            return "Uses whatever you connect: AirPods, iPhones and iPads running Swift Saber, or motion game controllers. Two devices give you two sabers. Nothing connected? The mouse works."
        case .airpodAndPhone:
            return "Two sabers: an AirPod in your main hand, an iPhone or iPad (running Swift Saber) in the other. iPhones buzz on every cut."
        case .twoPhones:
            return "Two sabers from two iPhones or iPads running Swift Saber, say yours and a family member's. Same Wi-Fi as this Mac."
        case .phone:
            return "One saber driven by an iPhone or iPad running the Swift Saber app."
        case .airpods:
            return "One saber. AirPods stream motion from one bud at a time, so hold a single bud."
        case .controllers:
            return "One or two game controllers with motion sensors, paired with this Mac: DualSense, DualShock 4 or Joy-Con. A Joy-Con pair goes L in the left hand, R in the right."
        case .airpodAndMouse:
            return "An AirPod drives your main hand, the mouse or trackpad drives the other saber."
        case .mouse:
            return "Aim and swing with the pointer. Great for testing without any devices."
        }
    }
    var usesAirPods: Bool { [.automatic, .airpods, .airpodAndPhone, .airpodAndMouse].contains(self) }
    var usesPhone: Bool { [.automatic, .phone, .airpodAndPhone, .twoPhones].contains(self) }
    var usesControllers: Bool { self == .automatic || self == .controllers }
    var usesMouse: Bool { self == .mouse || self == .airpodAndMouse }
    var usesMotionDevices: Bool { usesAirPods || usesPhone || usesControllers }

    /// Whether `device` can be a saber in this mode.
    func allows(_ device: SaberDevice) -> Bool {
        switch device {
        case .airPod, .airPodCase: return usesAirPods
        case .iOS1, .iOS2: return usesPhone
        case .controller1, .controller2: return usesControllers
        case .mouse: return self == .automatic || usesMouse
        }
    }
}

/// How the AirPod saber is held.
enum AirPodGrip: String, Codable, CaseIterable, Identifiable {
    /// One bud in the fist, read through Core Motion's headphone motion.
    case bud
    /// Both buds in the closed charging case, which becomes the hilt (AirPods Pro 2 / 3).
    case closedCase

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bud: return "AirPod in hand"
        case .closedCase: return "Closed case"
        }
    }
    var detail: String {
        switch self {
        case .bud:
            return "Hold one bud in your fist. Works with any AirPods that support spatial audio."
        case .closedCase:
            return "Keep both buds in the closed charging case and hold the case like a hilt. AirPods Pro 2 or 3; no ear detection to switch off."
        }
    }
}

struct GameSettings: Codable, Equatable {
    var inputMode: InputMode = .automatic
    /// The main hand: it holds the first device (the AirPod, or the only device); the second
    /// device takes the other hand. "Swap hands" flips it.
    var primaryHand: Hand = .right
    /// Swap which bud drives which saber in two-saber mode.
    var swapAirPods = false
    /// Whether the AirPod saber is a bud in the hand or the closed case.
    var airPodGrip: AirPodGrip = .bud
    /// For AirPods whose accelerometer reports gravity the other way round: flips the case saber end for end.
    var invertCaseGravity = false
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
    /// The environment levels are played in.
    var stage: StageKind = .prismHall
    /// When false the arena's own colours are used; when true `customColors` replaces them.
    var overrideColors = false
    var customColors: SaberColorScheme = .classic

    /// The colours actually used in game.
    var effectiveColors: SaberColorScheme { overrideColors ? customColors : stage.defaultColors }

    static let storageKey = "SwiftSaber.settings.v1"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case inputMode, primaryHand, swapAirPods, airPodGrip, invertCaseGravity, sensitivity, audioOutput, musicVolume, sfxVolume
        case audioOffsetMs, airPodLatencyMs, noFail, lenientCuts, autoRecenter, keepAirPodsAwake
        case bloom, cameraShake, stage, overrideColors, customColors
    }

    /// Every key is optional so settings saved by older versions keep loading (missing or
    /// unknown values fall back to their defaults instead of discarding everything).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { target = v }
        }
        read(.inputMode, &inputMode)
        read(.primaryHand, &primaryHand)
        read(.swapAirPods, &swapAirPods)
        read(.airPodGrip, &airPodGrip)
        read(.invertCaseGravity, &invertCaseGravity)
        read(.sensitivity, &sensitivity)
        read(.audioOutput, &audioOutput)
        read(.musicVolume, &musicVolume)
        read(.sfxVolume, &sfxVolume)
        read(.audioOffsetMs, &audioOffsetMs)
        read(.airPodLatencyMs, &airPodLatencyMs)
        read(.noFail, &noFail)
        read(.lenientCuts, &lenientCuts)
        read(.autoRecenter, &autoRecenter)
        read(.keepAirPodsAwake, &keepAirPodsAwake)
        read(.bloom, &bloom)
        read(.cameraShake, &cameraShake)
        read(.stage, &stage)
        read(.overrideColors, &overrideColors)
        read(.customColors, &customColors)
    }

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
