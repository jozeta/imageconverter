import Foundation

extension ImageOperation {
    /// One-line description of the step for the pipeline list.
    public var summary: String {
        switch self {
        case .resize(let options): return Self.summary(of: options.mode)
        case .crop(let options): return Self.summary(of: options.mode) + " · " + options.anchor.displayName
        case .rotateFlip(let options): return Self.summary(of: options)
        case .canvas(let options): return Self.summary(of: options.mode)
        case .colorProfile(let profile): return profile.displayName
        case .watermark(let options): return options.summary
        }
    }

    private static func summary(of mode: ResizeMode) -> String {
        switch mode {
        case .maxWidth(let width): return "max width \(width) px"
        case .maxHeight(let height): return "max height \(height) px"
        case .fitBox(let width, let height): return "fit \(width) × \(height)"
        case .exactWidth(let width): return "width \(width) px"
        case .exactHeight(let height): return "height \(height) px"
        case .exactSize(let width, let height, let fill):
            let fillName: String
            switch fill {
            case .stretch: fillName = "stretch"
            case .fitAndPad: fillName = "pad"
            case .fillAndCrop: fillName = "crop"
            }
            return "\(width) × \(height) · \(fillName)"
        }
    }

    private static func summary(of mode: CropMode) -> String {
        switch mode {
        case .size(let width, let height): return "\(width) × \(height) px"
        case .aspect(let width, let height): return "\(number(width)):\(number(height))"
        }
    }

    private static func summary(of options: RotateFlipOptions) -> String {
        var parts: [String] = []
        if options.rotation != .none { parts.append("\(options.rotation.rawValue)°") }
        switch (options.flipHorizontal, options.flipVertical) {
        case (true, true): parts.append("flip H+V")
        case (true, false): parts.append("flip H")
        case (false, true): parts.append("flip V")
        case (false, false): break
        }
        return parts.isEmpty ? "no change" : parts.joined(separator: " · ")
    }

    private static func summary(of mode: CanvasMode) -> String {
        switch mode {
        case .padding(let pixels): return "+\(pixels) px"
        case .paddingPercent(let percent): return "+\(number(percent)) %"
        case .size(let width, let height): return "\(width) × \(height)"
        }
    }

    /// Whole numbers without decimals, others with the minimal decimals.
    private static func number(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .precision(.fractionLength(0...2)).grouping(.never))
    }
}

extension MetadataOptions {
    /// One-line description for the pipeline list.
    public var summary: String {
        var text: String
        switch (removeAll, removeLocation, removeCamera) {
        case (true, _, _): text = "strip all"
        case (false, true, true): text = "strip location + camera"
        case (false, true, false): text = "strip location"
        case (false, false, true): text = "strip camera"
        case (false, false, false): text = "keep"
        }
        var fields: [String] = []
        if artist != nil { fields.append("artist") }
        if copyright != nil { fields.append("copyright") }
        if description != nil { fields.append("description") }
        if !fields.isEmpty { text += " · set " + fields.joined(separator: ", ") }
        return text
    }
}

extension RenameOptions {
    /// One-line description for the pipeline list: the pattern itself.
    public var summary: String { pattern }
}

extension WatermarkOptions {
    /// One-line description for the pipeline list: `© Johan · bottom right · 4 %`.
    public var summary: String {
        let name: String
        switch content {
        case .text(let watermark):
            let text = TextWatermark.singleLine(watermark.text)
            name = text.count > 20 ? String(text.prefix(20)) + "…" : text
        case .image(let watermark):
            name = watermark.path.isEmpty ? "no image" : URL(fileURLWithPath: watermark.path).lastPathComponent
        }
        let size = clampedSizePercent.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .precision(.fractionLength(0...2)).grouping(.never))
        return "\(name) · \(anchor.displayName) · \(size) %"
    }
}
