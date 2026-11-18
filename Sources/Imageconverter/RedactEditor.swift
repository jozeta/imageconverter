import SwiftUI
import ImageconverterCore

/// The Redact step: what to hide (faces, text, both), how (blur, pixelate, solid colour), the block size or blur
/// strength, and the padding.
struct RedactEditor: View {
    @Binding var options: RedactOptions

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            // The style follows the target's default (a solid colour for text) unless another one was chosen.
            Picker("Hide", selection: Binding(get: { options.target }, set: { options = options.retargeted($0) })) {
                ForEach(RedactTarget.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("What to hide")
            Picker("Style", selection: $options.style) {
                ForEach(RedactStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Redact style")
            if options.style == .fill {
                // Always drawn fully opaque, so the colour picker has no opacity.
                ColorPicker("Fill colour", selection: Binding(
                    get: {
                        Color(.sRGB, red: options.fillColor.red, green: options.fillColor.green,
                              blue: options.fillColor.blue, opacity: 1)
                    },
                    set: {
                        var color = ColorField.rgba(from: $0)
                        color.alpha = 1
                        options.fillColor = color
                    }), supportsOpacity: false)
                    .accessibilityLabel("Fill colour")
            }
            if options.style != .fill { RedactSizeRow(options: $options) }
            HStack(spacing: LadaGlass.Spacing.s) {
                Text("Padding").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .frame(width: 72, alignment: .leading)
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { options.clampedPadding }, set: { options.padding = $0.rounded() }),
                       in: RedactOptions.paddingRange)
                    .accessibilityLabel("Padding")
                    .accessibilityValue("\(Int(options.clampedPadding)) percent")
                Text("\(Int(options.clampedPadding))%").font(LadaGlass.Typography.mono)
                    .foregroundStyle(LadaGlass.Colors.text)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            if options.target.includesText {
                Text(Redaction.textAdvice)
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Found on this Mac with Vision. Best effort: it can miss a face or some text, so check the results. "
                 + "If Vision can't run, the image isn't written.")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pixelate's "Blocks across" (Coarse 2 … Fine 5) or Blur's "Strength" (Light 5 … Strong 2): parts of each area's
/// shorter side, so every position changes the result on any image size. Double-click: Auto (3). A step saved with
/// a pixel size keeps it until the slider is moved.
private struct RedactSizeRow: View {
    @Binding var options: RedactOptions

    private var pixelate: Bool { options.style == .pixelate }
    private var title: String { pixelate ? "Blocks across" : "Strength" }
    /// Pixelate: the slider is N (Coarse 2 on the left). Blur: Light (N = 5) on the left, so the position is 7 − N.
    private func position(_ across: Int) -> Int {
        pixelate ? across : RedactOptions.acrossRange.lowerBound + RedactOptions.acrossRange.upperBound - across
    }

    private var isAuto: Bool {
        options.legacyPixels == nil && (pixelate ? options.clampedBlocksAcross : options.clampedBlurAcross) == nil
    }

    private var valueText: String {
        if let pixels = options.legacyPixels { return "\(Int(pixels)) px" }
        if isAuto { return "Auto" }
        return pixelate ? "\(options.across)" : "1/\(options.across)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.s) {
                // "Blocks across" wraps onto two lines rather than being cut in the 72 pt label column.
                Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 72, alignment: .leading)
                    .accessibilityHidden(true)
                Text(pixelate ? "Coarse" : "Light").font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .accessibilityHidden(true)
                AdjustSliderControl(
                    value: Binding(get: { Double(position(options.across)) },
                                   set: { options = options.withAcross(position(Int($0.rounded()))) }),
                    range: Double(RedactOptions.acrossRange.lowerBound)...Double(RedactOptions.acrossRange.upperBound),
                    resetValue: Double(position(RedactOptions.autoAcross)),
                    stops: RedactOptions.acrossRange.count)
                    .accessibilityLabel(title)
                    .accessibilityValue(accessibilityValue)
                Text(pixelate ? "Fine" : "Strong").font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .accessibilityHidden(true)
                Text(valueText).font(LadaGlass.Typography.mono)
                    .foregroundStyle(LadaGlass.Colors.text)
                    .frame(width: 52, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .help(help)
            Text(note)
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityValue: String {
        if let pixels = options.legacyPixels { return "Saved as \(Int(pixels)) pixels" }
        let across = options.across
        let parts = [2: "half", 3: "third", 4: "quarter", 5: "fifth"][across] ?? "\(across)th"
        let value = pixelate ? "\(across) blocks across" : "radius one \(parts) of each area"
        return (isAuto ? "Auto, " : "") + value
    }

    private var note: String {
        if let pixels = options.legacyPixels { return "Saved as \(Int(pixels)) px; move the slider to switch." }
        return isAuto
            ? (pixelate ? "Auto: about three blocks across each area's shorter side."
                        : "Auto: a blur radius of a third of each area's shorter side.")
            : (pixelate ? "\(options.across) blocks across each area's shorter side."
                        : "A blur radius of 1/\(options.across) of each area's shorter side.")
    }

    private var help: String {
        pixelate
            ? "How many blocks span each hidden area's shorter side: 2 (coarse) to 5 (fine). Never finer than 5, "
                + "so faces and text stay unreadable. Double-click for Auto (3)."
            : "How strongly each hidden area is blurred: a radius of 1/5 (light) to 1/2 (strong) of its shorter side. "
                + "Never lighter than 1/5, so faces and text stay unreadable. Double-click for Auto (1/3)."
    }
}
