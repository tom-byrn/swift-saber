import SwiftUI
import UIKit

/// The phone as a remote: one screen per game screen, each with the same actions as the Mac.
struct RemoteRoot: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState
    var accent: Color

    var body: some View {
        VStack(spacing: 0) {
            RemoteHeader(state: state, accent: accent)
                .padding(.horizontal, 20)
                .padding(.top, 6)
            Group {
                switch state.screen {
                case .loading: LoadingScreen(state: state)
                case .menu: MenuScreen(state: state)
                case .levelSelect: LevelSelectScreen(state: state)
                case .calibration: CalibrationScreen(state: state)
                case .settings: SettingsScreen(state: state)
                case .countdown: CountdownScreen(state: state, accent: accent)
                case .playing: PlayingScreen(state: state, accent: accent)
                case .paused: PausedScreen(state: state)
                case .results: ResultsScreen(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Header

struct RemoteHeader: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState
    var accent: Color

    private var macName: String {
        if case .connected(let name) = model.link { return name }
        return "Mac"
    }

    private var role: (String, Color) {
        if !state.phoneIsSaber { return ("REMOTE", Color.white.opacity(0.7)) }
        switch model.hand {
        case 0: return ("LEFT SABER", Neon.red)
        case 1: return ("RIGHT SABER", Neon.blue)
        default: return (model.calibrated ? "SABER" : "NOT CALIBRATED", model.calibrated ? Color.white : Neon.orange)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 8, height: 8).shadow(color: .green, radius: 4)
            Text(macName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer()
            Text(role.0)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(role.1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().stroke(role.1.opacity(0.6), lineWidth: 1))
        }
        .frame(height: 32)
    }
}

// MARK: - Building blocks

struct NeonButton: View {
    var title: String
    var icon: String? = nil
    var color: Color
    var prominent = false
    var height: CGFloat = 58
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 18, weight: .bold)) }
                Text(title).font(.system(size: 18, weight: .heavy, design: .rounded)).tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(prominent ? 0.55 : 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.9), lineWidth: prominent ? 2.5 : 1.5))
            .shadow(color: prominent ? color.opacity(0.7) : .clear, radius: 12)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ScreenTitle: View {
    var text: String
    var color: Color
    var back: (() -> Void)?

    var body: some View {
        ZStack {
            Text(text)
                .font(.system(size: 26, weight: .black, design: .rounded)).italic()
                .foregroundStyle(.white)
                .shadow(color: color, radius: 10)
            if let back {
                HStack {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .accessibilityLabel("Back")
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.13)))
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.5))
    }
}

/// A slider that sends its value while dragging (throttled) and once more on release.
struct RemoteSlider: View {
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var onChange: (Double) -> Void
    @State private var local: Double?
    @State private var lastSent = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(local ?? value))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: Binding(get: { local ?? value }, set: { v in
                local = v
                if Date().timeIntervalSince(lastSent) > 0.1 {
                    lastSent = Date()
                    onChange(v)
                }
            }), in: range) { editing in
                if !editing {
                    if let v = local { onChange(v) }
                    local = nil
                }
            }
        }
    }
}

private func formatScore(_ s: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = " "
    return f.string(from: NSNumber(value: s)) ?? "\(s)"
}

// MARK: - Loading

struct LoadingScreen: View {
    var state: RemoteState
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Logo(size: 56)
            ProgressView(value: state.loadingProgress)
                .tint(Neon.blue)
                .frame(width: 240)
            Text("Composing \u{201C}\(state.songTitle)\u{201D}…")
                .font(.footnote).foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Main menu

struct MenuScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState
    @State private var confirmQuit = false

