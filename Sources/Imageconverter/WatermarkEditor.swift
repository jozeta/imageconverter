import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ImageconverterCore

/// Editor for the Watermark step: text or image, position, size, opacity and margin.
struct WatermarkEditor: View {
    @Binding var options: WatermarkOptions
    /// The other kind's last values, kept while the editor is open.
    @State private var textValues = TextWatermark()
    @State private var imageValues = ImageWatermark()

    private static let sizeDefaultImage = 20.0
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
            if options.sizePercent == Self.sizeDefaultImage { options.sizePercent = WatermarkOptions.defaultSizePercent }
        } else {
            options.content = .image(imageValues)
            if options.sizePercent == WatermarkOptions.defaultSizePercent { options.sizePercent = Self.sizeDefaultImage }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Content", selection: Binding(get: { isText }, set: { setKind(text: $0) })) {
                Text("Text").tag(true)
                Text("Image").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Watermark content")
            if isText { textControls } else { imageControls }
            HStack(alignment: .top, spacing: LadaGlass.Spacing.m) {
                Text("Position").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                AnchorPicker(anchor: $options.anchor)
            }
            PercentSlider(title: "Size", value: $options.sizePercent, range: 1...100)
            PercentSlider(title: "Opacity", value: Binding(
                get: { options.opacity * 100 }, set: { options.opacity = $0 / 100 }), range: 0...100)
            PercentSlider(title: "Margin", value: $options.marginPercent, range: 0...25)
        }
    }

    @ViewBuilder private var textControls: some View {
        TextField("Text", text: Binding(
            get: { text.text },
            set: { var value = text; value.text = $0; options.content = .text(value) }))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Watermark text")
        Picker("Font", selection: Binding(
            get: { text.fontName },
            set: { var value = text; value.fontName = $0; options.content = .text(value) })) {
            ForEach(Self.fonts, id: \.name) { Text($0.label).tag($0.name) }
            if !Self.fonts.contains(where: { $0.name == text.fontName }) {
                Text(text.fontName).tag(text.fontName)
            }
        }
        .accessibilityLabel("Watermark font")
        ColorField(title: "Color", color: Binding(
            get: { text.color },
            set: { var value = text; value.color = $0; options.content = .text(value) }))
    }

    @ViewBuilder private var imageControls: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Button("Choose image…") { chooseImage() }
            if !image.path.isEmpty {
                Button("Remove") { options.content = .image(ImageWatermark()) }
            }
        }
        WatermarkThumbnail(path: image.path)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the watermark image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        options.content = .image(ImageWatermark(path: url.path))
    }
}

/// A slider with its value as text and as the accessibility value.
private struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var shown: Int { value.isFinite ? Int(min(max(value, range.lowerBound), range.upperBound).rounded()) : 0 }

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Text(title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(
                get: { value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound },
                set: { value = $0.rounded() }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(shown) %")
            Text("\(shown) %").font(LadaGlass.Typography.mono).foregroundStyle(LadaGlass.Colors.text)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// The chosen file's name with a small thumbnail, loaded off the main actor.
private struct WatermarkThumbnail: View {
    let path: String
    @State private var thumbnail: NSImage?
    @State private var unreadable = false

    var body: some View {
        if path.isEmpty {
            Text("No image chosen").font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.warnText)
        } else {
            HStack(spacing: LadaGlass.Spacing.s) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                if unreadable {
                    Text("Can't read this image").font(LadaGlass.Typography.body)
                        .foregroundStyle(LadaGlass.Colors.warnText)
                } else {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(LadaGlass.Typography.body)
                        .foregroundStyle(LadaGlass.Colors.text).lineLimit(1).truncationMode(.middle)
                }
            }
            .task(id: path) {
                thumbnail = nil
                unreadable = false
                let loaded = await Self.loadThumbnail(path: path)
                thumbnail = loaded
                unreadable = loaded == nil
            }
        }
    }

    private static func loadThumbnail(path: String) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}
