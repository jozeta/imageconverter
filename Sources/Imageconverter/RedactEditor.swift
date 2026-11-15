import SwiftUI
import ImageconverterCore

/// The Redact step: what to hide (faces, text, both), how (blur, pixelate, solid colour) and the padding.
struct RedactEditor: View {
    @Binding var options: RedactOptions

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Hide", selection: $options.target) {
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
            Text("Found on this Mac with Vision. Best effort: it can miss a face or some text, so check the results.")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
