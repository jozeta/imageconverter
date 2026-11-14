import SwiftUI
import ImageconverterCore

/// A slider with its value as text and as the accessibility value.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "%"

    private var spokenUnit: String { unit == "°" ? "degrees" : unit }
    private var shown: Int { value.isFinite ? Int(min(max(value, range.lowerBound), range.upperBound).rounded()) : 0 }
    private var text: String { unit == "°" ? "\(shown)°" : "\(shown) \(unit)" }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .frame(width: 58, alignment: .leading)
            Slider(value: Binding(
                get: { value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound },
                set: { value = $0.rounded() }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(shown) \(spokenUnit)")
            Text(text).font(LadaGlass.Typography.mono).foregroundStyle(LadaGlass.Colors.text)
                .frame(width: 48, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// Rotation slider with quick buttons for the common angles.
struct WatermarkRotationControl: View {
    @Binding var rotation: Double

    private static let quick: [Double] = [0, -45, 45, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            ValueSlider(title: "Rotation", value: $rotation, range: -180...180, unit: "°")
            HStack(spacing: LadaGlass.Spacing.xs) {
                ForEach(Self.quick, id: \.self) { angle in
                    Button("\(Int(angle))°") { rotation = angle }
                        .buttonStyle(.lg(rotation == angle ? .secondary : .ghost))
                        .controlSize(.small)
                        .accessibilityLabel("Rotate \(Int(angle)) degrees")
                }
            }
            .padding(.leading, 58 + LadaGlass.Spacing.s)
        }
    }
}

/// Single or tiled; tiled shows its spacing and stagger.
struct WatermarkLayoutControl: View {
    @Binding var layout: WatermarkLayout

    private var isTiled: Bool {
        if case .tiled = layout { return true }
        return false
    }

    private var tiled: (spacing: Double, stagger: Bool) {
        if case .tiled(let spacing, let stagger) = layout { return (spacing, stagger) }
        return (WatermarkLayout.defaultSpacing, true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Layout", selection: Binding(
                get: { isTiled },
                set: { layout = $0 ? .tiled(spacing: tiled.spacing, stagger: tiled.stagger) : .single })) {
                Text("Single").tag(false)
                Text("Tiled").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Watermark layout")
            if isTiled {
                ValueSlider(title: "Spacing", value: Binding(
                    get: { tiled.spacing },
                    set: { layout = .tiled(spacing: $0, stagger: tiled.stagger) }), range: 0...400)
                Toggle("Stagger rows", isOn: Binding(
                    get: { tiled.stagger },
                    set: { layout = .tiled(spacing: tiled.spacing, stagger: $0) }))
                    .accessibilityLabel("Stagger every other row")
            }
        }
    }
}

/// A shadow toggle; when on, its colour, blur and offset.
struct WatermarkShadowControl: View {
    @Binding var shadow: WatermarkShadow?

    var body: some View {
        Toggle("Shadow", isOn: Binding(
            get: { shadow != nil },
            set: { shadow = $0 ? (shadow ?? WatermarkShadow()) : nil }))
            .accessibilityLabel("Watermark shadow")
        if let current = shadow {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                ColorField(title: "Shadow color", color: Binding(
                    get: { current.color }, set: { shadow?.color = $0 }))
                ValueSlider(title: "Blur", value: Binding(
                    get: { current.blur }, set: { shadow?.blur = $0 }), range: 0...50)
                ValueSlider(title: "Offset", value: Binding(
                    get: { current.offset }, set: { shadow?.offset = $0 }), range: 0...50)
            }
            .padding(.leading, LadaGlass.Spacing.m)
        }
    }
}

/// An outline toggle; when on, its colour and width.
struct WatermarkOutlineControl: View {
    @Binding var outline: WatermarkOutline?

    var body: some View {
        Toggle("Outline", isOn: Binding(
            get: { outline != nil },
            set: { outline = $0 ? (outline ?? WatermarkOutline()) : nil }))
            .accessibilityLabel("Watermark outline")
        if let current = outline {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                ColorField(title: "Outline color", color: Binding(
                    get: { current.color }, set: { outline?.color = $0 }))
                ValueSlider(title: "Width", value: Binding(
                    get: { current.width }, set: { outline?.width = $0 }), range: 0...20)
            }
            .padding(.leading, LadaGlass.Spacing.m)
        }
    }
}
