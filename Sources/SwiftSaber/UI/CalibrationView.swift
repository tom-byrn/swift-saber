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
                    HStack {
                        Text("INPUT").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Picker("Input", selection: Binding(get: { model.settings.inputMode }, set: { model.settings.inputMode = $0 })) {
                            ForEach(InputMode.allCases.filter(\.usesMotionDevices)) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 250)
                    }
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
                        Divider().overlay(Color.white.opacity(0.15))
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
                    Text("YOUR SABERS").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
                    SaberHandsView(sabers: model.saberSummary().map { (hand: $0.hand, name: model.deviceName($0.device), symbol: model.deviceSymbol($0.device)) })
                    Button("⇄ Swap hands") { model.swapHands() }
                        .buttonStyle(NeonButtonStyle(color: .gray, width: 330))
                        .disabled(!model.canSwapHands)

                    Text("DEVICES").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)
                    if mode.usesAirPods && !usesCase { MotionStatusBanner(motion: model.motion) }
                    if mode.usesPhone { PhoneStatusBanner(phone: model.phone) }
                    let rows = model.deviceRows()
                    if rows.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for devices…")
                                .font(Theme.body(14)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    ForEach(rows) { row in
                        DeviceRowView(row: row, reading: reading(for: row)) { used in
                            if let d = row.device { model.setDevice(d, used: used) }
                        }
                    }
                    Text(model.setupHint())
                        .font(Theme.body(13))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Start Calibration") { model.beginCalibration() }
                        .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 330))
                        .disabled(!model.plannedDevices.values.contains(where: \.needsCalibration))
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

    /// The live yaw / pitch / roll line for a device row.
    private func reading(for row: AppModel.DeviceRow) -> CalibrationModel.Reading? {
        guard let d = row.device, row.live else { return nil }
        return calibration.streams.first { $0.id.device == d && $0.live }?.reading
    }

    private var mode: InputMode { model.settings.inputMode }
    private var usesCase: Bool { model.usesAirPodsCase }

    private var checklist: [(String, String)] {
        let main = model.settings.primaryHand.name.lowercased()
        let other = model.settings.primaryHand.other.name.lowercased()
        let phoneStep = ("Open Swift Saber on your iPhone or iPad",
                         "Same Wi-Fi network as this Mac. It finds the game automatically — allow Local Network access when asked.")
        let controllerStep = ("Pair a motion controller with this Mac",
                              "DualSense, DualShock 4 or Joy-Con: System Settings › Bluetooth, then press a button on it. Its light bar takes the saber's colour.")
        var steps: [(String, String)] = []
        if usesCase {
            // The case panel covers the AirPods; only the other devices' steps remain.
            if mode == .airpodAndPhone {
                steps.append(("Open Swift Saber on your iPhone or iPad",
                              "Same Wi-Fi network as this Mac. Hold it in your \(other) fist; any orientation works."))
            } else if mode == .automatic {
                steps.append(("Want a second saber?", "Open Swift Saber on an iPhone or iPad, or pair a DualSense / Joy-Con. It shows up on the right."))
            }
            return steps
        }
        switch mode {
        case .automatic:
            steps.append(("Connect any two devices",
                          "An AirPod (with Automatic Ear Detection off), an iPhone or iPad running Swift Saber on the same Wi-Fi, or a DualSense, DualShock 4 or Joy-Con paired over Bluetooth."))
            steps.append(("Check the hands",
                          "Each device shows the hand it will drive. Swap them, or switch off one you don't want as a saber — like AirPods you're wearing."))
            steps.append(("Hold them like hilts", "Grip each device like a sword handle, any way round: calibration works out the orientation."))
        case .controllers:
            steps.append(controllerStep)
            steps.append(("One in each hand", "Grip it like a hilt, any way round. A Joy-Con pair goes L in the left hand, R in the right."))
        case .twoPhones:
            steps.append(("Open Swift Saber on both devices", phoneStep.1))
            steps.append(("One in each fist", "Grip each like a sword hilt; any orientation works. Set a device to Remote only on its screen if you'd rather not swing it."))
        default:
            if mode.usesAirPods {
                steps.append(("Connect your AirPods to this Mac",
                              "AirPods Pro / Max / 3rd gen or later with spatial audio support."))
                steps.append(("Turn off Automatic Ear Detection",
                              "System Settings › your AirPods › Automatic Ear Detection: Off. Otherwise motion stops when the buds leave your ears."))
            }
            if mode.usesPhone { steps.append(phoneStep) }
            switch mode {
            case .airpodAndPhone:
                steps.append(("AirPod in your \(main) fist, phone or iPad in your \(other)",
                              "Hold one bud only (AirPods stream from one bud at a time). Grip the phone like a hilt; any orientation works."))
            case .phone:
                steps.append(("Hold it in your \(main) fist", "Grip it like a sword hilt — any orientation works."))
            default:
                steps.append(("Hold one AirPod in your \(main) fist", "Grip it firmly, stem pointing any direction — calibration works out the orientation."))
            }
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
                            HoldRing(label: model.streamName(s.id), progress: s.progress,
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
                     ? "Press Next, Return or Space — or NEXT on your phone or controller — when you're ready."
                     : "Hold still until the ring fills. You'll get a chance to move before the next step.")
                    .font(Theme.body(12.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 860)
    }

    /// The colour of the hand this stream's device is about to drive.
    private func color(for id: StreamID) -> Color {
        switch model.plannedDevices.first(where: { $0.value == id.device })?.key {
        case .left: return Theme.red
        case .right: return Theme.blue
        case nil: return Color(red: 0.75, green: 0.55, blue: 1.0)
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
                HStack(spacing: 14) {
                    SaberHandsView(sabers: model.saberSummary().map { (hand: $0.hand, name: model.deviceName($0.device), symbol: model.deviceSymbol($0.device)) })
                        .frame(width: 360)
                    if model.canSwapHands {
                        Button("⇄ Swap") { model.swapHands() }
                            .buttonStyle(NeonButtonStyle(color: .gray))
                    }
                }
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
        .offset(y: 120)
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
        case .connected:
            EmptyView() // each device has its own row
        case .waiting:
            Label("Looking for Swift Saber on an iPhone or iPad…", systemImage: "iphone").font(Theme.body(13)).foregroundStyle(.white.opacity(0.7))
        case .failed(let msg):
            Label("Network error: \(msg)", systemImage: "exclamationmark.triangle.fill").font(Theme.body(13)).foregroundStyle(.orange)
        case .off:
            EmptyView()
        }
    }
}

/// Which device drives each hand.
struct SaberHandsView: View {
    var sabers: [(hand: Hand, name: String, symbol: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Hand.allCases, id: \.self) { hand in
                let saber = sabers.first { $0.hand == hand }
                let color = hand == .left ? Theme.red : Theme.blue
                VStack(spacing: 6) {
                    Text(hand == .left ? "LEFT HAND" : "RIGHT HAND").font(Theme.mono(10)).foregroundStyle(color)
                    Image(systemName: saber?.symbol ?? "hand.raised.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(saber == nil ? Color.white.opacity(0.25) : Color.white)
                        .frame(height: 30)
                    Text(saber?.name ?? "No saber")
                        .font(Theme.body(12.5))
                        .foregroundStyle(saber == nil ? Color.white.opacity(0.4) : Color.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(saber == nil ? 0.04 : 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(saber == nil ? 0.2 : 0.6), lineWidth: 1))
            }
        }
    }
}

/// One connected device in Saber Setup: what it is, whether it streams, the hand it will
/// drive, and a switch to leave it out.
struct DeviceRowView: View {
    var row: AppModel.DeviceRow
    var reading: CalibrationModel.Reading?
    var setUsed: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 20))
                .foregroundStyle(row.live ? Color.green : Color.gray)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(Theme.body(14)).foregroundStyle(.white).lineLimit(1)
                Text(row.note ?? (row.calibrated ? "Streaming · calibrated" : "Streaming"))
                    .font(Theme.body(11.5))
                    .foregroundStyle(row.note == nil ? Color.green : Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let r = reading {
                    Text(String(format: "yaw %+.0f°  pitch %+.0f°  roll %+.0f°", r.yaw, r.pitch, r.roll))
                        .font(Theme.mono(10))
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 6)
            if let hand = row.hand {
                Text(hand == .left ? "LEFT" : "RIGHT")
                    .font(Theme.mono(10)).tracking(1)
                    .foregroundStyle(hand == .left ? Theme.red : Theme.blue)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().stroke((hand == .left ? Theme.red : Theme.blue).opacity(0.7), lineWidth: 1))
            }
            if row.canToggle {
                Toggle("Use", isOn: Binding(get: { row.used }, set: setUsed))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(row.used ? "Leave this device out" : "Use this device as a saber")
            }
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
