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
                NeonText(text: "SABER SETUP", color: Theme.red, font: Theme.display(44))
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
                    if mode.usesAirPods {
                        Picker("Hold the AirPods as", selection: Binding(get: { model.settings.airPodGrip },
                                                                        set: { model.settings.airPodGrip = $0 })) {
                            ForEach(AirPodGrip.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .font(Theme.body(13))
                    }
                    if usesCase {
                        CaseSetupPanel(session: model.airPodsCase, hand: model.settings.primaryHand.name.lowercased())
                        if mode.usesPhone { Divider().overlay(Color.white.opacity(0.15)) }
                    }
                    let steps = checklist
                    if !steps.isEmpty && !usesCase {
                        Text("BEFORE YOU START").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        ChecklistRow(n: i + 1, title: step.0, detail: step.1)
                    }
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
                    if mode.usesAirPods && !usesCase { MotionStatusBanner(motion: model.motion) }
                    if mode.usesPhone { PhoneStatusBanner(phone: model.phone) }
                    if calibration.streams.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(usesCase ? "Waiting for the AirPods case…" : "Waiting for AirPods motion data…")
                                .font(Theme.body(14)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    ForEach(calibration.streams) { s in
                        HStack {
                            Image(systemName: s.id.symbol)
                                .font(.system(size: 22))
                                .foregroundStyle(s.live ? Color.green : Color.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.id.label).font(Theme.body(15)).foregroundStyle(.white)
                                Text(s.live ? "Streaming · \(Int(s.rate)) Hz" : "No data")
                                    .font(Theme.body(12))
                                    .foregroundStyle(s.live ? Color.green : Color.gray)
                                if s.live, let r = s.reading {
                                    Text(String(format: "yaw %+.0f°  pitch %+.0f°  roll %+.0f°", r.yaw, r.pitch, r.roll))
                                        .font(Theme.mono(10.5))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .monospacedDigit()
                                }
                            }
                            Spacer()
                        }
                    }
                    let live = calibration.streams.filter { $0.live }.count
                    Text(calibration.streamHint(mode: mode, grip: model.settings.airPodGrip))
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

    private var mode: InputMode { model.settings.inputMode }
    private var usesCase: Bool { model.usesAirPodsCase }

    private var checklist: [(String, String)] {
        let pod = model.settings.primaryHand.name.lowercased()
        let other = model.settings.primaryHand.other.name.lowercased()
        var steps: [(String, String)] = []
        if usesCase {
            // The case panel covers the AirPods; only the phone's steps remain.
            if mode.usesPhone {
                steps.append(("Open Swift Saber on your iPhone",
                              "Same Wi-Fi network as this Mac. Hold it in your \(other) fist; any orientation works."))
            }
            return steps
        }
        if mode.usesAirPods {
            steps.append(("Connect your AirPods to this Mac",
                          "AirPods Pro / Max / 3rd gen or later with spatial audio support."))
            steps.append(("Turn off Automatic Ear Detection",
                          "System Settings › your AirPods › Automatic Ear Detection: Off. Otherwise motion stops when the buds leave your ears."))
        }
        if mode.usesPhone {
            steps.append(("Open Swift Saber on your iPhone",
                          "Same Wi-Fi network as this Mac. It finds the game automatically — allow Local Network access when asked."))
        }
        switch mode {
        case .airpodAndPhone:
            steps.append(("AirPod in your \(pod) fist, iPhone in your \(other)",
                          "Hold one bud only (AirPods stream from one bud at a time). Grip the phone like a hilt; any orientation works."))
        case .phone:
            steps.append(("Hold the iPhone in your \(pod) fist", "Grip it like a sword hilt — any orientation works."))
        default:
            steps.append(("Hold one AirPod in your \(pod) fist", "Grip it firmly, stem pointing any direction — calibration works out the orientation."))
        }
        steps.append(("Stand facing the screen", "Game audio plays through your Mac's speakers (change in Settings)."))
        return steps
    }

    // MARK: Calibrating

    private var calibrating: some View {
        let active = calibration.streams.filter { $0.step != nil }
        let text = CalibrationModel.instruction(for: calibration.currentStep, count: active.count,
                                                grip: model.settings.airPodGrip, awaitingNext: calibration.canAdvance)
        return Panel(padding: 32) {
            VStack(spacing: 18) {
                PoseIllustration(step: calibration.canAdvance ? nextStep(after: calibration.currentStep) : calibration.currentStep)
                    .frame(width: 180, height: 110)
                VStack(spacing: 10) {
                    Text(text.title).font(Theme.display(40)).foregroundStyle(.white)
                    Text(text.detail)
                        .font(Theme.body(16))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 24) {
                    ForEach(active) { s in
                        HStack(alignment: .center, spacing: 12) {
                            HoldRing(label: s.id.label, progress: s.progress,
                                     color: color(for: s.id),
                                     done: s.awaitingNext || CalibrationModel.stepIndex(s.step) > CalibrationModel.stepIndex(calibration.currentStep))
                            if let r = s.reading {
                                SensorReadout(reading: r, step: calibration.currentStep,
                                              awaiting: s.awaitingNext, color: color(for: s.id))
                            }
                        }
                    }
                }
                HStack(spacing: 16) {
                    Button("Restart") { calibration.restart() }
                        .buttonStyle(NeonButtonStyle(color: .gray))
                    Button("Next ›") { model.calibrationNext() }
                        .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 220))
                        .disabled(!calibration.canAdvance)
                }
                Text(calibration.canAdvance
                     ? "Press Next, Return or Space — or tap NEXT on the iPhone — when you're ready."
                     : "Hold still until the ring fills. You'll get a chance to move before the next step.")
                    .font(Theme.body(12.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 860)
    }

    private func color(for id: StreamID) -> Color {
        switch id {
        case .left: return Theme.red
        case .phone: return Color(red: 0.75, green: 0.55, blue: 1.0)
        default: return Theme.blue
        }
    }

    private func nextStep(after s: CalibrationProcess.Step) -> CalibrationProcess.Step {
        switch s {
        case .pointAtScreen: return .pointUp
        case .pointUp: return .confirmCenter
        default: return s
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

struct PhoneStatusBanner: View {
    @ObservedObject var phone: PhoneControllerServer
    var body: some View {
        switch phone.status {
        case .connected(let name):
            Label("\(name) connected", systemImage: "iphone.radiowaves.left.and.right").font(Theme.body(13)).foregroundStyle(.green)
        case .waiting:
            Label("Looking for Swift Saber on your iPhone…", systemImage: "iphone").font(Theme.body(13)).foregroundStyle(.white.opacity(0.7))
        case .failed(let msg):
            Label("Network error: \(msg)", systemImage: "exclamationmark.triangle.fill").font(Theme.body(13)).foregroundStyle(.orange)
        case .off:
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

/// Live numbers for one sensor while calibrating: raw attitude, gravity, distance from the
/// captured screen pose and how steady the hand is.
struct SensorReadout: View {
    var reading: CalibrationModel.Reading
    var step: CalibrationProcess.Step
    var awaiting: Bool
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("YAW", String(format: "%+7.1f°", reading.yaw))
            row("PITCH", String(format: "%+7.1f°", reading.pitch))
            row("ROLL", String(format: "%+7.1f°", reading.roll))
            row("GRAVITY", String(format: "%+.2f %+.2f %+.2f", reading.gravity.x, reading.gravity.y, reading.gravity.z))
            Divider().background(Color.white.opacity(0.15))
            if let d = reading.fromScreen {
                row("FROM SCREEN", String(format: "%5.1f°", d), valueColor: fromScreenColor(d))
                if let target = target {
                    Text(target).font(Theme.mono(10)).foregroundStyle(.white.opacity(0.45))
                }
            } else {
                row("FROM SCREEN", "—")
            }
            if let m = reading.motion {
                let steady = m < 5
                row("MOVEMENT", String(format: "%5.1f°", m), valueColor: steady ? .green : .orange)
            }
            if !awaiting, let hint = reading.hint {
                Label(hint, systemImage: "arrow.up.forward")
                    .font(Theme.body(11.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.45), lineWidth: 1))
    }

    private var target: String? {
        switch step {
        case .pointUp: return String(format: "ceiling needs > %.0f°", CalibrationProcess.minimumRaiseDegrees)
        case .confirmCenter: return String(format: "centre needs < %.0f°", CalibrationProcess.maximumRecenterDegrees)
        default: return nil
        }
    }

    private func fromScreenColor(_ d: Double) -> Color {
        switch step {
        case .pointUp: return d > CalibrationProcess.minimumRaiseDegrees ? .green : .orange
        case .confirmCenter: return d < CalibrationProcess.maximumRecenterDegrees ? .green : .orange
        default: return .white
        }
    }

    private func row(_ label: String, _ value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label).font(Theme.mono(10.5)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value).font(Theme.mono(12)).foregroundStyle(valueColor).monospacedDigit()
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
