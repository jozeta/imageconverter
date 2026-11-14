import Foundation
import UniformTypeIdentifiers

/// What a condition checks about a source file. The first nine cases are saved exactly as before (so older
/// pipelines read the same); every case is answered from header-only facts (`ItemFacts`).
public enum ConditionCheck: Codable, Equatable, Sendable {
    case longestEdge(Comparison, Int)
    case width(Comparison, Int)
    case height(Comparison, Int)
    case fileSize(Comparison, bytes: Int)
    case format(FormatMatch)
    case hasTransparency(Bool)
    case orientation(Orientation)
    case hasGPS(Bool)
    /// Case-insensitive substring of the camera make or model.
    case camera(contains: String)

    // Name and location.
    /// The file name without its extension.
    case name(TextMatch)
    /// One of these extensions (no dots; `jpg` and `jpeg`, `tif` and `tiff` count as the same).
    case fileExtension([String])
    /// Case-insensitive substring of the folder's full path.
    case folder(contains: String)

    // Dates.
    case date(DateField, DateRule)

    // Metadata.
    case metadata(MetadataTest)

    // Image.
    case megapixels(Comparison, Double)
    case aspectRatio(AspectRule)
    case bitDepth(BitDepth)
    case colorSpace(ColorSpaceKind)
    /// The file embeds a color profile.
    case hasProfile
    /// Missing DPI counts as 72.
    case dpi(Comparison, Int)
    /// The EXIF orientation is anything but upright (rotated or mirrored).
    case isRotated
    /// More than one frame or page.
    case isAnimated

    public static let maxExtensions = 20
    public static let maxMegapixels = 1_000.0
    public static let maxDPI = 100_000

    public var isValid: Bool {
        switch self {
        case .longestEdge(_, let value), .width(_, let value), .height(_, let value):
            return (0...Condition.maxPixelValue).contains(value)
        case .fileSize(_, let bytes):
            return (0...Condition.maxBytesValue).contains(bytes)
        case .format(.format):
            return true
        case .format(.type(let identifier)):
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            return !identifier.isEmpty && identifier.count <= Condition.maxTextLength
                && identifier.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        case .camera(let text), .folder(let text):
            return Self.isValidText(text)
        case .name(let match):
            return Self.isValidText(match.text)
        case .fileExtension(let list):
            return !list.isEmpty && list.count <= Self.maxExtensions && list.allSatisfy(Self.isValidExtension)
        case .date(_, let rule):
            return rule.isValid
        case .metadata(let test):
            return test.isValid
        case .megapixels(_, let value):
            return value.isFinite && (0...Self.maxMegapixels).contains(value)
        case .aspectRatio(let rule):
            return rule.isValid
        case .dpi(_, let value):
            return (0...Self.maxDPI).contains(value)
        case .hasTransparency, .orientation, .hasGPS, .bitDepth, .colorSpace, .hasProfile, .isRotated, .isAnimated:
            return true
        }
    }