    private var readyText: String {
        switch state.sabersReady {
        case 0: return "No sabers ready yet — set them up first"
        case 1: return "One saber ready"
        default: return "Two sabers ready"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 4)
            Logo(size: 54)
            Text(readyText)
                .font(.subheadline)
                .foregroundStyle(state.sabersReady == 0 ? Neon.orange : Color.white.opacity(0.6))
                .padding(.bottom, 10)
            Spacer(minLength: 4)

            NeonButton(title: "PLAY", icon: "play.fill", color: Neon.blue, prominent: true, height: 72) {
                model.send(.openLevelSelect)
            }
            NeonButton(title: state.anyCalibrated ? "RECALIBRATE SABERS" : "SET UP SABERS", icon: "scope", color: Neon.red) {
                model.send(.openCalibration)
            }
            HStack(spacing: 12) {
                NeonButton(title: "SETTINGS", icon: "gearshape.fill", color: .white) { model.send(.openSettings) }
                NeonButton(title: "RECENTER", icon: "dot.viewfinder", color: .white) { model.send(.recenter) }
            }
            Button("Quit Game") { confirmQuit = true }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 6)
                .confirmationDialog("Quit Swift Saber on your Mac?", isPresented: $confirmQuit, titleVisibility: .visible) {
                    Button("Quit Game", role: .destructive) { model.send(.quitGame) }
                }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - Level select

struct LevelSelectScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState

