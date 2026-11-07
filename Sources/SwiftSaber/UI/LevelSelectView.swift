import SwiftUI
import SaberCore

struct LevelSelectView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 26) {
            HStack {
                Button("‹ Back") { model.screen = .menu }
                    .buttonStyle(NeonButtonStyle(color: .gray))
                Spacer()
                NeonText(text: "SELECT LEVEL", color: Theme.blue, font: Theme.display(44))
                Spacer()
                Color.clear.frame(width: 110, height: 1)
            }

            Panel {
                HStack(alignment: .top, spacing: 36) {
                    SongArt()
                        .frame(width: 220, height: 220)

                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.song.title)
                                .font(Theme.display(46))
                                .foregroundStyle(.white)
                            Text("\(model.song.artist)  ·  \(Int(model.song.bpm)) BPM  ·  \(formatTime(model.song.duration))")
                                .font(Theme.body(15))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Text("DIFFICULTY").font(Theme.mono(11)).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 10) {
                            ForEach(Difficulty.allCases) { d in
                                DifficultyChip(difficulty: d, selected: model.selectedDifficulty == d) {
                                    model.selectedDifficulty = d
                                    model.audio.play(.click, volume: 0.5)
                                }
                            }
                        }

                        Text("SABERS").font(Theme.mono(11)).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 10) {
                            ForEach(PlayMode.allCases) { m in
                                let disabled = m == .twoSabers && model.availableHands.count < 2
                                Button {
                                    model.selectedMode = m
                                    model.audio.play(.click, volume: 0.5)
                                } label: {
                                    Text(m.name)
                                }
                                .buttonStyle(NeonButtonStyle(color: model.selectedMode == m ? Theme.red : .gray, width: 180))
                                .disabled(disabled)
                            }
                        }
                        if model.availableHands.count < 2 {
                            Text(model.availableHands.isEmpty
                                 ? "No saber input yet — set up AirPods or switch to mouse input in Settings."
                                 : "Only one saber has input, so you'll play the One Saber map.")
                                .font(Theme.body(13))
                                .foregroundStyle(Color.orange.opacity(0.9))
                        }

                        HStack(spacing: 12) {
                            Text("ARENA").font(Theme.mono(11)).foregroundStyle(.white.opacity(0.5))
                            Picker("Arena", selection: Binding(get: { model.settings.stage }, set: { model.settings.stage = $0 })) {
                                ForEach(StageKind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 170)
                            Button("Colors…") { model.screen = .customize }
                                .buttonStyle(.link)
                                .font(Theme.body(13))
                        }

                        Toggle(isOn: Binding(get: { model.settings.noFail }, set: { model.settings.noFail = $0 })) {
                            Text("No Fail").font(Theme.body(14)).foregroundStyle(.white.opacity(0.85))
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.blue)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        let map = model.beatmap(model.selectedDifficulty, model.availableHands.count < 2 ? .oneSaber : model.selectedMode)
                        StatRow(label: "Blocks", value: "\(map.notes.count)")
                        StatRow(label: "Bombs", value: "\(map.bombs.count)")
                        StatRow(label: "Blocks / sec", value: String(format: "%.1f", map.notesPerSecond))
                        StatRow(label: "Block speed", value: String(format: "%.1f m/s", map.noteSpeed))
                        Divider().overlay(Theme.stroke)
                        if let best = BestScores.get(model.selectedDifficulty, map.mode) {
                            StatRow(label: "Best", value: "\(best.score)")
                            StatRow(label: "Rank", value: best.rank.rawValue + (best.fullCombo ? " · FC" : ""))
                        } else {
                            Text("Not played yet").font(Theme.body(13)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: 190)
                }
            }

            HStack(spacing: 18) {
                Button("Watch Demo") { model.startDemo() }
                    .buttonStyle(NeonButtonStyle(color: .white, width: 200))
                Button("Start") { model.startLevel() }
                    .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 260))
                    .disabled(model.availableHands.isEmpty)
            }
        }
        .padding(50)
        .frame(maxWidth: 1100)
    }

    func formatTime(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct DifficultyChip: View {
    var difficulty: Difficulty
    var selected: Bool
    var action: () -> Void

    var color: Color {
        switch difficulty {
        case .easy: return Color(red: 0.2, green: 0.9, blue: 0.5)
        case .normal: return Color(red: 0.3, green: 0.75, blue: 1.0)
        case .hard: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .expert: return Theme.red
        }
    }

    var body: some View {
        Button(action: action) {
            Text(difficulty.name)
        }
        .buttonStyle(NeonButtonStyle(color: selected ? color : .gray.opacity(0.6), width: 112))
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var body: some View {
        HStack {
            Text(label).font(Theme.body(13)).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value).font(Theme.mono(14)).foregroundStyle(.white)
        }
    }
}

/// Cover art: the app's procedurally drawn artwork.
struct SongArt: View {
    private static let artwork = IconRenderer.image(size: 440)
    var body: some View {
        Image(nsImage: Self.artwork)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .shadow(color: Theme.blue.opacity(0.5), radius: 16)
    }
}
