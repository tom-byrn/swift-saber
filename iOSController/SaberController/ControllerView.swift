import SwiftUI

struct ControllerView: View {
    @EnvironmentObject var model: ControllerModel
    @State private var pulse = false
    @State private var flash = false

    private var saberColor: Color {
        switch model.hand {
        case 0: return Color(red: 1.0, green: 0.16, blue: 0.24)
        case 1: return Color(red: 0.18, green: 0.55, blue: 1.0)
        default: return Color.white.opacity(0.6)
        }
    }

    private var handText: String {
        switch model.hand {
        case 0: return "LEFT SABER"
        case 1: return "RIGHT SABER"
        default: return "NOT ASSIGNED"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Saber-coloured glow that flashes on every cut.
            RadialGradient(colors: [saberColor.opacity(flash ? 0.65 : 0.28), .clear],
                           center: .center, startRadius: 10, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.18), value: flash)

            VStack(spacing: 22) {
                VStack(spacing: -10) {
                    Text("SWIFT")
                        .font(.system(size: 52, weight: .black, design: .rounded)).italic()
                        .foregroundStyle(.white)
                        .shadow(color: Color(red: 1, green: 0.16, blue: 0.24), radius: 12)
                    Text("SABER")
                        .font(.system(size: 52, weight: .black, design: .rounded)).italic()
                        .foregroundStyle(.white)
                        .shadow(color: Color(red: 0.18, green: 0.55, blue: 1), radius: 12)
                }
                Text("CONTROLLER").font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(6).foregroundStyle(.white.opacity(0.6))

                statusCard

                Spacer(minLength: 8)

                // Hilt-style indicator.
                Capsule()
                    .fill(LinearGradient(colors: [.white, saberColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 220, height: 10)
                    .shadow(color: saberColor, radius: pulse ? 22 : 10)
                Text(handText)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(saberColor)

                Spacer(minLength: 8)

                HStack(spacing: 14) {
                    bigButton("RECENTER", icon: "scope") { model.tap(.recenter) }
                    bigButton("PAUSE", icon: "pause.fill") { model.tap(.pause) }
                }
                Text("Grip the phone like a sword hilt — any orientation works. Calibrate from the Mac (Set Up Sabers). Tap RECENTER while pointing at the screen if your saber drifts.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 8)
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: model.lastHit) { _, _ in
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { flash = false }
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
                Text("Open the game on your Mac and make sure both devices are on the same Wi-Fi. Input mode must include the iPhone (Settings › Input).")
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

    private func bigButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 28, weight: .bold))
                Text(title).font(.system(size: 15, weight: .heavy, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 20).fill(saberColor.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(saberColor.opacity(0.8), lineWidth: 2))
        }
    }
}
