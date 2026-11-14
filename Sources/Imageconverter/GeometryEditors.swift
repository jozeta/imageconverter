import SwiftUI
import ImageconverterCore

// MARK: - Rotate / flip

struct RotateFlipEditor: View {
    @Binding var options: RotateFlipOptions

    private enum Fill: String, CaseIterable {
        case expand = "Fill corners", crop = "Crop to fit (straighten)"
    }

    private var fill: Fill {
        if case .expand = options.angleFill { return .expand }
        return .crop
    }

    private var background: RGBAColor {
        if case .expand(let color) = options.angleFill { return color }
        return .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Rotation", selection: $options.rotation) {
                ForEach(Rotation.allCases, id: \.self) { Text("\($0.rawValue)°").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Rotation")
            angleRow
            if options.angle != 0 {
                Picker("Corners", selection: Binding(
                    get: { fill },
                    set: { options.angleFill = $0 == .expand ? .expand(background: background) : .cropToFit })) {
                    ForEach(Fill.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .accessibilityLabel("Angle corners")
                if fill == .expand {
                    Toggle("Transparent corners", isOn: Binding(
                        get: { background.alpha == 0 },
                        set: { options.angleFill = .expand(background: $0 ? .clear : .white) }))
                    if background.alpha != 0 {
                        ColorField(title: "Corner colour", color: Binding(
                            get: { background }, set: { options.angleFill = .expand(background: $0) }))
                    }
                }
            }
            Toggle("Mirror (flip horizontally)", isOn: $options.flipHorizontal)
            Toggle("Flip vertically", isOn: $options.flipVertical)
        }
    }

    /// The slider covers the useful −45...45 range; the field accepts the full −180...180.
    private var angleRow: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text("Angle").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            Slider(value: Binding(
                get: { min(45, max(-45, options.angle)) },
                set: { options.angle = ($0 * 10).rounded() / 10 }), in: -45...45)
                .accessibilityLabel("Angle")
                .accessibilityValue("\(options.angle) degrees")
                .accessibilityAction(named: "Reset to 0") { options.angle = 0 }
            TextField("Angle in degrees", value: Binding(
                get: { options.angle },
                set: { options.angle = RotateFlipOptions.clampedAngle($0) }), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .accessibilityLabel("Angle in degrees")
            Text("°").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
        }
    }
}

// MARK: - Perspective

struct PerspectiveEditor: View {
    @Binding var options: PerspectiveOptions

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Toggle("Auto", isOn: $options.auto)
                .help("Finds a document or screen and squares it up")
                .accessibilityHint("Finds a document or screen and squares it up")
            Text("Finds a document or screen and squares it up.")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            SignedSlider(title: "Vertical", value: $options.vertical, range: PerspectiveOptions.range)
            SignedSlider(title: "Horizontal", value: $options.horizontal, range: PerspectiveOptions.range)
            Button("Reset") { options.vertical = 0; options.horizontal = 0 }
                .buttonStyle(.lg(.ghost))
                .controlSize(.small)
                .disabled(options.vertical == 0 && options.horizontal == 0)
                .accessibilityLabel("Reset keystone sliders")
        }
    }
}

/// A labelled slider with a signed value text; double-click the label to reset.
private struct SignedSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var shown: Int { Int(value.rounded()) }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .frame(width: 72, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value = 0 }
                .help("Double-click to reset")
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(shown)")
                .accessibilityAction(named: "Reset to 0") { value = 0 }
            Text(shown < 0 ? "−\(-shown)" : (shown > 0 ? "+\(shown)" : "0"))
                .font(LadaGlass.Typography.mono).foregroundStyle(LadaGlass.Colors.text)
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Trim

struct TrimEditor: View {
    @Binding var options: TrimOptions

    private enum Kind: String, CaseIterable {
        case transparent = "Transparent edges", color = "Colour", edge = "Edge colour"
    }

    private var kind: Kind {
        switch options.mode {
        case .transparent: return .transparent
        case .color: return .color
        case .edgeColor: return .edge
        }
    }

    private var color: RGBAColor {
        if case .color(let value) = options.mode { return value }
        return .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Trim", selection: Binding(
                get: { kind },
                set: { new in
                    switch new {
                    case .transparent: options.mode = .transparent
                    case .color: options.mode = .color(color)
                    case .edge: options.mode = .edgeColor
                    }
                })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityLabel("Trim mode")
            if kind == .color {
                ColorField(title: "Border colour", color: Binding(
                    get: { color }, set: { options.mode = .color($0) }))
            }
            HStack(spacing: LadaGlass.Spacing.s) {
                Text("Tolerance").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .frame(width: 72, alignment: .leading)
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { options.tolerance }, set: { options.tolerance = $0.rounded() }),
                       in: TrimOptions.toleranceRange)
                    .accessibilityLabel("Tolerance")
                    .accessibilityValue("\(Int(options.tolerance)) percent")
                Text("\(Int(options.tolerance))%").font(LadaGlass.Typography.mono)
                    .foregroundStyle(LadaGlass.Colors.text)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            NumberField(title: "Padding", value: Binding(
                get: { options.padding }, set: { options.padding = $0 }), minimum: 0, maximum: 10_000)
        }
    }
}

// MARK: - Aspect ratio menu (canvas)

/// A preset menu of `SizePresets.aspectRatios` plus "Custom" with two fields, editing a canvas aspect mode.
struct AspectRatioPicker: View {
    @Binding var mode: CanvasMode
    @State private var custom = false

    private static let presets = SizePresets.aspectRatios

    private var ratio: (wide: Double, high: Double) {
        if case .aspect(let wide, let high) = mode { return (wide, high) }
        return (1, 1)
    }

    private var presetName: String {
        if custom { return "Custom" }
        return Self.presets.first { $0.width == ratio.wide && $0.height == ratio.high }?.name ?? "Custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Ratio", selection: Binding(
                get: { presetName },
                set: { name in
                    if let preset = Self.presets.first(where: { $0.name == name }) {
                        custom = false
                        mode = .aspect(width: preset.width, height: preset.height)
                    } else {
                        custom = true
                    }
                })) {
                ForEach(Self.presets, id: \.name) { Text($0.name).tag($0.name) }
                Text("Custom").tag("Custom")
            }
            .accessibilityLabel("Aspect ratio")
            if presetName == "Custom" {
                FieldRow {
                    DecimalField(title: "Ratio width", value: Binding(
                        get: { ratio.wide }, set: { mode = .aspect(width: $0, height: ratio.high) }))
                    Text(":").foregroundStyle(LadaGlass.Colors.muted)
                    DecimalField(title: "Ratio height", value: Binding(
                        get: { ratio.high }, set: { mode = .aspect(width: ratio.wide, height: $0) }))
                }
            }
        }
    }
}