    private func difficultyColor(_ i: Int) -> Color {
        [Neon.green, Color(red: 0.3, green: 0.75, blue: 1.0), Neon.orange, Neon.red][min(max(i, 0), 3)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(text: "SELECT LEVEL", color: Neon.blue) { model.send(.back) }
                .padding(.horizontal, 20)
            ScrollView {
                VStack(spacing: 16) {
                    Card {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [Neon.red, Color(red: 0.4, green: 0.1, blue: 0.6), Neon.blue],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 64, height: 64)
                                .overlay(Image(systemName: "music.note").font(.system(size: 26, weight: .bold)))
                                .shadow(color: Neon.blue.opacity(0.6), radius: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.songTitle).font(.system(size: 26, weight: .black, design: .rounded))
                                Text(state.songInfo).font(.footnote).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }

                    Card {
                        SectionLabel("Difficulty")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(Array(state.difficulties.enumerated()), id: \.offset) { i, name in
                                let selected = state.difficulty == i
                                Button {
                                    model.send(.selectDifficulty(i))
                                } label: {
                                    Text(name)
                                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                                        .frame(maxWidth: .infinity).frame(height: 48)
                                        .foregroundStyle(.white)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(difficultyColor(i).opacity(selected ? 0.5 : 0.08)))
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(selected ? difficultyColor(i) : Color.white.opacity(0.2), lineWidth: selected ? 2.5 : 1))
                                        .shadow(color: selected ? difficultyColor(i).opacity(0.7) : .clear, radius: 8)
                                }
                                .buttonStyle(PressScale())
                            }
                        }

                        SectionLabel("Sabers")
                        HStack(spacing: 10) {
                            modeButton("Two Sabers", mode: 0, enabled: state.twoSabersAvailable)
                            modeButton("One Saber", mode: 1, enabled: true)
                        }
                        if state.sabersReady < 2 {
                            Text(state.sabersReady == 0
                                 ? "No saber input yet — set up your sabers or switch to mouse input in Settings."
                                 : "Only one saber has input, so you'll play the One Saber map.")
                                .font(.footnote).foregroundStyle(Neon.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Toggle("No Fail", isOn: Binding(get: { state.settings.noFail },
                                                        set: { model.send(.setFlag(.noFail, $0)) }))
                            .tint(Neon.blue)
                    }

                    Card {
                        HStack {
                            Text(state.mapStats).font(.footnote).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                        }
                        HStack {
                            Text("Best").foregroundStyle(.white.opacity(0.55))
                            Spacer()
                            Text(state.best ?? "Not played yet")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(state.best == nil ? Color.white.opacity(0.5) : Color.white)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            HStack(spacing: 12) {
                NeonButton(title: "DEMO", icon: "eye.fill", color: .white) { model.send(.watchDemo) }
                    .frame(width: 130)
                NeonButton(title: "START", icon: "play.fill", color: Neon.blue, prominent: true, height: 64) {
                    model.send(.start)
                }
                .disabled(state.sabersReady == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func modeButton(_ title: String, mode: Int, enabled: Bool) -> some View {
        let selected = state.mode == mode
        return Button {
            model.send(.selectMode(mode))
        } label: {
            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity).frame(height: 46)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 12).fill(Neon.red.opacity(selected ? 0.45 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Neon.red : Color.white.opacity(0.2), lineWidth: selected ? 2.5 : 1))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
    }
}

// MARK: - Calibration

struct CalibrationScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState
    private var cal: RemoteState.Calibration { state.calibration }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(text: "SABER SETUP", color: Neon.red) { model.send(.back) }
                .padding(.horizontal, 20)
            switch cal.phase {
            case .detecting: detecting
            case .calibrating: calibrating
            case .done: done
            }
        }
    }

    private var detecting: some View {
        VStack(spacing: 14) {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        SectionLabel("Motion streams")
                        if cal.streams.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().tint(.white)
                                Text("Waiting for motion data…").foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        ForEach(cal.streams) { s in
                            HStack(spacing: 12) {
                                Image(systemName: s.name == "iPhone" ? "iphone" : "airpodpro")
                                    .font(.system(size: 22))
                                    .foregroundStyle(s.live ? Color.green : Color.gray)
                                    .frame(width: 30)
                                Text(s.name)
                                Spacer()
                                Text(s.live ? "Streaming" : "No data")
                                    .font(.footnote)
                                    .foregroundStyle(s.live ? Color.green : Color.gray)
                            }
                        }
                        Text(cal.detail)
                            .font(.footnote).foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                        if let failure = cal.failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Neon.orange)
                        }
                    }
                    Card {
                        SectionLabel("How it works")
                        Text("Hold your sabers and stand facing the screen. You'll point at the screen, then at the ceiling, then at the screen again — holding still until each ring fills.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            VStack(spacing: 10) {
                NeonButton(title: "START CALIBRATION", icon: "scope", color: Neon.blue, prominent: true, height: 64) {
                    model.send(.beginCalibration)
                }
                .disabled(!cal.canStart)
                Button("Use mouse / trackpad instead") { model.send(.useMouseInstead) }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private var calibrating: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(cal.title)
                .font(.system(size: 32, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            Text(cal.detail)
                .font(.body).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 28) {
                ForEach(cal.streams) { s in
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: s.done ? 1 : s.progress)
                                .stroke(s.name.hasPrefix("Left") ? Neon.red : Neon.blue,
                                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.1), value: s.progress)
                            Image(systemName: s.done ? "checkmark" : "hand.point.up.fill")
                                .font(.system(size: 24, weight: .bold))
                        }
                        .frame(width: 84, height: 84)
                        Text(s.name).font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(.top, 8)
            Spacer()
            NeonButton(title: "RESTART", icon: "arrow.counterclockwise", color: .gray) { model.send(.restartCalibration) }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Neon.blue)
                .shadow(color: Neon.blue, radius: 12)
            Text(cal.title).font(.system(size: 32, weight: .black, design: .rounded))
            Text(cal.detail)
                .font(.body).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Spacer()
            NeonButton(title: "PLAY NOW", icon: "play.fill", color: Neon.red, prominent: true, height: 64) {
                model.send(.calibrationPlayNow)
            }
            HStack(spacing: 12) {
                NeonButton(title: "AGAIN", icon: "arrow.counterclockwise", color: .gray) { model.send(.restartCalibration) }
                NeonButton(title: "DONE", icon: "checkmark", color: Neon.blue) { model.send(.finishCalibration) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState
    private var g: RemoteState.Settings { state.settings }

    private func flag(_ f: RemoteSettingFlag, _ get: @escaping (RemoteState.Settings) -> Bool) -> Binding<Bool> {
        Binding(get: { get(g) }, set: { model.send(.setFlag(f, $0), haptic: false) })
    }

    private func slider(_ title: String, _ key: RemoteSettingValue, _ value: Double, _ range: ClosedRange<Double>,
                        _ format: @escaping (Double) -> String) -> some View {
        RemoteSlider(title: title, value: value, range: range, format: format) { model.send(.setValue(key, $0), haptic: false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(text: "SETTINGS", color: .white) { model.send(.back) }
                .padding(.horizontal, 20)
            ScrollView {
                VStack(spacing: 16) {
                    Card {
                        SectionLabel("Controls")
                        HStack {
                            Text("Input")
                            Spacer()
                            Menu {
                                Picker("Input", selection: Binding(get: { g.inputMode },
                                                                   set: { model.send(.setInputMode($0)) })) {
                                    ForEach(g.inputModes) { Text($0.title).tag($0.id) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(g.inputModes.first { $0.id == g.inputMode }?.title ?? g.inputMode)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                                .foregroundStyle(Neon.blue)
                            }
                        }
                        Text(g.inputDetail).font(.footnote).foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AirPod hand")
                            Picker("AirPod hand", selection: Binding(get: { g.primaryHand },
                                                                     set: { model.send(.setPrimaryHand($0)) })) {
                                Text("Left").tag(0)
                                Text("Right").tag(1)
                            }
                            .pickerStyle(.segmented)
                        }
                        slider("Saber sensitivity", .sensitivity, g.sensitivity, 0.6...2.0) { String(format: "%.2f×", $0) }
                        slider("AirPods motion delay", .airPodLatencyMs, g.airPodLatencyMs, 0...150) { "\(Int($0)) ms" }
                        Toggle("Lenient cut angles", isOn: flag(.lenientCuts) { $0.lenientCuts })
                        Toggle("Auto-recenter when a song starts", isOn: flag(.autoRecenter) { $0.autoRecenter })
                        Toggle("Keep AirPods awake", isOn: flag(.keepAirPodsAwake) { $0.keepAirPodsAwake })
                    }

                    Card {
                        SectionLabel("Audio")
                        HStack {
                            Text("Play game audio on")
                            Spacer()
                            Menu {
                                Picker("Output", selection: Binding(get: { g.audioOutput },
                                                                    set: { model.send(.setAudioOutput($0)) })) {
                                    ForEach(g.audioOutputs) { Text($0.title).tag($0.id) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(g.audioOutputs.first { $0.id == g.audioOutput }?.title ?? "Custom")
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                                .foregroundStyle(Neon.blue)
                            }
                        }
                        slider("Music volume", .musicVolume, g.musicVolume, 0...1) { "\(Int(($0 * 100).rounded()))%" }
                        slider("Effects volume", .sfxVolume, g.sfxVolume, 0...1) { "\(Int(($0 * 100).rounded()))%" }
                        slider("Audio offset", .audioOffsetMs, g.audioOffsetMs, -200...300) { "\(Int($0)) ms" }
                    }

                    Card {
                        SectionLabel("Visuals")
                        Toggle("Bloom & glow", isOn: flag(.bloom) { $0.bloom })
                        Toggle("Camera shake", isOn: flag(.cameraShake) { $0.cameraShake })
                        Toggle("No Fail", isOn: flag(.noFail) { $0.noFail })
                    }
                }
                .tint(Neon.blue)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Countdown

struct CountdownScreen: View {
    var state: RemoteState
    var accent: Color
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(state.countdownMessage.uppercased())
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
            Text("\(state.countdown)")
                .font(.system(size: 160, weight: .black, design: .rounded)).italic()
                .foregroundStyle(.white)
                .shadow(color: state.countdown % 2 == 0 ? Neon.red : Neon.blue, radius: 24)
                .contentTransition(.numericText())
                .animation(.snappy, value: state.countdown)
            Text("Point at the screen")
                .font(.footnote).foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Playing (hold to pause)

struct PlayingScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState
    var accent: Color
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            // Song progress + score, glanceable between songs sections.
            VStack(spacing: 8) {
                ProgressView(value: state.progress).tint(.white)
                HStack {
                    Text(state.timeText).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if state.demo {
                        Text("AUTOPLAY DEMO").font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel("Combo")
                        Text("\(state.combo)").font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(state.combo > 0 ? Neon.blue : Color.gray)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        SectionLabel("Score")
                        Text(formatScore(state.score)).font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(Neon.red)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)

            Spacer()
            SaberHilt(color: accent, pulse: pulse, width: 180)
            Spacer()

            HoldToPauseButton(color: accent, frozenProgress: model.previewHoldProgress) {
                model.confirmHaptic()
                model.send(.pause, haptic: false)
            }
            Text("Swing freely — only a long press pauses the game.")
                .font(.footnote).foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// A big round button that only fires after being held down, so a swing or a brushed
/// thumb can never pause the song by accident.
struct HoldToPauseButton: View {
    var color: Color
    var duration: Double = 0.8
    /// Preview only: show the ring frozen part-way.
    var frozenProgress: Double? = nil
    var action: () -> Void

    @State private var holding = false
    @State private var progress: CGFloat = 0
    private let tick = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        let shownProgress = frozenProgress.map { CGFloat($0) } ?? progress
        let active = holding || frozenProgress != nil
        ZStack {
            Circle().fill(color.opacity(active ? 0.32 : 0.14))
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 12)
            Circle()
                .trim(from: 0, to: shownProgress)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color, radius: 12)
            VStack(spacing: 10) {
                Image(systemName: "pause.fill").font(.system(size: 54, weight: .black))
                Text(active ? "KEEP HOLDING" : "HOLD TO PAUSE")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .tracking(1)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 220, height: 220)
        .scaleEffect(active ? 0.95 : 1)
        .animation(.easeOut(duration: 0.15), value: active)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 80) {
            action()
        } onPressingChanged: { pressing in
            holding = pressing
            if pressing {
                tick.impactOccurred(intensity: 0.6)
                progress = 0
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .accessibilityLabel("Pause")
        .accessibilityHint("Press and hold to pause the game")
        .accessibilityAction { action() }
    }
}

// MARK: - Paused

struct PausedScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("PAUSED")
                .font(.system(size: 52, weight: .black, design: .rounded)).italic()
                .foregroundStyle(.white)
                .shadow(color: Neon.blue, radius: 16)
            Text(state.timeText).font(.system(size: 14, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 16)
            Spacer()
            NeonButton(title: "RESUME", icon: "play.fill", color: Neon.blue, prominent: true, height: 76) {
                model.send(.resume)
            }
            NeonButton(title: "RECENTER SABERS", icon: "dot.viewfinder", color: .white) { model.send(.recenter) }
            HStack(spacing: 12) {
                NeonButton(title: "RESTART", icon: "arrow.counterclockwise", color: Neon.red) { model.send(.restart) }
                NeonButton(title: "QUIT", icon: "house.fill", color: .gray) { model.send(.quitToMenu) }
            }
            Text("Point at the screen centre before tapping Recenter.")
                .font(.footnote).foregroundStyle(.white.opacity(0.5))
                .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - Results

struct ResultsScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState

    var body: some View {
        VStack(spacing: 14) {
            if let r = state.results {
                Spacer(minLength: 4)
                Text(r.headline)
                    .font(.system(size: 18, weight: .heavy, design: .rounded)).tracking(3)
                    .foregroundStyle(r.failed ? Neon.red : Color.white)
                Text(r.rank)
                    .font(.system(size: 120, weight: .black, design: .rounded)).italic()
                    .foregroundStyle(.white)
                    .shadow(color: r.failed ? Neon.red : Neon.blue, radius: 22)
                Text(formatScore(r.score))
                    .font(.system(size: 40, weight: .black, design: .rounded))
                if r.newRecord {
                    Text("NEW PERSONAL BEST")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Neon.blue)
                        .shadow(color: Neon.blue, radius: 6)
                }
                Card {
                    statRow("Accuracy", String(format: "%.1f%%", r.accuracy * 100))
                    statRow("Good cuts", "\(r.goodCuts) / \(r.totalNotes)")
                    statRow("Max combo", "\(r.maxCombo)")
                    statRow("Misses", "\(r.misses)")
                }
                .padding(.top, 6)
                Spacer(minLength: 4)
            } else {
                Spacer()
            }
            NeonButton(title: "PLAY AGAIN", icon: "arrow.counterclockwise", color: Neon.blue, prominent: true, height: 68) {
                model.send(.restart)
            }
            HStack(spacing: 12) {
                NeonButton(title: "LEVELS", icon: "list.bullet", color: Neon.red) { model.send(.openLevelSelect) }
                NeonButton(title: "MENU", icon: "house.fill", color: .gray) { model.send(.back) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
        .font(.subheadline)
    }
}
