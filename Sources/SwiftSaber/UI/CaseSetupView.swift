import SwiftUI
import SaberCore

/// Guided connection for the closed-case saber: open the lid, close it, set the case down,
/// pick it up. Sits on the Saber Setup screen; calibration follows once the case is ready.
struct CaseSetupPanel: View {
    @ObservedObject var session: AirPodsCaseSession
    var hand: String

    private struct Step {
        var title: String
        var detail: String
    }

    private var steps: [Step] {
        [
            Step(title: "Get the case ready",
                 detail: "Both AirPods Pro in their case, paired with this Mac. If they're also paired with your iPhone, turn its Bluetooth off (Swift Saber on the phone uses Wi-Fi)."),
            Step(title: "Open the lid",
                 detail: "Swift Saber connects while the lid is open. Keep both AirPods inside."),
            Step(title: "Close the lid",
                 detail: "Keep both AirPods inside. It's noticed by itself, or press Lid Is Closed."),
            Step(title: "Set it down",
                 detail: "Put the closed case on a flat surface and don't touch it while the ring fills. This only happens the first time each week."),
            Step(title: "Pick it up",
                 detail: "Hold the case in your \(hand) fist like a sword hilt, lid towards the screen or any way you like."),
        ]
    }

    /// Which step is current (0-based); `steps.count` means connected.
    private var current: Int {
        switch session.stage {
        case .off: return 0
        case .preparing, .openLid, .connecting: return 1
        case .closeLid: return 2
        case .holdStill, .linking: return 3
        case .ready: return 5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AIRPODS CASE").font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let title = session.pairTitle, session.stage.isActive {
                    Text(title).font(Theme.body(12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                CaseStepRow(n: i + 1, title: step.title, detail: step.detail,
                            state: i < current ? .done : (i == current ? .active : .upcoming),
                            progress: i == 3 && session.stage == .holdStill ? session.holdProgress : nil)
            }

            status
            controls

            Text("While connected, Mac sound and the microphone stay off these AirPods. Connecting briefly drops their audio, so don't connect during a call. Ending a session uses up diagnostic data stored on the case. A session lasts about 30 minutes after the lid closes; connect again to keep playing.")
                .font(Theme.body(11)).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        switch session.stage {
        case .off:
            if let problem = session.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(13)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preparing:
            waiting("Looking for your AirPods…")
        case .openLid:
            waiting("Open the lid to connect.")
        case .connecting:
            waiting("Connecting — keep the lid open for a moment.")
        case .closeLid:
            Label("Motion is flowing. Now close the lid.", systemImage: "airpodspro.chargingcase.wireless")
                .font(Theme.body(13)).foregroundStyle(Theme.blue)
        case .holdStill:
            Label(session.holdMoving ? "Movement detected — leave the case still." : "Measuring the sensor… keep it still.",
                  systemImage: session.holdMoving ? "hand.raised.fill" : "level")
                .font(Theme.body(13)).foregroundStyle(session.holdMoving ? .orange : .white.opacity(0.8))
        case .linking:
            waiting("Almost there…")
        case .ready:
            Label("Case connected — your saber is live.", systemImage: "checkmark.circle.fill")
                .font(Theme.body(13)).foregroundStyle(.green)
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.body(13)).foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 12) {
            switch session.stage {
            case .off:
                Button(session.problem == nil ? "Connect Case" : "Connect Again") { session.connect() }
                    .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 220))
            case .closeLid:
                Button("Lid Is Closed") { session.confirmLidClosed() }
                    .buttonStyle(NeonButtonStyle(color: Theme.blue, prominent: true, width: 220))
                Button("Cancel") { session.disconnect() }
                    .buttonStyle(NeonButtonStyle(color: .gray))
            case .ready:
                Button("Disconnect Case") { session.disconnect() }
                    .buttonStyle(NeonButtonStyle(color: .gray))
            default:
                Button("Cancel") { session.disconnect() }
                    .buttonStyle(NeonButtonStyle(color: .gray))
            }
        }
        .padding(.top, 2)
    }
}

struct CaseStepRow: View {
    enum State { case done, active, upcoming }
    var n: Int
    var title: String
    var detail: String
    var state: State
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().stroke(ringColor.opacity(state == .upcoming ? 0.35 : 0.9), lineWidth: 1.5)
                if let progress {
                    Circle().trim(from: 0, to: progress)
                        .stroke(Theme.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: progress)
                }
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(n)").font(Theme.heading(14)).foregroundStyle(.white.opacity(state == .active ? 1 : 0.45))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(14)).foregroundStyle(.white.opacity(state == .upcoming ? 0.5 : 1))
                if state == .active {
                    Text(detail).font(Theme.body(12)).foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var ringColor: Color {
        switch state {
        case .done: return .green
        case .active: return Theme.blue
        case .upcoming: return .white
        }
    }
}
