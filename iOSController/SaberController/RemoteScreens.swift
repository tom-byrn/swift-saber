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
                case .customize: CustomizeScreen(state: state)
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
                .font(Theme.body(13))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer()
            Text(role.0)
                .font(Theme.mono(11))
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
                Text(title).font(Theme.heading(prominent ? 24 : 20)).tracking(1)
                    .lineLimit(1).minimumScaleFactor(0.7)
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
            NeonText(text: text, color: color, font: Theme.display(36))
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
            .font(Theme.mono(11))
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
                    .font(Theme.mono(12))
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
                .font(Theme.body(13)).foregroundStyle(.white.opacity(0.6))
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
                .font(Theme.body(15))
                .foregroundStyle(state.sabersReady == 0 ? Neon.orange : Color.white.opacity(0.6))
                .padding(.bottom, 10)
            Spacer(minLength: 4)

            NeonButton(title: "PLAY", icon: "play.fill", color: Neon.blue, prominent: true, height: 72) {
                model.send(.openLevelSelect)
            }
            NeonButton(title: state.anyCalibrated ? "RECALIBRATE SABERS" : "SET UP SABERS", icon: "scope", color: Neon.red) {
                model.send(.openCalibration)
            }
            NeonButton(title: "ARENA & COLORS", icon: "paintpalette.fill", color: Neon.purple) {
                model.send(.openCustomize)
            }
            HStack(spacing: 12) {
                NeonButton(title: "SETTINGS", icon: "gearshape.fill", color: .white) { model.send(.openSettings) }
                NeonButton(title: "RECENTER", icon: "dot.viewfinder", color: .white) { model.send(.recenter) }
            }
            Button("Quit Game") { confirmQuit = true }
                .font(Theme.body(15))
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
                                Text(state.songTitle).font(Theme.display(34))
                                Text(state.songInfo).font(Theme.body(13)).foregroundStyle(.white.opacity(0.6))
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
                                        .font(Theme.heading(20)).tracking(1).textCase(.uppercase)
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
                                .font(Theme.body(13)).foregroundStyle(Neon.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let look = state.look {
                            SectionLabel("Arena")
                            HStack {
                                Menu {
                                    Picker("Arena", selection: Binding(get: { look.arena },
                                                                       set: { model.send(.setArena($0)) })) {
                                        ForEach(look.arenas) { Text($0.title).tag($0.id) }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(look.arenas.first { $0.id == look.arena }?.title ?? look.arena)
                                            .font(Theme.heading(19)).tracking(1).textCase(.uppercase)
                                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(height: 42)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Neon.purple.opacity(0.18)))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Neon.purple.opacity(0.8), lineWidth: 1.5))
                                }
                                Spacer()
                                Button("Colors…") { model.send(.openCustomize) }
                                    .font(Theme.body(15))
                                    .foregroundStyle(Neon.blue)
                            }
                        }

                        Toggle("No Fail", isOn: Binding(get: { state.settings.noFail },
                                                        set: { model.send(.setFlag(.noFail, $0)) }))
                            .tint(Neon.blue)
                    }

                    Card {
                        HStack {
                            Text(state.mapStats).font(Theme.body(13)).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                        }
                        HStack {
                            Text("Best").foregroundStyle(.white.opacity(0.55))
                            Spacer()
                            Text(state.best ?? "Not played yet")
                                .font(Theme.mono(14))
                                .foregroundStyle(state.best == nil ? Color.white.opacity(0.5) : Color.white)
                        }
                        .font(Theme.body(15))
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
                .font(Theme.heading(19)).tracking(1).textCase(.uppercase)
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

/// The guided closed-case connection, mirrored from the Mac.
struct CaseSetupCard: View {
    @EnvironmentObject var model: ControllerModel
    var setup: RemoteState.Calibration.AirPodsCase

    var body: some View {
        Card {
            HStack {
                SectionLabel("AirPods case")
                Spacer()
                Text(setup.connected ? "Connected" : "Step \(min(setup.step, setup.stepCount)) of \(setup.stepCount)")
                    .font(Theme.body(12))
                    .foregroundStyle(setup.connected ? Color.green : .white.opacity(0.5))
            }
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 5)
                    if let progress = setup.progress {
                        Circle().trim(from: 0, to: progress)
                            .stroke(Neon.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.15), value: progress)
                    }
                    Image(systemName: setup.connected ? "checkmark" : "airpodspro.chargingcase.wireless.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(setup.connected ? Color.green : .white)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(setup.title).font(Theme.body(17)).foregroundStyle(.white)
                    Text(setup.detail).font(Theme.body(13)).foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = setup.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(13)).foregroundStyle(Neon.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NeonButton(title: setup.actionTitle, icon: icon, color: setup.action == "connect" || setup.action == "lidClosed" ? Neon.blue : .white,
                       prominent: setup.action == "connect" || setup.action == "lidClosed", height: 52) {
                switch setup.action {
                case "connect": model.send(.connectCase)
                case "lidClosed": model.send(.caseLidClosed)
                default: model.send(.disconnectCase)
                }
            }
        }
    }

    private var icon: String {
        switch setup.action {
        case "connect": return "antenna.radiowaves.left.and.right"
        case "lidClosed": return "checkmark"
        default: return "xmark"
        }
    }
}

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
                    if let grip = cal.airPodGrip, let grips = cal.airPodGrips {
                        Picker("Hold the AirPods as", selection: Binding(get: { grip }, set: { model.send(.setAirPodGrip($0)) })) {
                            ForEach(grips) { Text($0.title).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let airPodsCase = cal.airPodsCase { CaseSetupCard(setup: airPodsCase) }
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
                                Image(systemName: s.name == "iPhone" ? "iphone" : (s.name == "AirPods Case" ? "airpodspro.chargingcase.wireless.fill" : "airpodpro"))
                                    .font(.system(size: 22))
                                    .foregroundStyle(s.live ? Color.green : Color.gray)
                                    .frame(width: 30)
                                Text(s.name)
                                Spacer()
                                Text(s.live ? "Streaming" : "No data")
                                    .font(Theme.body(13))
                                    .foregroundStyle(s.live ? Color.green : Color.gray)
                            }
                        }
                        Text(cal.detail)
                            .font(Theme.body(13)).foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                        if let failure = cal.failure {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.body(13)).foregroundStyle(Neon.orange)
                        }
                    }
                    Card {
                        SectionLabel("How it works")
                        Text("Hold your sabers and stand facing the screen. You'll point at the screen, then at the ceiling, then at the screen again — holding still until each ring fills.")
                            .font(Theme.body(13)).foregroundStyle(.white.opacity(0.7))
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
                    .font(Theme.body(15))
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
                .font(Theme.display(40))
                .multilineTextAlignment(.center)
            Text(cal.detail)
                .font(Theme.body(17)).foregroundStyle(.white.opacity(0.75))
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
                        Text(s.name).font(Theme.body(13)).foregroundStyle(.white.opacity(0.7))
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
            Text(cal.title).font(Theme.display(40))
            Text(cal.detail)
                .font(Theme.body(17)).foregroundStyle(.white.opacity(0.75))
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
                        Text(g.inputDetail).font(Theme.body(13)).foregroundStyle(.white.opacity(0.6))
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
                .font(Theme.heading(22))
                .tracking(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
            NeonText(text: "\(state.countdown)", color: state.countdown % 2 == 0 ? Neon.red : Neon.blue,
                     font: Theme.display(170))
                .contentTransition(.numericText())
                .animation(.snappy, value: state.countdown)
            Text("Point at the screen")
                .font(Theme.body(13)).foregroundStyle(.white.opacity(0.55))
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
                    Text(state.timeText).font(Theme.mono(11)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if state.demo {
                        Text("AUTOPLAY DEMO").font(Theme.heading(15)).tracking(2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("COMBO").font(Theme.heading(15)).tracking(3).foregroundStyle(.white.opacity(0.7))
                        NeonText(text: "\(state.combo)", color: state.combo > 0 ? Neon.blue : Color.gray,
                                 font: Theme.display(46))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("SCORE").font(Theme.heading(15)).tracking(3).foregroundStyle(.white.opacity(0.7))
                        NeonText(text: formatScore(state.score), color: Neon.red, font: Theme.display(46))
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
                .font(Theme.body(13)).foregroundStyle(.white.opacity(0.5))
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
                    .font(Theme.heading(19))
                    .tracking(1.5)
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
            NeonText(text: "PAUSED", color: Neon.blue, font: Theme.display(64))
            Text(state.timeText).font(Theme.mono(13)).foregroundStyle(.white.opacity(0.6))
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
                .font(Theme.body(13)).foregroundStyle(.white.opacity(0.5))
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
                    .font(Theme.heading(24)).tracking(4)
                    .foregroundStyle(r.failed ? Neon.red : Color.white)
                NeonText(text: r.rank, color: r.failed ? Neon.red : Neon.blue, font: Theme.display(150))
                Text(formatScore(r.score))
                    .font(Theme.display(56))
                if r.newRecord {
                    Text("NEW PERSONAL BEST")
                        .font(Theme.mono(13))
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
            Text(value).font(Theme.mono(14))
        }
        .font(Theme.body(15))
    }
}

// MARK: - Arena & colours

extension Color {
    /// "#RRGGBB" → Color (white if malformed).
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// The Mac's "Arena & Colors" screen: pick the arena and the saber / light colours.
struct CustomizeScreen: View {
    @EnvironmentObject var model: ControllerModel
    var state: RemoteState

    var body: some View {
        VStack(spacing: 0) {
            ScreenTitle(text: "ARENA & COLORS", color: Neon.blue) { model.send(.back) }
                .padding(.horizontal, 20)
            if let look = state.look {
                ScrollView {
                    VStack(spacing: 16) {
                        arenas(look)
                        colors(look)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                NeonButton(title: "PREVIEW LIGHTS", icon: "sparkles", color: .white) { model.send(.previewLights) }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else {
                Spacer()
            }
        }
    }

    private func arenas(_ look: RemoteState.Look) -> some View {
        Card {
            SectionLabel("Arena")
            ForEach(look.arenas) { arena in
                let selected = arena.id == look.arena
                Button {
                    model.send(.setArena(arena.id))
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(LinearGradient(colors: arena.swatch.map { Color(hex: $0).opacity(0.6) },
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: arena.symbol).font(.system(size: 20, weight: .semibold))
                        }
                        .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(arena.title.uppercased()).font(Theme.heading(19)).tracking(1)
                            Text(arena.tagline).font(Theme.body(12)).foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(selected ? 0.12 : 0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? Neon.blue : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(PressScale())
            }
        }
    }

    private func colors(_ look: RemoteState.Look) -> some View {
        Card {
            Toggle(isOn: Binding(get: { look.customColors }, set: { model.send(.setCustomColors($0)) })) {
                SectionLabel("Custom colors")
            }
            .tint(Neon.blue)
            Text(look.customColors
                 ? "Your colours are used in every arena."
                 : "Using the arena's own colours. Pick a template or change a colour to customise.")
                .font(Theme.body(12)).foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            SectionLabel("Templates")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(look.presets) { preset in
                    PresetTile(preset: preset, selected: preset.id == look.presetID) {
                        model.send(.applyColorPreset(preset.id))
                    }
                }
            }

            SabersPreview(colors: look.colors)
                .padding(.vertical, 4)

            ForEach(Array(look.colors.enumerated()), id: \.offset) { i, hex in
                HStack(spacing: 12) {
                    Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                        .shadow(color: Color(hex: hex), radius: 5)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    Text(i < RemoteState.Look.slotNames.count ? RemoteState.Look.slotNames[i] : "Colour \(i + 1)")
                        .font(Theme.body(15))
                    Spacer()
                    Text(hex).font(Theme.mono(12)).foregroundStyle(.white.opacity(0.6))
                    ColorPicker("", selection: Binding(get: { Color(hex: hex) },
                                                       set: { model.sendThrottled(.setColor(slot: i, hex: $0.hexString)) }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }

            HStack(spacing: 8) {
                smallButton("Swap L / R") { model.send(.swapColors) }
                smallButton("Lights = Sabers") { model.send(.lightsMatchSabers) }
                smallButton("Reset") { model.send(.resetColors) }
            }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(13))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 38)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.2)))
        }
        .buttonStyle(PressScale())
    }
}

private struct PresetTile: View {
    var preset: RemoteState.Look.Preset
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    ForEach(Array(preset.colors.prefix(2).enumerated()), id: \.offset) { _, hex in
                        Rectangle().fill(Color(hex: hex))
                    }
                }
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 0) {
                    ForEach(Array(preset.colors.dropFirst(2).enumerated()), id: \.offset) { _, hex in
                        Rectangle().fill(Color(hex: hex))
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())
                .padding(.horizontal, 8)
                Text(preset.name)
                    .font(Theme.body(12))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.14 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(PressScale())
    }
}

/// Two glowing blades in the chosen saber colours.
private struct SabersPreview: View {
    var colors: [String]
    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(colors.prefix(2).enumerated()), id: \.offset) { _, hex in
                let c = Color(hex: hex)
                Capsule()
                    .fill(LinearGradient(colors: [.white, c], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                    .shadow(color: c, radius: 6)
                    .shadow(color: c, radius: 12)
            }
        }
    }
}
