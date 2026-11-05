import SwiftUI
import SaberCore

enum Theme {
    static let red = Color(red: 1.0, green: 0.16, blue: 0.24)
    static let blue = Color(red: 0.18, green: 0.55, blue: 1.0)
    static let panel = Color.black.opacity(0.62)
    static let stroke = Color.white.opacity(0.14)

    static func saber(_ hand: Hand) -> Color { hand == .left ? red : blue }

    static func display(_ size: CGFloat) -> Font {
        .custom("AvenirNextCondensed-HeavyItalic", size: size)
    }
    static func heading(_ size: CGFloat) -> Font {
        .custom("AvenirNextCondensed-DemiBold", size: size)
    }
    static func body(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

/// Text with a neon glow.
struct NeonText: View {
    var text: String
    var color: Color
    var font: Font

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Color.white)
            .shadow(color: color, radius: 2)
            .shadow(color: color, radius: 8)
            .shadow(color: color.opacity(0.7), radius: 22)
    }
}

/// Dark glass panel with a subtle red-to-blue rim.
struct Panel<Content: View>: View {
    var padding: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.panel)
                    .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Theme.red.opacity(0.7), Color.white.opacity(0.08), Theme.blue.opacity(0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.6), radius: 30)
    }
}

struct NeonButtonStyle: ButtonStyle {
    var color: Color = Theme.blue
    var prominent = false
    var width: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        NeonButtonBody(configuration: configuration, color: color, prominent: prominent, width: width)
    }

    private struct NeonButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        let prominent: Bool
        let width: CGFloat?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(Theme.heading(prominent ? 24 : 19))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, prominent ? 14 : 10)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(prominent ? (hovering ? 0.55 : 0.4) : (hovering ? 0.28 : 0.12)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color.opacity(hovering ? 1 : 0.7), lineWidth: 1.5)
                )
                .shadow(color: color.opacity(hovering ? 0.9 : 0.4), radius: hovering ? 16 : 8)
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.03 : 1))
                .opacity(enabled ? 1 : 0.35)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

struct KeyHint: View {
    var key: String
    var label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(Theme.mono(11))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4)))
            Text(label).font(Theme.body(12))
        }
        .foregroundStyle(.white.opacity(0.65))
    }
}

/// Animated "SWIFT SABER" title.
struct TitleLogo: View {
    var size: CGFloat = 96
    @State private var pulse = false

    var body: some View {
        VStack(spacing: -size * 0.18) {
            NeonText(text: "SWIFT", color: Theme.red, font: Theme.display(size))
            NeonText(text: "SABER", color: Theme.blue, font: Theme.display(size))
                .offset(x: size * 0.35)
        }
        .overlay(
            // A blade slashing through the title.
            Capsule()
                .fill(LinearGradient(colors: [.clear, .white, Theme.blue, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: size * 4.2, height: 3)
                .shadow(color: Theme.blue, radius: 10)
                .rotationEffect(.degrees(-12))
                .opacity(pulse ? 0.95 : 0.5)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
