import Foundation
import ImageIO

/// The per-item values a text watermark's tokens draw on. Built from the header properties the load already
/// read, so it costs no extra decode.
public struct WatermarkTextContext: Equatable, Sendable {
    /// The source's name without its extension.
    public var fileName: String
    /// The source's name with its extension.
    public var fileNameWithExtension: String
    /// The date taken (EXIF, as a GMT wall clock), else the file's creation date (shifted the same way).
    public var date: Date?
    public var copyright: String?
    public var artist: String?

    public init(fileName: String, fileNameWithExtension: String, date: Date? = nil, copyright: String? = nil,
                artist: String? = nil) {
        self.fileName = fileName
        self.fileNameWithExtension = fileNameWithExtension
        self.date = date
        self.copyright = copyright
        self.artist = artist
    }

    /// The context for `source`. Copyright and artist come from the Metadata step when it is active and sets
    /// them (an empty value counts: it clears the field); else they are empty when the step removes them, and
    /// otherwise come from the source's EXIF/TIFF, IPTC or PNG fields.
    public static func make(source: URL, properties: [String: Any], metadata: MetadataOptions,
                            fileCreationDate: Date?) -> WatermarkTextContext {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        let step = metadata.isActive
        // Removing IPTC drops the whole IPTC dictionary (when not removing everything, which has its own keep list).
        let iptc = step && metadata.removeIPTC && !metadata.removeAll
            ? nil : properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        let sourceCopyright = text(tiff?[kCGImagePropertyTIFFCopyright as String])
            ?? text(iptc?[kCGImagePropertyIPTCCopyrightNotice as String])
            ?? text(png?[kCGImagePropertyPNGCopyright as String])
        let sourceArtist = text(tiff?[kCGImagePropertyTIFFArtist as String])
            ?? text(iptc?[kCGImagePropertyIPTCByline as String])
            ?? text(png?[kCGImagePropertyPNGAuthor as String])
        // Removal happens before setting: a value the step sets wins; a field it removes renders empty, so the
        // stripped author or copyright doesn't reappear in the pixels.
        let removesAll = step && metadata.removeAll
        let removesArtist = step && (metadata.removeAuthor && !metadata.removeAll
            || removesAll && !metadata.keepWhenRemovingAll.contains(.author))
        let removesCopyright = removesAll && !metadata.keepWhenRemovingAll.contains(.copyright)
        return WatermarkTextContext(
            fileName: source.deletingPathExtension().lastPathComponent,
            fileNameWithExtension: source.lastPathComponent,
            date: RenameContext.captureDate(properties: properties, fileCreationDate: fileCreationDate),
            copyright: (step ? metadata.copyright : nil) ?? (removesCopyright ? nil : sourceCopyright),
            artist: (step ? metadata.artist : nil) ?? (removesArtist ? nil : sourceArtist))
    }

    /// A string, or the first string of an array (IPTC Byline is a list); nil when empty.
    private static func text(_ value: Any?) -> String? {
        let string = (value as? String) ?? (value as? [Any])?.first as? String
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}

/// Renders a text watermark's tokens: `{filename}`, `{filename.ext}`, `{date}`, `{date:FORMAT}`, `{year}`,
/// `{copyright}`, `{artist}`. Unknown tokens stay as typed.
public enum WatermarkText {
    /// Longest rendered text, in characters.
    public static let maxLength = 200

    /// Every supported token, in menu order.
    public static let tokens = ["{filename}", "{filename.ext}", "{date}", "{date:yyyy-MM-dd}", "{year}",
                                "{copyright}", "{artist}"]

    /// True when `template` may contain a token (so a per-item context is worth building).
    public static func usesTokens(_ template: String) -> Bool {
        template.contains("{") && template.contains("}")
    }

    /// True when `template` uses a date token (so the file's creation date may be needed).
    static func usesDate(_ template: String) -> Bool {
        template.contains("{date") || template.contains("{year}")
    }

    public static func render(_ template: String, context: WatermarkTextContext) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            out += rest[..<open]
            let inner = String(rest[afterOpen..<close])
            out += value(of: inner, context: context) ?? "{\(inner)}"
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return clean(out)
    }

    /// Line breaks become spaces, control, bidi and zero-width characters are removed, the ends trimmed,
    /// and the result cut to `maxLength` characters.
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in TextWatermark.singleLine(text).unicodeScalars {
            if scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}" {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control, !invisible.contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) : trimmed
    }

    /// Bidi controls and zero-width characters.
    private static let invisible: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
        0x200E, 0x200F, 0x061C, 0x200B, 0x2060, 0xFEFF,
    ]

    /// The token's value, or nil for an unknown token (kept literal).
    private static func value(of token: String, context: WatermarkTextContext) -> String? {
        switch token {
        case "filename": return context.fileName
        case "filename.ext": return context.fileNameWithExtension
        case "date": return format(context.date, "yyyy-MM-dd")
        case "year": return format(context.date, "yyyy")
        case "copyright": return context.copyright ?? ""
        case "artist": return context.artist ?? ""
        default:
            guard token.hasPrefix("date:") else { return nil }
            let pattern = String(token.dropFirst("date:".count))
            guard RenameTemplate.isSafeDateFormat(pattern) else { return nil }
            return format(context.date, pattern)
        }
    }

    private static func format(_ date: Date?, _ pattern: String) -> String {
        guard let date else { return "" }
        return RenameTemplate.formatDate(date, pattern)
    }
}
