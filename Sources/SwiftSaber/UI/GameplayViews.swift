import SwiftUI
import SaberCore

// MARK: - HUD

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let h = model.hud
        VStack {
            // Song progress
            VStack(spacing: 6) {
                Text("\(model.song.title.uppercased())  ·  \(model.playing.difficulty.name.uppercased())")
                    .font(Theme.heading(15)).tracking(2)
                    .foregroundStyle(.white.opacity(0.6))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(width: 340, height: 3)
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: 340 * h.progress, height: 3)
                        .shadow(color: .white, radius: 4)
                }
                Text("\(time(h.time)) / \(time(h.duration))").font(Theme.mono(11)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 24)

            if h.autoplay {
                Text("AUTOPLAY DEMO")
                    .font(Theme.heading(16)).tracking(3)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().stroke(Color.white.opacity(0.35)))
                    .padding(.top, 8)
            }

            if let w = h.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(14))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.top, 10)
            }

            Spacer()

            HStack(alignment: .bottom) {
                // Combo
                VStack(spacing: 2) {
                    Text("COMBO").font(Theme.heading(18)).tracking(3).foregroundStyle(.white.opacity(0.7))
                    NeonText(text: "\(h.combo)", color: h.combo > 0 ? Theme.blue : .gray, font: Theme.display(64))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.15), value: h.combo)
                }
                .frame(width: 220)
                .padding(.vertical, 14)
                .background(HUDFrame())

                Spacer()

                // Energy
                VStack(spacing: 8) {
                    if h.noFail {
                        Text("NO FAIL").font(Theme.mono(11)).foregroundStyle(.white.opacity(0.5))
                    }
                    EnergyBar(energy: h.energy)
                        .frame(width: 420, height: 14)
                }
                .padding(.bottom, 20)

                Spacer()

                // Score + multiplier
                HStack(spacing: 18) {
                    MultiplierRing(multiplier: h.multiplier, fill: h.multiplierFill)
                        .frame(width: 78, height: 78)
                    VStack(alignment: .leading, spacing: 0) {
                        NeonText(text: formatScore(h.score), color: Theme.red, font: Theme.display(48))
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.2), value: h.score)
                        HStack(spacing: 10) {
                            Text(h.rank).font(Theme.display(28)).foregroundStyle(.white)
                            Text(String(format: "%.1f%%", h.accuracy * 100)).font(Theme.mono(15)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .frame(width: 330, alignment: .leading)
                .padding(.vertical, 14).padding(.horizontal, 20)
                .background(HUDFrame())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
    }

    func time(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    func formatScore(_ s: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: s)) ?? "\(s)"
    }
}

struct HUDFrame: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

struct EnergyBar: View {
    var energy: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 4)
                    .fill(energy < 0.25 ? Theme.red : Color.white)
                    .frame(width: geo.size.width * energy)
                    .shadow(color: energy < 0.25 ? Theme.red : .white, radius: 6)
                    .animation(.easeOut(duration: 0.2), value: energy)
                RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

struct MultiplierRing: View {
    var multiplier: Int
    var fill: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.blue, radius: 6)
                .animation(.easeOut(duration: 0.15), value: fill)
            Text("×\(multiplier)")
                .font(Theme.display(30))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Pause

struct PauseView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            Panel(padding: 36) {
                VStack(spacing: 14) {
                    NeonText(text: "PAUSED", color: Theme.blue, font: Theme.display(56))
                        .padding(.bottom, 10)
                    Button("Resume") { model.resumeGame() }
                        .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 260))
                    Button("Recenter Sabers") { model.recenter() }
                        .buttonStyle(NeonButtonStyle(color: .white, width: 260))
                    Button("Restart") { model.restartLevel() }
                        .buttonStyle(NeonButtonStyle(color: Theme.red, width: 260))
                    Button("Quit to Menu") { model.quitToMenu() }
                        .buttonStyle(NeonButtonStyle(color: .gray, width: 260))
                    Text("Point both sabers at the screen centre, then press R to recenter.")
                        .font(Theme.body(12)).foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 6)
                }
            }
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var appeared = false

    var body: some View {
        if let r = model.results {
            Panel(padding: 40) {
                VStack(spacing: 22) {
                    Text(r.failed ? "LEVEL FAILED" : (r.fullCombo ? "FULL COMBO!" : "LEVEL CLEARED"))
                        .font(Theme.heading(26)).tracking(4)
                        .foregroundStyle(r.failed ? Theme.red : .white)
                    HStack(alignment: .center, spacing: 50) {
                        NeonText(text: r.rank.rawValue, color: rankColor(r), font: Theme.display(150))
                            .scaleEffect(appeared ? 1 : 2.2)
                            .opacity(appeared ? 1 : 0)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(r.score)")
                                .font(Theme.display(64)).foregroundStyle(.white)
                            if model.isNewRecord {
                                Text("NEW PERSONAL BEST").font(Theme.mono(13)).foregroundStyle(Theme.blue)
                                    .shadow(color: Theme.blue, radius: 6)
                            }
                            StatRow(label: "Accuracy", value: String(format: "%.1f%%", r.percent * 100))
                            StatRow(label: "Good cuts", value: "\(r.goodCuts) / \(r.totalNotes)")
                            StatRow(label: "Max combo", value: "\(r.maxCombo)")
                            StatRow(label: "Misses · bad cuts · bombs", value: "\(r.misses) · \(r.badCuts) · \(r.bombHits)")
                            StatRow(label: "Average cut", value: String(format: "%.0f", r.averageCut))
                            StatRow(label: "Swing · follow-through · aim",
                                    value: String(format: "%.0f · %.0f · %.0f", r.averagePre, r.averagePost, r.averageAccuracy))
                        }
                        .frame(width: 380)
                    }
                    HStack(spacing: 16) {
                        Button("Menu") { model.quitToMenu() }
                            .buttonStyle(NeonButtonStyle(color: .gray, width: 180))
                        Button("Play Again") { model.restartLevel() }
                            .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 220))
                        Button("Change Level") { model.goToLevelSelect() }
                            .buttonStyle(NeonButtonStyle(color: Theme.red, width: 200))
                    }
                }
            }
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.2)) { appeared = true }
            }
        }
    }

    func rankColor(_ r: GameResults) -> Color {
        switch r.rank {
        case .ss, .s: return Theme.blue
        case .a, .b: return .white
        default: return Theme.red
        }
    }
}
