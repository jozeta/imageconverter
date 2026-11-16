import Foundation
import ImageIO

// MARK: Text

extension MetadataInspection {
    /// Untrusted text made safe to show: control characters, bidirectional overrides and other invisible
    /// formatting characters become visible `<U+XXXX>` escapes (tabs and line breaks too), cut to `maxValueLength`.
    public static func display(_ text: String, limit: Int = maxValueLength) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            let hidden = category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .privateUse || category == .surrogate
            let piece = hidden ? String(format: "<U+%04X>", scalar.value).unicodeScalars : String(scalar).unicodeScalars
            if count + piece.count > limit {
                out.append(contentsOf: "…".unicodeScalars)
                break
            }
            out.append(contentsOf: piece)
            count += piece.count
        }
        return String(out)
    }

    /// A property value as text: lists joined with commas (at most 200 items), nested dictionaries as
    /// `key: value` pairs, data as its size.
    static func text(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let data as Data: return "\(data.count) bytes of data"
        case let list as [Any]:
            let shown = list.prefix(maxListItems).map(text).joined(separator: ", ")
            return list.count > maxListItems ? shown + ", … (\(list.count) items)" : shown
        case let dict as [String: Any]:
            return dict.sorted { $0.key < $1.key }.prefix(maxListItems).map { "\($0.key): \(text($0.value))" }
                .joined(separator: "; ")
        default: return String(describing: value)
        }
    }

    static func strings(_ value: Any) -> [String] {
        if let list = value as? [Any] { return list.prefix(maxListItems).map(text) }
        return [text(value)]
    }

    /// An XMP tag's value: text, lists joined with commas, structures as `name: value` pairs.
    static func xmpText(_ tag: CGImageMetadataTag) -> String {
        switch CGImageMetadataTagCopyValue(tag) {
        case let text as String: return text
        case let items as [CGImageMetadataTag]:
            let shown = items.prefix(maxListItems).map(xmpText).joined(separator: ", ")
            return items.count > maxListItems ? shown + ", … (\(items.count) items)" : shown
        case let fields as [String: CGImageMetadataTag]:
            return fields.sorted { $0.key < $1.key }.prefix(maxListItems).map { "\($0.key): \(xmpText($0.value))" }
                .joined(separator: "; ")
        case let other?: return "\(other)"
        case nil: return ""
        }
    }

    static func xmpStrings(_ tag: CGImageMetadataTag) -> [String] {
        if let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
            return items.prefix(maxListItems).map(xmpText)
        }
        return [xmpText(tag)]
    }

    /// A key as words: "BodySerialNumber" → "Body Serial Number"; a few well-known names read better.
    static func label(_ key: String) -> String {
        if let known = knownLabels[key] { return known }
        var words = ""
        var previous: Character?
        for character in key {
            if let last = previous, character.isUppercase, last.isLowercase || last.isNumber { words.append(" ") }
            words.append(character)
            previous = character
        }
        return words
    }

    private static let knownLabels: [String: String] = [
        kCGImagePropertyExifDateTimeOriginal as String: "Date taken",
        kCGImagePropertyExifDateTimeDigitized as String: "Date digitized",
        kCGImagePropertyTIFFDateTime as String: "Date modified",
        kCGImagePropertyIPTCObjectName as String: "Title",
        kCGImagePropertyIPTCCaptionAbstract as String: "Description",
        kCGImagePropertyIPTCByline as String: "Byline",
        kCGImagePropertyTIFFImageDescription as String: "Description",
        kCGImagePropertyExifFNumber as String: "F-number",
        kCGImagePropertyExifISOSpeedRatings as String: "ISO",
        kCGImagePropertyDPIWidth as String: "DPI (width)",
        kCGImagePropertyDPIHeight as String: "DPI (height)",
    ]
}
