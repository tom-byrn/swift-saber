import SwiftUI
import SceneKit
import SaberCore

/// Hosts the persistent SceneKit view.
struct SceneHost: NSViewRepresentable {
    let view: SCNView
    func makeNSView(context: Context) -> SCNView { view }
    func updateNSView(_ nsView: SCNView, context: Context) {}
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            SceneHost(view: model.renderer.view)
                .ignoresSafeArea()

            Group {
                switch model.screen {
                case .loading: LoadingView()
                case .menu: MainMenuView()
                case .levelSelect: LevelSelectView()
                case .calibration: CalibrationView(calibration: model.calibration)
                case .settings: SettingsView()
                case .customize: CustomizeView()
                case .countdown: CountdownView()
                case .playing: HUDView().allowsHitTesting(false)
                case .paused: ZStack { HUDView().allowsHitTesting(false); PauseView() }
                case .results: ResultsView()
                }
            }
            .transition(.opacity)

            if let toast = model.toast {
                VStack {
                    Text(toast)
                        .font(Theme.body(15))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .overlay(Capsule().stroke(Theme.blue.opacity(0.6)))
                        .padding(.top, 28)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.25), value: model.screen)
    }
}

// MARK: - Loading

struct LoadingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 40) {
                TitleLogo(size: 92)
                VStack(spacing: 12) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(width: 360, height: 6)
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.red, Theme.blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 360 * model.loadingProgress, height: 6)
                            .shadow(color: Theme.blue, radius: 6)
                    }
                    Text("Composing \u{201C}\(model.song.title)\u{201D}…")
                        .font(Theme.body(13))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

// MARK: - Main menu

struct MainMenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            VStack(alignment: .leading, spacing: 30) {
                TitleLogo(size: 104)
                Text("Slice to the beat with AirPods as your sabers.")
                    .font(Theme.body(17))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.leading, 6)
            }
            Panel {
                VStack(spacing: 14) {
                    Button("Play") { model.goToLevelSelect() }
                        .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 280))
                    Button(model.calibratedStreams.isEmpty ? "Set Up Sabers" : "Recalibrate Sabers") { model.openCalibration() }
                        .buttonStyle(NeonButtonStyle(color: Theme.red, width: 280))
                    Button("Arena & Colors") { model.screen = .customize }
                        .buttonStyle(NeonButtonStyle(color: Color(red: 0.75, green: 0.4, blue: 1.0), width: 280))
                    Button("Settings") { model.screen = .settings }
                        .buttonStyle(NeonButtonStyle(color: .white, width: 280))
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(NeonButtonStyle(color: .gray, width: 280))
                    Divider().overlay(Theme.stroke).padding(.vertical, 6)
                    InputStatusView(motion: model.motion, phone: model.phone)
                }
            }
            .frame(width: 360)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear, .black.opacity(0.4)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        )
        .overlay(alignment: .bottom) {
            HStack(spacing: 22) {
                KeyHint(key: "↩", label: "Play")
                KeyHint(key: "R", label: "Recenter")
                KeyHint(key: "F", label: "Full screen")
                KeyHint(key: "esc", label: "Pause / Back")
                Label("Every menu also works from the Swift Saber app on your iPhone", systemImage: "iphone")
                    .font(Theme.body(12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.bottom, 22)
        }
    }
}

struct InputStatusView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var motion: HeadphoneMotionService
    @ObservedObject var phone: PhoneControllerServer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INPUT").font(Theme.mono(11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(model.settings.inputMode.title).font(Theme.body(13)).foregroundStyle(.white.opacity(0.85))
            }
            if model.settings.inputMode.usesAirPods {
                let caseGrip = model.settings.airPodGrip == .closedCase
                switch caseGrip ? .waitingForAirPods : motion.status {
                case .denied:
                    Label("Motion access denied — enable it in System Settings › Privacy & Security", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.body(12)).foregroundStyle(.orange)
                case .unavailable:
                    Label("Headphone motion isn't available on this Mac", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.body(12)).foregroundStyle(.orange)
                default:
                    if !model.streamInfos.contains(where: { $0.id.isAirPod && ($0.id == .airPodCase) == caseGrip }) {
                        Label(caseGrip ? "AirPods case not connected — open Set Up Sabers" : "Waiting for AirPods motion…",
                              systemImage: caseGrip ? "airpodspro.chargingcase.wireless" : "airpodspro")
                            .font(Theme.body(12)).foregroundStyle(.white.opacity(0.6))
                    }
                    ForEach(model.streamInfos.filter { $0.id.isAirPod && ($0.id == .airPodCase) == caseGrip }) { s in
                        HStack(spacing: 8) {
                            Circle().fill(s.isLive ? Color.green : Color.gray).frame(width: 7, height: 7)
                                .shadow(color: s.isLive ? .green : .clear, radius: 4)
                            Text(s.id.label).font(Theme.body(12)).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text(s.isCalibrated ? "calibrated" : "not calibrated")
                                .font(Theme.body(11))
                                .foregroundStyle(s.isCalibrated ? Theme.blue : Color.orange)
                        }
                    }
                }
            }
            if model.settings.inputMode.usesPhone {
                HStack(spacing: 8) {
                    let connected = phone.isConnected
                    Circle().fill(connected ? Color.green : Color.gray).frame(width: 7, height: 7)
                    Text(connected ? "iPhone controller" : "iPhone: open Swift Saber").font(Theme.body(12)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(model.phoneCalibrated ? "calibrated" : "not calibrated")
                        .font(Theme.body(11))
                        .foregroundStyle(model.phoneCalibrated ? Theme.blue : Color.orange)
                }
            }
            let hands = model.availableHands
            Text(hands.count >= 2 ? "Two sabers ready" : (hands.count == 1 ? "One saber ready (\(hands[0].name.lowercased()) hand)" : "No sabers ready yet"))
                .font(Theme.body(12))
                .foregroundStyle(hands.isEmpty ? Color.orange : Color.white.opacity(0.6))
        }
    }
}

// MARK: - Countdown

struct CountdownView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Text(model.countdownMessage.uppercased())
                .font(Theme.heading(26)).tracking(3)
                .foregroundStyle(.white.opacity(0.85))
            NeonText(text: "\(model.countdownValue)", color: model.countdownValue % 2 == 0 ? Theme.red : Theme.blue, font: Theme.display(170))
                .id(model.countdownValue)
                .transition(.scale(scale: 1.6).combined(with: .opacity))
            Text("\(model.song.title) · \(model.playing.difficulty.name) · \(model.playing.mode.name)")
                .font(Theme.body(14)).foregroundStyle(.white.opacity(0.55))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: model.countdownValue)
        .allowsHitTesting(false)
    }
}
