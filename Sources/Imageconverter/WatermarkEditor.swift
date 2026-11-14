import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageconverterCore

/// Editor for the Watermark step: text (with tokens, shadow, outline) or image (raster or SVG), layout,
/// position, size, opacity, margin and rotation, plus templates.
struct WatermarkEditor: View {
    @Binding var options: WatermarkOptions
    @Environment(AppModel.self) private var model: AppModel?
    /// The text with its tokens filled in for the selected image (nil: no tokens, or nothing to show yet).
    @State private var liveText: String?
    /// The other kind's last values, kept while the editor is open.
    @State private var textValues = TextWatermark()
    @State private var imageValues = ImageWatermark()

    static let fonts: [(name: String, label: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"), ("Helvetica", "Helvetica"),
        ("AvenirNext-DemiBold", "Avenir Next Demi Bold"), ("Georgia-Bold", "Georgia Bold"),
        ("Menlo-Bold", "Menlo Bold"), (".SystemBold", "System bold")
    ]

    private var isText: Bool {
        if case .text = options.content { return true }
        return false
    }

    private var text: TextWatermark {
        if case .text(let value) = options.content { return value }
        return textValues
    }

    private var image: ImageWatermark {
        if case .image(let value) = options.content { return value }
        return imageValues
    }

    private func setKind(text useText: Bool) {
        switch options.content {
        case .text(let value): textValues = value
        case .image(let value): imageValues = value
        }
        if useText {
            options.content = .text(textValues)
            if options.sizePercent == WatermarkOptions.defaultImageSizePercent { options.sizePercent = WatermarkOptions.defaultSizePercent }
        } else {
            options.content = .image(imageValues)
            if options.sizePercent == WatermarkOptions.defaultSizePercent { options.sizePercent = WatermarkOptions.defaultImageSizePercent }
        }
    }

    private var isTiled: Bool {
        if case .tiled = options.layout { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Picker("Content", selection: Binding(get: { isText }, set: { setKind(text: $0) })) {
                    Text("Text").tag(true)
                    Text("Image").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Watermark content")
                WatermarkTemplatesMenu(options: $options)
            }
            if isText { textControls } else { imageControls }
            WatermarkLayoutControl(layout: $options.layout)
            HStack(alignment: .top, spacing: LadaGlass.Spacing.s) {
                Text("Position").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                AnchorPicker(anchor: $options.anchor)
            }
            // A tiled mark covers the whole image, so the anchor and margin don't apply.
            .disabled(isTiled)
            .opacity(isTiled ? 0.5 : 1)
            ValueSlider(title: "Size", value: $options.sizePercent, range: 1...100)
            ValueSlider(title: "Opacity", value: Binding(
                get: { options.opacity * 100 }, set: { options.opacity = $0 / 100 }), range: 0...100)
            ValueSlider(title: "Margin", value: $options.marginPercent, range: 0...25)
                .disabled(isTiled)
            WatermarkRotationControl(rotation: $options.rotation)
        }
    }

    private func updateText(_ change: (inout TextWatermark) -> Void) {
        var value = text
        change(&value)
        options.content = .text(value)
    }

    private func updateImage(_ change: (inout ImageWatermark) -> Void) {
        var value = image
        change(&value)
        options.content = .image(value)
    }

    /// What the live text depends on.
    private struct LiveTextKey: Equatable {
        let template: String
        let source: URL?
        let metadata: MetadataOptions?
    }

    private var liveTextKey: LiveTextKey {
        LiveTextKey(template: text.text, source: model?.watermarkSampleSource, metadata: model?.pipeline.metadata)
    }

    @ViewBuilder private var textControls: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            TextField("Text", text: Binding(get: { text.text }, set: { new in updateText { $0.text = new } }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Watermark text")
            Menu("Insert") {
                ForEach(WatermarkText.tokens, id: \.self) { token in
                    Button(token) { updateText { $0.text += token } }
                }
            }
            .fixedSize()
            .accessibilityLabel("Insert a token")
            .help("Insert a token that is filled in for each image")
        }
        if text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Empty text: nothing is drawn.").font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
        } else if WatermarkText.usesTokens(text.text) {
            liveTextLine
        }
        Picker("Font", selection: Binding(get: { text.fontName }, set: { new in updateText { $0.fontName = new } })) {
            ForEach(Self.fonts, id: \.name) { Text($0.label).tag($0.name) }
            if !Self.fonts.contains(where: { $0.name == text.fontName }) {
                Text(text.fontName).tag(text.fontName)
            }
        }
        .accessibilityLabel("Watermark font")
        ColorField(title: "Color", color: Binding(get: { text.color }, set: { new in updateText { $0.color = new } }))
        WatermarkShadowControl(shadow: Binding(get: { text.shadow }, set: { new in updateText { $0.shadow = new } }))
        WatermarkOutlineControl(outline: Binding(get: { text.outline }, set: { new in updateText { $0.outline = new } }))
    }

    /// "On this image: …" for the selected image, as the batch will draw it.
    @ViewBuilder private var liveTextLine: some View {
        Group {
            if model?.watermarkSampleSource == nil {
                Text("Add images to see the text for one.")
            } else if let liveText {
                Text("On this image: " + (liveText.isEmpty ? "(empty, nothing is drawn)" : liveText))
            } else {
                Text("On this image: …")
            }
        }
        .font(LadaGlass.Typography.label)
        .foregroundStyle(LadaGlass.Colors.muted)
        .lineLimit(2)
        .task(id: liveTextKey) {
            let key = liveTextKey
            guard let source = key.source else {
                liveText = nil
                return
            }
            let rendered = await AppModel.watermarkText(key.template, source: source,
                                                        metadata: key.metadata ?? MetadataOptions())
            guard !Task.isCancelled else { return }
            liveText = rendered
        }
    }

    @ViewBuilder private var imageControls: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Button("Choose image…") { chooseImage() }
                .help("PNG, JPEG, HEIC, TIFF, … or a plain SVG logo")
            if !image.path.isEmpty {
                Button("Remove") { updateImage { $0.path = "" } }
            }
        }
        WatermarkThumbnail(path: image.path)
        WatermarkShadowControl(shadow: Binding(get: { image.shadow }, set: { new in updateImage { $0.shadow = new } }))
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the watermark image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateImage { $0.path = url.path }
    }
}
