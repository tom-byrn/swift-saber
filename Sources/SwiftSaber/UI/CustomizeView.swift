import SwiftUI
import AppKit
import SaberCore

extension NeonColor {
    var color: Color { Color(nsColor: ns) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}

/// Pick the arena and the colours. The live 3D arena stays visible between the two panels,
/// so every change previews instantly.
struct CustomizeView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedSlot: SaberColorScheme.Slot = .leftSaber

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("‹ Back") { model.screen = .menu }
                    .buttonStyle(NeonButtonStyle(color: .gray))
                Spacer()
                NeonText(text: "ARENA & COLORS", color: Theme.blue, font: Theme.display(44))
                Spacer()
                Color.clear.frame(width: 110, height: 1)
            }

            HStack(alignment: .top, spacing: 0) {
                Panel(padding: 20) { ArenaList() }
                    .frame(width: 330)
                Spacer(minLength: 20)
                VStack {
                    Spacer()
                    Button("Preview Lights") { model.renderer.previewLights() }
                        .buttonStyle(NeonButtonStyle(color: .white, width: 200))
                }
                Spacer(minLength: 20)
                Panel(padding: 20) { ColorEditor(selectedSlot: $selectedSlot) }
                    .frame(width: 430)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
    }
}

// MARK: - Arenas

private struct ArenaList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Arena")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(StageKind.allCases) { kind in
                        ArenaRow(kind: kind, selected: model.settings.stage == kind) {
                            model.settings.stage = kind
                            model.audio.play(.click, volume: 0.5)
                        }
                    }
                }
            }
        }
    }
}

private struct ArenaRow: View {
    var kind: StageKind
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                let c = kind.defaultColors
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [c.leftLights.color.opacity(0.55), c.rightLights.color.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: kind.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title.uppercased())
                        .font(Theme.heading(18)).tracking(1)
                        .foregroundStyle(.white)
                    Text(kind.tagline)
                        .font(Theme.body(11))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : (hovering ? 0.07 : 0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.blue : Color.white.opacity(0.1), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Colours

private struct ColorEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedSlot: SaberColorScheme.Slot

    private var colors: SaberColorScheme { model.settings.effectiveColors }

    /// Writes a change as the custom scheme (switching custom colours on).
    private func edit(_ change: (inout SaberColorScheme) -> Void) {
        var s = model.settings
        var c = s.effectiveColors
        change(&c)
        s.customColors = c
        s.overrideColors = true
        model.settings = s
    }

    private func slotBinding(_ slot: SaberColorScheme.Slot) -> Binding<NeonColor> {
        Binding(get: { colors[slot] }, set: { v in edit { $0[slot] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Colors")
                Spacer()
                Toggle("Custom colors", isOn: Binding(
                    get: { model.settings.overrideColors },
                    set: { on in
                        var s = model.settings
                        if on && !s.overrideColors && s.customColors == .classic {
                            // First time: start from what's on screen.
                            s.customColors = s.stage.defaultColors
                        }
                        s.overrideColors = on
                        model.settings = s
                    }))
                .toggleStyle(.switch)
                .tint(Theme.blue)
                .font(Theme.body(13))
                .foregroundStyle(.white.opacity(0.85))
            }
            Text(model.settings.overrideColors
                 ? "Your colours are used in every arena."
                 : "Using \(model.settings.stage.title)'s own colours. Pick a template or edit a colour to customise.")
                .font(Theme.body(11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    templates
                    Divider().overlay(Theme.stroke)
                    BlockPreview(colors: colors)
                    VStack(spacing: 6) {
                        ForEach(SaberColorScheme.Slot.allCases) { slot in
                            SlotRow(slot: slot, color: slotBinding(slot), selected: selectedSlot == slot) {
                                selectedSlot = slot
                            }
                        }
                    }
                    RGBSliders(color: slotBinding(selectedSlot), title: selectedSlot.title)
                    HStack(spacing: 10) {
                        Button("Swap Left / Right") { edit { $0 = $0.swapped } }
                        Button("Lights Match Sabers") {
                            edit { $0.leftLights = $0.leftSaber; $0.rightLights = $0.rightSaber }
                        }
                        Spacer()
                        Button("Reset") {
                            var s = model.settings
                            s.overrideColors = false
                            s.customColors = s.stage.defaultColors
                            model.settings = s
                        }
                    }
                    .buttonStyle(SmallButtonStyle())
                }
                .padding(.trailing, 6)
            }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEMPLATES").font(Theme.mono(10)).foregroundStyle(.white.opacity(0.45))
            let current = ColorPreset.matching(colors)?.id
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ColorPreset.all) { preset in
                    PresetSwatch(preset: preset, selected: current == preset.id) {
                        edit { $0 = preset.scheme }
                        model.audio.play(.click, volume: 0.5)
                    }
                }
            }
        }
    }
}

