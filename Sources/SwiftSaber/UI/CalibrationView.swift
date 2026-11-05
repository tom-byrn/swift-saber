import SwiftUI
import SaberCore

struct CalibrationView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var calibration: CalibrationModel

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button("‹ Back") { model.closeCalibration() }
                    .buttonStyle(NeonButtonStyle(color: .gray))
                Spacer()
                NeonText(text: "AIRPODS SETUP", color: Theme.red, font: Theme.display(44))
                Spacer()
                Color.clear.frame(width: 110, height: 1)
            }

            switch calibration.phase {
            case .detecting: detecting
            case .calibrating: calibrating
            case .done: done
            }
        }
        .padding(44)
        .frame(maxWidth: 1080)
    }

    // MARK: Detecting

    private var detecting: some View {
        HStack(alignment: .top, spacing: 26) {
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("BEFORE YOU START").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
                    ChecklistRow(n: 1, title: "Connect your AirPods to this Mac",
                                 detail: "AirPods Pro / Max / 3rd gen or later with spatial audio support.")
                    ChecklistRow(n: 2, title: "Turn off Automatic Ear Detection",
                                 detail: "System Settings › your AirPods › Automatic Ear Detection: Off. Otherwise motion stops when the buds leave your ears.")
                    ChecklistRow(n: 3, title: "Take the buds out and hold one in each fist",
                                 detail: "Grip them firmly, stems pointing in any direction — calibration works out the orientation.")
                    ChecklistRow(n: 4, title: "Stand facing the screen",
                                 detail: "Game audio plays through your Mac's speakers (change in Settings).")
                    if let failure = calibration.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.body(13)).foregroundStyle(.orange)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(width: 520)

            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Text("MOTION STREAMS").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
                    MotionStatusBanner(motion: model.motion)
                    if calibration.streams.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for AirPods motion data…").font(Theme.body(14)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    ForEach(calibration.streams) { s in
                        HStack {
                            Image(systemName: "airpodpro.\(s.id == .left ? "left" : "right")")
                                .font(.system(size: 22))
                                .foregroundStyle(s.live ? (s.id == .left ? Theme.red : Theme.blue) : Color.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.id.label).font(Theme.body(15)).foregroundStyle(.white)
                                Text(s.live ? "Streaming · \(Int(s.rate)) Hz" : "No data")
                                    .font(Theme.body(12))
                                    .foregroundStyle(s.live ? Color.green : Color.gray)
                            }
                            Spacer()
                        }
                    }
                    let live = calibration.streams.filter { $0.live }.count
                    Text(live >= 2 ? "Both buds are streaming — you'll get two sabers."
                         : live == 1 ? "One bud is streaming. AirPods often report motion from one bud at a time; you'll play with one saber (or add the mouse as a second saber in Settings)."
                         : "Move the AirPods around a little to wake them up.")
                        .font(Theme.body(13))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Start Calibration") { calibration.begin() }
                        .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 330))
                        .disabled(live == 0)
                        .padding(.top, 6)
                    Button("Use mouse / trackpad instead") {
                        model.settings.inputMode = .mouse
                        model.closeCalibration()
                    }
                    .buttonStyle(NeonButtonStyle(color: .gray, width: 330))
                }
            }
            .frame(width: 400)
        }
    }

    // MARK: Calibrating

    private var calibrating: some View {
        let active = calibration.streams.filter { $0.step != nil }
        let text = CalibrationModel.instruction(for: calibration.currentStep, count: active.count)
        return Panel(padding: 36) {
            VStack(spacing: 28) {
                PoseIllustration(step: calibration.currentStep)
                    .frame(width: 180, height: 150)
                VStack(spacing: 10) {
                    Text(text.title).font(Theme.display(42)).foregroundStyle(.white)
                    Text(text.detail)
                        .font(Theme.body(16))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                HStack(spacing: 40) {
                    ForEach(active) { s in
                        HoldRing(label: s.id.label, progress: s.progress,
                                 color: s.id == .left ? Theme.red : Theme.blue,
                                 done: stepIndex(s.step) > stepIndex(calibration.currentStep))
                    }
                }
                Button("Restart") { calibration.restart() }
                    .buttonStyle(NeonButtonStyle(color: .gray))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 760)
    }

    private func stepIndex(_ s: CalibrationProcess.Step?) -> Int {
        switch s {
        case .pointAtScreen: return 0
        case .pointUp: return 1
        case .confirmCenter: return 2
        case .done: return 3
        default: return 0
        }
    }

    // MARK: Done

    private var done: some View {
        Panel(padding: 36) {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.blue)
                    .shadow(color: Theme.blue, radius: 12)
                Text("You're calibrated").font(Theme.display(44)).foregroundStyle(.white)
                Text("Your sabers are live behind this panel — give them a swing. Point at the screen and press R any time to recenter if they drift.")
                    .font(Theme.body(16))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                HStack(spacing: 16) {
                    Button("Calibrate Again") { calibration.restart() }
                        .buttonStyle(NeonButtonStyle(color: .gray))
                    Button("Done") { model.closeCalibration() }
                        .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true))
                    Button("Play Now") {
                        model.calibration.deactivate()
                        model.goToLevelSelect()
                    }
                    .buttonStyle(NeonButtonStyle(color: Theme.red, prominent: true))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 700)
        .offset(y: 160)
    }
}

struct MotionStatusBanner: View {
    @ObservedObject var motion: HeadphoneMotionService
    var body: some View {
        switch motion.status {
        case .denied:
            Label("Motion access is denied. Enable Swift Saber in System Settings › Privacy & Security › Motion & Fitness, then relaunch.",
                  systemImage: "hand.raised.fill")
                .font(Theme.body(13)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable:
            Label("Headphone motion isn't available. It needs macOS 14+ and AirPods with spatial audio.", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body(13)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .connected:
            Label("AirPods connected", systemImage: "airpodspro").font(Theme.body(13)).foregroundStyle(.green)
        case .waitingForAirPods:
            EmptyView()
        }
    }
}

struct ChecklistRow: View {
    var n: Int
    var title: String
    var detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(Theme.heading(18))
                .frame(width: 30, height: 30)
                .background(Circle().stroke(Theme.blue.opacity(0.8), lineWidth: 1.5))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(15)).foregroundStyle(.white)
                Text(detail).font(Theme.body(12.5)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HoldRing: View {
    var label: String
    var progress: Double
    var color: Color
    var done: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: done ? 1 : progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color, radius: 8)
                    .animation(.linear(duration: 0.1), value: progress)
                Image(systemName: done ? "checkmark" : "hand.point.up.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white.opacity(done ? 1 : 0.7))
            }
            .frame(width: 90, height: 90)
            Text(label).font(Theme.body(13)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Simple pose diagram: a fist with a blade pointing at the screen or at the ceiling.
struct PoseIllustration: View {
    var step: CalibrationProcess.Step
    var body: some View {
        let up = step == .pointUp
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.35), lineWidth: 2)
                .frame(width: 70, height: 46)
                .offset(x: 50, y: -30)
            Text("SCREEN").font(Theme.mono(8)).foregroundStyle(.white.opacity(0.4)).offset(x: 50, y: -30)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.85))
                .offset(x: -40, y: 40)
            Capsule()
                .fill(LinearGradient(colors: [Theme.blue, .white], startPoint: .leading, endPoint: .trailing))
                .frame(width: 110, height: 6)
                .shadow(color: Theme.blue, radius: 8)
                .offset(x: 15)
                .rotationEffect(.degrees(up ? -90 : -15), anchor: .leading)
                .offset(x: -40, y: 30)
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: up)
        }
    }
}
