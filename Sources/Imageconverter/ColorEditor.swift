import AppKit
import SwiftUI
import ImageconverterCore

/// The Color step: Profile, then Re-color, then Reduce colours (the order they run in).
struct ColorEditor: View {
    @Binding var options: ColorOptions

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            section("Profile") {
                Picker("Profile", selection: $options.profile) {
                    ForEach(ColorProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Color profile")
            }
            section("Re-color") {
                RecolorControls(options: $options.recolor)
            }
            section("Reduce colours") {
                ReduceControls(reduction: $options.reduce)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.text)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private struct RecolorControls: View {
    @Binding var options: RecolorOptions

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Re-color", selection: $options.kind) {
                ForEach(RecolorKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Re-color")
            switch options.kind {
            case .none:
                EmptyView()
            case .tint:
                HexColorWell(title: "Tint colour", color: $options.tint)
                strength
            case .duotone:
                HStack(spacing: LadaGlass.Spacing.m) {
                    HexColorWell(title: "Shadows", color: $options.shadows)
                    HexColorWell(title: "Highlights", color: $options.highlights)
                }
                strength
            case .sepia:
                strength
            case .replace:
                HStack(spacing: LadaGlass.Spacing.m) {
                    HexColorWell(title: "Replace", color: $options.source)
                    Image(systemName: "arrow.right").foregroundStyle(LadaGlass.Colors.muted).accessibilityHidden(true)
                    HexColorWell(title: "With", color: $options.target)
                }
                PercentSlider(title: "Tolerance", value: $options.tolerance, range: RecolorOptions.percentRange)
                PercentSlider(title: "Softness", value: $options.softness, range: RecolorOptions.percentRange)
                Text("Matches by hue; greys are left alone. Shading is kept.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            case .hueShift:
                PercentSlider(title: "Hue", value: $options.hueShift, range: RecolorOptions.hueRange, unit: "°",
                              spokenUnit: "degrees")
            }
        }
    }

    private var strength: some View {
        PercentSlider(title: "Strength", value: $options.strength, range: RecolorOptions.percentRange)
    }
}

private struct ReduceControls: View {
    @Binding var reduction: ColorReduction

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Toggle("Reduce to a palette", isOn: $reduction.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if reduction.isEnabled {
                HStack(spacing: LadaGlass.Spacing.s) {
                    NumberField(title: "Colours", value: Binding(
                        get: { reduction.clampedCount }, set: { reduction.count = $0 }),
                                minimum: ColorReduction.countRange.lowerBound,
                                maximum: ColorReduction.countRange.upperBound, suffix: "")
                    Stepper("Colours", value: Binding(get: { reduction.clampedCount }, set: { reduction.count = $0 }),
                            in: ColorReduction.countRange)
                        .labelsHidden()
                        .accessibilityLabel("Colours")
                }
                Toggle("Dithering", isOn: $reduction.dither)
                    .toggleStyle(.checkbox)
                Text("PNG is written with a palette when it can be; GIF always is.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            }
        }
    }
}

/// A colour well for an opaque sRGB colour saved as hex.
private struct HexColorWell: View {
    let title: String
    @Binding var color: HexColor

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: {
                let (red, green, blue) = color.components
                return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
            },
            set: { new in
                guard let native = NSColor(new).usingColorSpace(.sRGB) else { return }
                color = HexColor(unitRed: Double(native.redComponent), green: Double(native.greenComponent),
                                 blue: Double(native.blueComponent))
            }), supportsOpacity: false)
            .font(LadaGlass.Typography.label)
            .accessibilityLabel(title)
            .accessibilityValue(color.hex)
    }
}

/// A labelled slider with its value; whole numbers.
private struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "%"
    var spokenUnit = "percent"

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .frame(width: 72, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value)) \(spokenUnit)")
            Text("\(Int(value))\(unit)").font(LadaGlass.Typography.mono)
                .foregroundStyle(LadaGlass.Colors.text)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}
