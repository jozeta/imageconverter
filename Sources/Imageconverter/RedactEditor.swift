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
            if options.style == .pixelate {
                RedactSizeRow(title: "Block size", value: $options.fixedBlockSize,
                              range: RedactOptions.blockSizeRange, start: RedactOptions.defaultFixedBlockSize,
                              autoHelp: "Auto: a third of each box's shorter side, so every box gets about three blocks.")
            } else if options.style == .blur {
                RedactSizeRow(title: "Strength", value: $options.fixedBlurRadius,
                              range: RedactOptions.blurRadiusRange, start: RedactOptions.defaultFixedBlurRadius,
                              autoHelp: "Auto: a blur radius of a third of each box's shorter side.")
            }
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

/// Auto or a fixed number of pixels (of the image as it arrives at the step) for Pixelate's blocks or Blur's radius.
private struct RedactSizeRow: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let start: Double
    let autoHelp: String

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .frame(width: 72, alignment: .leading)
                    .accessibilityHidden(true)
                Picker(title, selection: Binding(get: { value != nil },
                                                 set: { value = $0 ? (value ?? start) : nil })) {
                    Text("Auto").tag(false)
                    Text("Fixed").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(title)
            }
            if let fixed = value {
                HStack(spacing: LadaGlass.Spacing.s) {
                    Spacer().frame(width: 72)
                    Slider(value: Binding(get: { min(max(fixed, range.lowerBound), range.upperBound) },
                                          set: { value = $0.rounded() }), in: range)
                        .accessibilityLabel("\(title) in pixels")
                        .accessibilityValue("\(Int(fixed)) pixels")
                    Text("\(Int(fixed)) px").font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.text)
                        .frame(width: 52, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Text("In pixels of the image as it reaches this step. "
                     + "Small sizes are raised where needed so text and faces stay unreadable.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(autoHelp)
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
