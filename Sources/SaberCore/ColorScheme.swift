import Foundation

/// An sRGB colour with components in 0...1.
public struct NeonColor: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = clamp(r, 0, 1)
        self.g = clamp(g, 0, 1)
        self.b = clamp(b, 0, 1)
    }

    /// Creates a colour from 0...255 components.
    public init(r255: Int, g255: Int, b255: Int) {
        self.init(Double(r255) / 255, Double(g255) / 255, Double(b255) / 255)
    }

    /// Parses "#RRGGBB", "RRGGBB", "#RGB" or "RGB" (case-insensitive).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r255: Int((v >> 16) & 0xFF), g255: Int((v >> 8) & 0xFF), b255: Int(v & 0xFF))
    }

    public var r255: Int { Int((r * 255).rounded()) }
    public var g255: Int { Int((g * 255).rounded()) }
    public var b255: Int { Int((b * 255).rounded()) }

    /// "#RRGGBB".
    public var hex: String { String(format: "#%02X%02X%02X", UInt32(r255), UInt32(g255), UInt32(b255)) }

    public static let white = NeonColor(1, 1, 1)
    public static let black = NeonColor(0, 0, 0)

    /// Linear blend towards `other`.
    public func mixed(with other: NeonColor, _ t: Double) -> NeonColor {
        NeonColor(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// Multiplies every component (clamped).
    public func scaled(_ k: Double) -> NeonColor { NeonColor(r * k, g * k, b * k) }

    /// Perceived brightness (Rec. 709 luma), 0...1.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// A darker, more saturated variant used for block bodies: the strongest channel keeps
    /// most of its value while weaker channels sink, so blocks read as deep coloured glass.
    public var deepened: NeonColor {
        NeonColor(pow(r, 1.3) * 0.66, pow(g, 1.3) * 0.66, pow(b, 1.3) * 0.66)
    }

    /// The same colour lifted to full brightness (keeps hue and saturation). Black stays black.
    public var maximized: NeonColor {
        let m = max(r, max(g, b))
        guard m > 0.0001 else { return self }
        return NeonColor(r / m, g / m, b / m)
    }
}

/// The colours a level is played with. Left/right lights replace the red/blue light events.
public struct SaberColorScheme: Codable, Equatable, Hashable, Sendable {
    public var leftSaber: NeonColor
    public var rightSaber: NeonColor
    public var leftLights: NeonColor
    public var rightLights: NeonColor

    public init(leftSaber: NeonColor, rightSaber: NeonColor, leftLights: NeonColor, rightLights: NeonColor) {
        self.leftSaber = leftSaber
        self.rightSaber = rightSaber
        self.leftLights = leftLights
        self.rightLights = rightLights
    }

    /// Saber and lights share the same two colours.
    public init(left: NeonColor, right: NeonColor) {
        self.init(leftSaber: left, rightSaber: right, leftLights: left, rightLights: right)
    }

    public func saber(_ hand: Hand) -> NeonColor { hand == .left ? leftSaber : rightSaber }

    public enum Slot: Int, CaseIterable, Identifiable, Sendable {
        case leftSaber, rightSaber, leftLights, rightLights
        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .leftSaber: return "Left saber"
            case .rightSaber: return "Right saber"
            case .leftLights: return "Left lights"
            case .rightLights: return "Right lights"
            }
        }
    }

    public subscript(slot: Slot) -> NeonColor {
        get {
            switch slot {
            case .leftSaber: return leftSaber
            case .rightSaber: return rightSaber
            case .leftLights: return leftLights
            case .rightLights: return rightLights
            }
        }
        set {
            switch slot {
            case .leftSaber: leftSaber = newValue
            case .rightSaber: rightSaber = newValue
            case .leftLights: leftLights = newValue
            case .rightLights: rightLights = newValue
            }
        }
    }

    /// Swaps the left and right colours.
    public var swapped: SaberColorScheme {
        SaberColorScheme(leftSaber: rightSaber, rightSaber: leftSaber, leftLights: rightLights, rightLights: leftLights)
    }

    /// The game's original red / blue look.
    public static let classic = SaberColorScheme(
        left: NeonColor(1.0, 0.11, 0.2), right: NeonColor(0.1, 0.48, 1.0))
}