    private static func isValidText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.count <= Condition.maxTextLength
    }

    private static func isValidExtension(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 10 && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// `JPG`, `.jpeg` and `jpeg` are one extension; so are `tif` and `tiff`.
    static func normalizedExtension(_ text: String) -> String {
        var ext = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ext.hasPrefix(".") { ext.removeFirst() }
        switch ext {
        case "jpg", "jpe": return "jpeg"
        case "tif": return "tiff"
        default: return ext
        }
    }

    /// An extension list as typed (`jpg, png .heic`): split on commas and spaces, dots dropped, repeats removed.
    public static func extensions(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { piece in
            var ext = piece.lowercased()
            while ext.hasPrefix(".") { ext.removeFirst() }
            guard !ext.isEmpty, seen.insert(ext).inserted else { return nil }
            return ext
        }
    }

    public func matches(_ facts: ItemFacts) -> Bool {
        var timedOut = false
        return matches(facts, timedOut: &timedOut)
    }

    /// False when the value this check reads is missing from the file (presence checks always have a value).
    func hasValue(in facts: ItemFacts) -> Bool {
        switch self {
        case .date(let field, let rule): return rule == .exists || facts.date(field) != nil
        case .metadata(let test): return !test.operation.takesValue || !facts.values(of: test.subject).isEmpty
        case .camera: return facts.make != nil || facts.model != nil
        case .bitDepth: return facts.bitsPerComponent != nil
        case .colorSpace: return facts.colorModel != nil || facts.profileName != nil
        default: return true
        }
    }

    // One case per check keeps every test in one place.
    // swiftlint:disable cyclomatic_complexity
    /// As `matches`; `timedOut` is set when a name pattern was stopped (it then doesn't match).
    func matches(_ facts: ItemFacts, timedOut: inout Bool) -> Bool {
        switch self {
        case .longestEdge(let comparison, let value): return comparison.test(max(facts.width, facts.height), value)
        case .width(let comparison, let value): return comparison.test(facts.width, value)
        case .height(let comparison, let value): return comparison.test(facts.height, value)
        case .fileSize(let comparison, let bytes): return comparison.test(facts.fileSize, bytes)
        case .format(let match): return Self.matches(match, facts)
        case .hasTransparency(let wanted): return facts.hasAlpha == wanted
        case .orientation(let wanted): return Orientation(width: facts.width, height: facts.height) == wanted
        case .hasGPS(let wanted): return facts.hasGPS == wanted
        case .camera(let text): return Self.contains([facts.make, facts.model].compactMap { $0 }, text)
        case .name(let match): return match.matches(facts.fileName, timedOut: &timedOut)
        case .fileExtension(let list):
            let ext = Self.normalizedExtension(facts.fileExtension)
            return list.contains { Self.normalizedExtension($0) == ext }
        case .folder(let text): return Self.contains([facts.folderPath], text)
        case .date(let field, let rule): return rule.matches(facts.date(field), now: facts.now ?? Date())
        case .metadata(let test): return test.matches(facts.values(of: test.subject))
        default: return matchesImage(facts)
        }
    }
    // swiftlint:enable cyclomatic_complexity

    private func matchesImage(_ facts: ItemFacts) -> Bool {
        switch self {
        case .megapixels(let comparison, let value):
            return comparison.test(Double(facts.width) * Double(facts.height) / 1_000_000, value)
        case .aspectRatio(let rule): return rule.matches(width: facts.width, height: facts.height)
        case .bitDepth(let depth):
            if depth == .thirtyTwoFloat { return facts.isFloat || facts.bitsPerComponent == 32 }
            return !facts.isFloat && facts.bitsPerComponent == depth.rawValue
        case .colorSpace(let kind):
            return ColorSpaceKind(colorModel: facts.colorModel, profileName: facts.profileName) == kind
        case .hasProfile: return facts.profileName != nil
        case .dpi(let comparison, let value):
            // Untrusted headers: anything not a sane number counts as missing (72).
            let dpi = facts.dpi.flatMap { $0.isFinite && $0 >= 0 && $0 <= Double(Self.maxDPI) * 10 ? $0 : nil } ?? 72
            return comparison.test(Int(dpi.rounded()), value)
        case .isRotated: return facts.exifOrientation != 1
        case .isAnimated: return facts.frameCount > 1
        default: return false
        }
    }

    private static func matches(_ match: FormatMatch, _ facts: ItemFacts) -> Bool {
        switch match {
        case .format(let format): return facts.format == format
        case .type(let identifier):
            if facts.sourceType == identifier { return true }
            guard let source = UTType(facts.sourceType), let wanted = UTType(identifier) else { return false }
            return source.conforms(to: wanted)
        }
    }

    private static func contains(_ values: [String], _ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return values.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// What reading the facts must include for this check.
    var needs: FactNeeds {
        switch self {
        case .hasTransparency: return .alphaScan
        case .isAnimated: return .frames
        case .date(.taken, _): return .xmp
        case .metadata(let test): return test.subject.needsXMP ? .xmp : []
        default: return []
        }
    }
}
