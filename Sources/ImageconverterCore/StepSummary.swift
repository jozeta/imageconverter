import Foundation

extension ImageOperation {
    /// One-line description of the step for the pipeline list.
    public var summary: String {
        switch self {
        case .resize(let options): return Self.summary(of: options)
        case .crop(let options): return Self.summary(of: options.mode) + " · " + options.anchor.displayName
        case .rotateFlip(let options): return Self.summary(of: options)
        case .canvas(let options): return Self.summary(of: options.mode)
        case .colorProfile(let profile): return profile.displayName
        case .adjust(let options): return options.summary
        case .watermark(let options): return options.summary
        }
    }

    private static func summary(of options: ResizeOptions) -> String {
        var parts = [summary(of: options.mode)]
        if options.resampling != .lanczos { parts.append(options.resampling.displayName.lowercased()) }
        // A physical size already names its DPI.
        var isPhysical = false
        if case .physical = options.mode { isPhysical = true }
        if !isPhysical, let dpi = options.effectiveDPI { parts.append("\(number(dpi)) dpi") }
        return parts.joined(separator: " · ")
    }

    // One case per mode keeps every summary in one place.
    // swiftlint:disable:next cyclomatic_complexity
    private static func summary(of mode: ResizeMode) -> String {
        switch mode {
        case .maxWidth(let width): return "max width \(width) px"
        case .maxHeight(let height): return "max height \(height) px"
        case .fitBox(let width, let height): return "fit \(width) × \(height)"
        case .exactWidth(let width): return "width \(width) px"
        case .exactHeight(let height): return "height \(height) px"
        case .exactSize(let width, let height, let fill): return "\(width) × \(height) · \(fill.summaryName)"
        case .percent(let percent): return "\(number(percent)) %"
        case .longestEdge(let edge): return "longest edge \(edge) px"
        case .shortestEdge(let edge): return "shortest edge \(edge) px"
        case .minimum(let width, let height): return "at least \(width) × \(height)"
        case .physical(let width, let height, let unit, let dpi):
            // Two sides fit inside the print size, keeping the aspect ratio.
            let side: (Double?) -> String = { $0.map { number($0) } ?? "auto" }
            return "\(side(width)) × \(side(height)) \(unit.displayName) at \(number(dpi)) dpi"
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

extension AdjustOptions {
    /// One-line description for the pipeline list: `exposure +20, contrast +10`, or `no changes`.
    public var summary: String {
        let parts = Field.allCases.compactMap { field -> String? in
            let value = Int(self[field].rounded())
            guard value != 0 else { return nil }
            // Signed fields show their sign (a real minus sign); 0…100 fields are plain amounts.
            let number = field.range.lowerBound < 0 ? (value > 0 ? "+\(value)" : "−\(-value)") : "\(value)"
            return field.displayName.lowercased() + " " + number + (field == .hue ? "°" : "")
        }
        return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
    }
}

extension RenameOptions {
    /// One-line description for the pipeline list: the pattern, plus the rule count when there are several.
    public var summary: String {
        let count = replacements.filter { !$0.find.isEmpty }.count
        return count > 1 ? "\(pattern) · \(count) replacements" : pattern
    }
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

private extension ExactFill {
    var summaryName: String {
        switch self {
        case .stretch: return "stretch"
        case .fitAndPad: return "pad"
        case .fillAndCrop: return "crop"
        }
    }
}
