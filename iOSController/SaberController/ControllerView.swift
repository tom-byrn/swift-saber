import SwiftUI
import UIKit

enum Neon {
    static let red = Color(red: 1.0, green: 0.16, blue: 0.24)
    static let blue = Color(red: 0.18, green: 0.55, blue: 1.0)
    static let green = Color(red: 0.2, green: 0.9, blue: 0.5)
    static let orange = Color(red: 1.0, green: 0.6, blue: 0.2)
}

/// The same type as the Mac game (Sources/SwiftSaber/UI/Theme.swift): Avenir Next Condensed
/// for titles and buttons, rounded system text for body copy, monospaced for small labels.
/// Avenir Next Condensed isn't always installed on iOS (it can be an on-demand download);
/// without it the closest built-in face, SF Pro Condensed, stands in at the same weights.
enum Theme {
    static let hasAvenirCondensed = UIFont(name: "AvenirNextCondensed-HeavyItalic", size: 12) != nil
        && UIFont(name: "AvenirNextCondensed-DemiBold", size: 12) != nil

    static func display(_ size: CGFloat) -> Font {
        hasAvenirCondensed
            ? .custom("AvenirNextCondensed-HeavyItalic", size: size)
            : .system(size: size, weight: .heavy, design: .default).width(.condensed).italic()
    }
    static func heading(_ size: CGFloat) -> Font {
        hasAvenirCondensed
            ? .custom("AvenirNextCondensed-DemiBold", size: size)
            : .system(size: size, weight: .semibold, design: .default).width(.condensed)
    }
    static func body(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

/// Text with a neon glow, as on the Mac.
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

struct ControllerView: View {
    @EnvironmentObject var model: ControllerModel
    @State private var flash = false

    /// The colour of the saber this phone drives (blue when it is only a remote).
    private var accent: Color {
        switch model.hand {
        case 0: return Neon.red
        case 1: return Neon.blue
        default: return model.remote != nil ? Neon.blue : Color.white.opacity(0.6)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Saber-coloured glow that flashes on every cut.
            RadialGradient(colors: [accent.opacity(flash ? 0.65 : 0.24), .clear],
                           center: .center, startRadius: 10, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.18), value: flash)

            if case .connected = model.link, let state = model.remote {
                RemoteRoot(state: state, accent: accent)
                    .transition(.opacity)
            } else {
                ConnectionView(accent: accent)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .fontDesign(.rounded)
        .animation(.easeInOut(duration: 0.2), value: model.remote?.screen)
        .onChange(of: model.lastHit) { _, _ in
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { flash = false }
        }
    }
}

// MARK: - Not connected (or a Mac without remote control)

struct ConnectionView: View {
    @EnvironmentObject var model: ControllerModel
    var accent: Color
    @State private var pulse = false

    private var handText: String {
        switch model.hand {
        case 0: return "LEFT SABER"
        case 1: return "RIGHT SABER"
        default: return "NOT ASSIGNED"
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Logo(size: 52)

            statusCard

            Spacer(minLength: 8)

            SaberHilt(color: accent, pulse: pulse)
            Text(handText)
                .font(Theme.heading(26)).tracking(2)
                .foregroundStyle(accent)

            Spacer(minLength: 8)

            if case .connected = model.link {
                // A Mac without remote control: the original two buttons still work.
                HStack(spacing: 14) {
                    TileButton(title: "RECENTER", icon: "scope", color: accent) { model.tap(.recenter) }
                    TileButton(title: "PAUSE", icon: "pause.fill", color: accent) { model.tap(.pause) }
                }
            }
            Text("Grip the phone like a sword hilt — any orientation works. Once connected, every menu of the game appears here.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 8)
        }
        .padding(24)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.link {
            case .searching:
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Looking for Swift Saber on your Mac…").foregroundStyle(.white)
                }
                Text("Open the game on your Mac and make sure both devices are on the same Wi-Fi.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            case .connecting(let name):
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Connecting to \(name)…").foregroundStyle(.white)
                }
            case .connected(let name):
                Label("Connected to \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label(model.calibrated ? "Calibrated" : "Not calibrated yet — run Set Up Sabers on the Mac",
                      systemImage: model.calibrated ? "scope" : "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(model.calibrated ? Color.white.opacity(0.8) : Color.orange)
            }
            if model.macs.count > 1 {
                Menu("Switch Mac") {
                    ForEach(model.macs) { mac in
                        Button(mac.id) { model.connect(to: mac) }
                    }
                }
                .font(.footnote)
            }
            if !model.motionAvailable {
                Label("This device has no motion sensors.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15)))
    }
}

// MARK: - Shared pieces

/// The Mac's "SWIFT SABER" title: staggered neon words with a blade slashing through.
struct Logo: View {
    var size: CGFloat
    @State private var pulse = false

    init(size: CGFloat) { self.size = size }

    var body: some View {
        VStack(spacing: -size * 0.18) {
            NeonText(text: "SWIFT", color: Neon.red, font: Theme.display(size))
            NeonText(text: "SABER", color: Neon.blue, font: Theme.display(size))
                .offset(x: size * 0.35)
        }
        .offset(x: -size * 0.17)
        .overlay(
            Capsule()
                .fill(LinearGradient(colors: [.clear, .white, Neon.blue, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: size * 4.2, height: 3)
                .shadow(color: Neon.blue, radius: 10)
                .rotationEffect(.degrees(-12))
                .opacity(pulse ? 0.95 : 0.5)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct SaberHilt: View {
    var color: Color
    var pulse: Bool
    var width: CGFloat = 220
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white, color], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 10)
            .shadow(color: color, radius: pulse ? 22 : 10)
    }
}

struct TileButton: View {
    var title: String
    var icon: String
    var color: Color
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 28, weight: .bold))
                Text(title).font(Theme.heading(19)).tracking(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 20).fill(color.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.8), lineWidth: 2))
        }
    }
}