/// A named, ready-made colour scheme.
public struct ColorPreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var scheme: SaberColorScheme

    public init(id: String, name: String, scheme: SaberColorScheme) {
        self.id = id; self.name = name; self.scheme = scheme
    }

    private static func hex(_ s: String) -> NeonColor { NeonColor(hex: s) ?? .white }

    public static let all: [ColorPreset] = [
        ColorPreset(id: "classic", name: "Classic", scheme: .classic),
        ColorPreset(id: "sunset", name: "Sunset", scheme: SaberColorScheme(
            leftSaber: hex("#FF7A1A"), rightSaber: hex("#B44DFF"), leftLights: hex("#FF4E2B"), rightLights: hex("#8A3DFF"))),
        ColorPreset(id: "synthwave", name: "Synthwave", scheme: SaberColorScheme(
            leftSaber: hex("#FF2BD6"), rightSaber: hex("#1FF2FF"), leftLights: hex("#FF2B9E"), rightLights: hex("#2BB8FF"))),
        ColorPreset(id: "toxic", name: "Toxic", scheme: SaberColorScheme(
            leftSaber: hex("#7CFF2B"), rightSaber: hex("#A22BFF"), leftLights: hex("#45FF3A"), rightLights: hex("#C23AFF"))),
        ColorPreset(id: "fireice", name: "Fire & Ice", scheme: SaberColorScheme(
            leftSaber: hex("#FF3A12"), rightSaber: hex("#9FEAFF"), leftLights: hex("#FF6A00"), rightLights: hex("#5FD4FF"))),
        ColorPreset(id: "goldteal", name: "Gold & Teal", scheme: SaberColorScheme(
            leftSaber: hex("#FFC21A"), rightSaber: hex("#00E0B8"), leftLights: hex("#FFAA00"), rightLights: hex("#00C9A7"))),
        ColorPreset(id: "bubblegum", name: "Bubblegum", scheme: SaberColorScheme(
            leftSaber: hex("#FF6FB5"), rightSaber: hex("#6FE3FF"), leftLights: hex("#FF8FC8"), rightLights: hex("#8FB4FF"))),
        ColorPreset(id: "emerald", name: "Emerald", scheme: SaberColorScheme(
            leftSaber: hex("#00FF85"), rightSaber: hex("#2B6BFF"), leftLights: hex("#00E676"), rightLights: hex("#2979FF"))),
        ColorPreset(id: "inferno", name: "Inferno", scheme: SaberColorScheme(
            leftSaber: hex("#FF1A1A"), rightSaber: hex("#FFB01A"), leftLights: hex("#E01010"), rightLights: hex("#FF8C00"))),
        ColorPreset(id: "deepsea", name: "Deep Sea", scheme: SaberColorScheme(
            leftSaber: hex("#00F0FF"), rightSaber: hex("#3A4DFF"), leftLights: hex("#00D0E0"), rightLights: hex("#2A3AFF"))),
        ColorPreset(id: "royal", name: "Royal", scheme: SaberColorScheme(
            leftSaber: hex("#FFD700"), rightSaber: hex("#7A2BFF"), leftLights: hex("#FFC000"), rightLights: hex("#5A1FE0"))),
        ColorPreset(id: "mono", name: "Monochrome", scheme: SaberColorScheme(
            leftSaber: hex("#FFFFFF"), rightSaber: hex("#7F8C99"), leftLights: hex("#F2F5FF"), rightLights: hex("#6C7A8C"))),
    ]

    public static func preset(id: String) -> ColorPreset? { all.first { $0.id == id } }

    /// The preset whose colours match `scheme` exactly, if any.
    public static func matching(_ scheme: SaberColorScheme) -> ColorPreset? { all.first { $0.scheme == scheme } }
}