private struct PresetSwatch: View {
    var preset: ColorPreset
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    private var sabers: some View {
        let s = preset.scheme
        return HStack(spacing: 0) {
            Rectangle().fill(s.leftSaber.color)
            Rectangle().fill(s.rightSaber.color)
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var lights: some View {
        let s = preset.scheme
        return HStack(spacing: 0) {
            Rectangle().fill(s.leftLights.color)
            Rectangle().fill(s.rightLights.color)
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .padding(.horizontal, 6)
    }

    private var fillOpacity: Double { selected ? 0.14 : (hovering ? 0.08 : 0.03) }
    private var strokeColor: Color { Color.white.opacity(selected ? 0.9 : 0.1) }

    private var label: some View {
        VStack(spacing: 3) {
            sabers
            lights
            Text(preset.name)
                .font(Theme.body(10))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.white.opacity(selected ? 1 : 0.7))
                .padding(.top, 2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(fillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(strokeColor, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(preset.name)
    }
}

/// A row for one colour: swatch, name, hex field and the system colour panel.
private struct SlotRow: View {
    var slot: SaberColorScheme.Slot
    @Binding var color: NeonColor
    var selected: Bool
    var select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(color.color)
                        .frame(width: 20, height: 20)
                        .shadow(color: color.color, radius: selected ? 6 : 2)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    Text(slot.title)
                        .font(Theme.body(13))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HexField(color: $color)
            ColorPicker("", selection: Binding(get: { color.color }, set: { color = NeonColor($0) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? color.color.opacity(0.9) : Color.clear, lineWidth: 1.2)
        )
    }
}

/// Hex entry ("#RRGGBB"); applies on Return or when focus leaves.
private struct HexField: View {
    @Binding var color: NeonColor
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("#RRGGBB", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundStyle(.white)
            .frame(width: 76)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(focused ? 0.5 : 0.15)))
            .focused($focused)
            .onAppear { text = color.hex }
            .onChange(of: color) { (_: NeonColor, new: NeonColor) in if !focused { text = new.hex } }
            .onChange(of: focused) { (_: Bool, isFocused: Bool) in if !isFocused { commit() } }
            .onSubmit { commit() }
    }

    private func commit() {
        if let c = NeonColor(hex: text) { color = c }
        text = color.hex
    }
}

/// Full 0–255 red / green / blue sliders for the selected colour.
private struct RGBSliders: View {
    @Binding var color: NeonColor
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EDITING: \(title.uppercased())").font(Theme.mono(10)).foregroundStyle(.white.opacity(0.45))
            channel("R", value: Binding(get: { Double(color.r255) }, set: { color = NeonColor(r255: Int($0), g255: color.g255, b255: color.b255) }),
                    gradient: [NeonColor(0, color.g, color.b).color, NeonColor(1, color.g, color.b).color])
            channel("G", value: Binding(get: { Double(color.g255) }, set: { color = NeonColor(r255: color.r255, g255: Int($0), b255: color.b255) }),
                    gradient: [NeonColor(color.r, 0, color.b).color, NeonColor(color.r, 1, color.b).color])
            channel("B", value: Binding(get: { Double(color.b255) }, set: { color = NeonColor(r255: color.r255, g255: color.g255, b255: Int($0)) }),
                    gradient: [NeonColor(color.r, color.g, 0).color, NeonColor(color.r, color.g, 1).color])
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.3)))
    }

    private func channel(_ name: String, value: Binding<Double>, gradient: [Color]) -> some View {
        HStack(spacing: 10) {
            Text(name).font(Theme.mono(12)).foregroundStyle(.white.opacity(0.8)).frame(width: 14)
            VStack(spacing: 1) {
                Slider(value: value, in: 0...255)
                    .controlSize(.small)
                Capsule()
                    .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 4)
                    .padding(.horizontal, 3)
            }
            Text("\(Int(value.wrappedValue))")
                .font(Theme.mono(12)).foregroundStyle(.white)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Two little blocks and blades in the chosen colours.
private struct BlockPreview: View {
    var colors: SaberColorScheme

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Hand.allCases, id: \.self) { (hand: Hand) in
                HandPreview(c: colors.saber(hand))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(11))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2)))
    }
}

/// A block and a blade in one saber colour.
private struct HandPreview: View {
    var c: NeonColor

    var body: some View {
        let main: Color = c.color
        let deep: Color = c.deepened.color
        let core: Color = c.mixed(with: NeonColor.white, 0.7).color
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(deep)
                RoundedRectangle(cornerRadius: 7).strokeBorder(main, lineWidth: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: main.opacity(0.7), radius: 8)
            Capsule()
                .fill(LinearGradient(colors: [core, main], startPoint: .center, endPoint: .trailing))
                .frame(width: 70, height: 6)
                .shadow(color: main, radius: 6)
                .shadow(color: main, radius: 12)
        }
    }
}
