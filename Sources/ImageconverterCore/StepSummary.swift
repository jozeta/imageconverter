import Foundation

extension ImageOperation {
    /// One-line description of the step for the pipeline list.
    public var summary: String {
        switch self {
        case .resize(let options): return Self.summary(of: options)
        case .crop(let options): return Self.summary(of: options.mode) + " · " + options.focus.displayName
        case .rotateFlip(let options): return Self.summary(of: options)
        case .redact(let options): return options.summary
        case .perspective(let options): return Self.summary(of: options)
        case .trim(let options): return Self.summary(of: options)
        case .canvas(let options): return Self.summary(of: options.mode)
        case .colorProfile(let profile): return profile.displayName
        case .adjust(let options): return options.summary
        case .watermark(let options): return options.summary
        case .condition(let conditional): return conditional.summary
        }
    }

    private static func summary(of options: ResizeOptions) -> String {
        var parts = [summary(of: options.mode)]
        if options.cropsToFill, options.focus != .default { parts.append(options.focus.displayName) }
        if options.resampling != .lanczos { parts.append(options.resampling.displayName.lowercased()) }
        // A physical size already names its DPI.
        if !options.mode.isPrintSize, let dpi = options.effectiveDPI { parts.append("\(number(dpi)) dpi") }
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
        case .printSheet(let long, let short, let unit, let dpi):
            return "print \(number(short)) × \(number(long)) \(unit.displayName) at \(number(dpi)) dpi"
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
        let angle = options.effectiveAngle
        if angle != 0 {
            let verb = options.angleFill == .cropToFit ? "straighten" : "rotate"
            parts.append("\(verb) \(signed(angle, plus: false))°")
        }
        return parts.isEmpty ? "no change" : parts.joined(separator: " · ")
    }

    private static func summary(of mode: CanvasMode) -> String {
        switch mode {
        case .padding(let pixels): return "+\(pixels) px"
        case .paddingPercent(let percent): return "+\(number(percent)) %"
        case .size(let width, let height): return "\(width) × \(height)"
        case .aspect(let width, let height): return "\(number(width)):\(number(height))"
        }
    }

    private static func summary(of options: PerspectiveOptions) -> String {
        var parts: [String] = []
        if options.auto { parts.append("auto") }
        let vertical = PerspectiveOptions.clamped(options.vertical)
        let horizontal = PerspectiveOptions.clamped(options.horizontal)
        if vertical != 0 { parts.append("vertical " + signed(vertical)) }
        if horizontal != 0 { parts.append("horizontal " + signed(horizontal)) }
        return parts.isEmpty ? "no change" : parts.joined(separator: " · ")
    }

    private static func summary(of options: TrimOptions) -> String {
        var parts: [String]
        switch options.mode {
        case .transparent: parts = ["transparent"]
        case .edgeColor: parts = ["edge color"]
        case .color(let color): parts = [hex(color)]
        }
        parts.append("\(number(TrimOptions.clampedTolerance(options.tolerance))) %")
        if options.padding > 0 { parts.append("+\(options.padding) px") }
        return parts.joined(separator: " · ")
    }

    /// `+20` / `−10` (a real minus sign); `plus: false` leaves positive numbers bare.
    private static func signed(_ value: Double, plus: Bool = true) -> String {
        if value < 0 { return "−" + number(-value) }
        return (plus ? "+" : "") + number(value)
    }

    private static func hex(_ color: RGBAColor) -> String {
        let byte: (Double) -> Int = { Int((($0.isFinite ? min(1, max(0, $0)) : 0) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
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
        var text = removalSummary
        var fields: [String] = []
        if artist != nil { fields.append("artist") }
        if copyright != nil { fields.append("copyright") }
        if description != nil { fields.append("description") }
        if title != nil { fields.append("title") }
        if keywords != nil { fields.append("keywords") }
        if case .set = location { fields.append("GPS") }
        switch dateTaken {
        case .keep: break
        case .set: fields.append("date")
        case .shift: fields.append("shifted date")
        }
        if !custom.isEmpty { fields.append(custom.count == 1 ? "1 field" : "\(custom.count) fields") }
        if setFileDates { fields.append("file dates") }
        if !fields.isEmpty { text += " · set " + fields.joined(separator: ", ") }
        return text
    }

    private var removalSummary: String {
        if removeAll {
            // Orientation and colour profile always survive, so they aren't worth mentioning.
            let names: [KeepField: String] = [.copyright: "copyright", .author: "author", .dateTaken: "date",
                                              .cameraInfo: "camera", .location: "location"]
            let kept = KeepField.allCases.filter(keepWhenRemovingAll.contains).compactMap { names[$0] }
            return kept.isEmpty ? "strip all" : "strip all except " + kept.joined(separator: ", ")
        }
        let parts = [(location == .remove, "location"), (removeCamera, "camera"), (removeAuthor, "author"),
                     (removeThumbnail, "thumbnail"), (removeIPTC, "IPTC"), (removeXMP, "XMP")]
            .filter(\.0).map(\.1)
        return parts.isEmpty ? "keep" : "strip " + parts.joined(separator: " + ")
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
        var parts = [pattern]
        if count > 1 { parts.append("\(count) replacements") }
        if caseStyle != .keep { parts.append("\(caseStyle.rawValue) case") }
        return parts.joined(separator: " · ")
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
