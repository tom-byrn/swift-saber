import SwiftUI
import SaberCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    private func binding<T>(_ kp: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { model.settings[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button("‹ Back") { model.screen = .menu }
                    .buttonStyle(NeonButtonStyle(color: .gray))
                Spacer()
                NeonText(text: "SETTINGS", color: .white, font: Theme.display(44))
                Spacer()
                Color.clear.frame(width: 110, height: 1)
            }

            HStack(alignment: .top, spacing: 22) {
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle("Controls")
                        Picker("Input", selection: binding(\.inputMode)) {
                            ForEach(InputMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(model.settings.inputMode.detail).font(Theme.body(12)).foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Main hand", selection: binding(\.primaryHand)) {
                            Text("Left").tag(Hand.left)
                            Text("Right").tag(Hand.right)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Swap left / right AirPods", isOn: binding(\.swapAirPods))

                        SliderRow(title: "Saber sensitivity", value: binding(\.sensitivity), range: 0.6...2.0,
                                  format: { String(format: "%.2f×", $0) })
                        SliderRow(title: "AirPods motion delay", value: binding(\.airPodLatencyMs), range: 0...150,
                                  format: { "\(Int($0)) ms" })
                        Toggle("Lenient cut angles", isOn: binding(\.lenientCuts))
                        Toggle("Auto-recenter when a song starts", isOn: binding(\.autoRecenter))
                        Toggle("Keep AirPods awake (silent stream)", isOn: binding(\.keepAirPodsAwake))
                    }
                }
                .frame(width: 470)

                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle("Audio")
                        Picker("Play game audio on", selection: binding(\.audioOutput)) {
                            Text("Mac speakers (recommended)").tag("auto")
                            Text("System default output").tag("system")
                            ForEach(model.outputDevices) { d in
                                Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
                            }
                        }
                        Text("AirPods in your hands can't play the music, and Bluetooth adds ~200 ms of lag. Speakers keep the rhythm tight.")
                            .font(Theme.body(12)).foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                        SliderRow(title: "Music volume", value: binding(\.musicVolume), range: 0...1, format: { "\(Int($0 * 100))%" })
                        SliderRow(title: "Effects volume", value: binding(\.sfxVolume), range: 0...1, format: { "\(Int($0 * 100))%" })
                        SliderRow(title: "Audio offset", value: binding(\.audioOffsetMs), range: -200...300,
                                  format: { "\(Int($0)) ms" })

                        SectionTitle("Visuals").padding(.top, 6)
                        Toggle("Bloom & glow", isOn: binding(\.bloom))
                        Toggle("Camera shake", isOn: binding(\.cameraShake))
                        Toggle("No Fail", isOn: binding(\.noFail))
                    }
                }
                .frame(width: 470)
            }
            .toggleStyle(.switch)
            .tint(Theme.blue)
            .font(Theme.body(14))
            .foregroundStyle(.white)
        }
        .padding(44)
        .onAppear { model.refreshOutputDevices() }
    }
}

struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).font(Theme.mono(12)).foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: $value, in: range)
        }
    }
}
