import SwiftUI
import ImageconverterCore

/// Editor for the Adjust step: labelled sliders in three groups, each value resettable to 0.
struct AdjustEditor: View {
    @Binding var options: AdjustOptions

    private typealias Field = AdjustOptions.Field

    private static let groups: [(title: String, fields: [Field])] = [
        ("Light", [.exposure, .brilliance, .highlights, .shadows, .contrast, .brightness, .blackPoint]),
        ("Colour", [.saturation, .vibrance, .warmth, .tint, .hue]),
        ("Detail", [.sharpness, .definition, .noiseReduction])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            ForEach(Self.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                    HStack {
                        Text(group.title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.text)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Reset") { for field in group.fields { options[field] = 0 } }
                            .buttonStyle(.lg(.ghost))
                            .controlSize(.small)
                            .disabled(group.fields.allSatisfy { options[$0] == 0 })
                            .accessibilityLabel("Reset \(group.title)")
                    }
                    ForEach(group.fields, id: \.self) { field in
                        AdjustSlider(field: field, value: Binding(
                            get: { options[field] }, set: { options[field] = $0 }))
                    }
                }
            }
            Text("Double-click a label or slider to reset it.").font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
        }
    }
}

/// One adjustment: label (double-click resets), slider, value text.
private struct AdjustSlider: View {
    let field: AdjustOptions.Field
    @Binding var value: Double

    private var shown: Int { Int(AdjustOptions.clamped(value, to: field).rounded()) }

    /// Displayed as 0 (the display rounds to integers), so the track stays grey.
    private var isNeutral: Bool { abs(value) < 0.5 }

    private var valueText: String {
        // Signed fields show + and a real minus sign, like the step summary.
        let number = shown < 0 ? "−\(-shown)" : (field.range.lowerBound < 0 && shown > 0 ? "+\(shown)" : "\(shown)")
        return number + (field == .hue ? "°" : "")
    }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text(field.displayName).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value = 0 }
                .help("Double-click to reset")
                .accessibilityHidden(true)
            AdjustSliderControl(value: Binding(
                get: { AdjustOptions.clamped(value, to: field) },
                set: { value = $0 }), range: field.range)
                .help("Double-click to reset")
                .accessibilityLabel(field.displayName)
                .accessibilityValue(field == .hue ? "\(shown) degrees" : "\(shown)")
                .accessibilityAction(named: "Reset to 0") { value = 0 }
            Text(valueText).font(LadaGlass.Typography.mono).foregroundStyle(LadaGlass.Colors.text)
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}
