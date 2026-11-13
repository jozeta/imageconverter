import Foundation
import ImageIO

/// The values a rename template can draw on for one output file.
public struct RenameContext: Sendable {
    public var name: String
    public var ext: String
    public var format: String
    public var folder: String
    public var date: Date?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Int?
    public var width: Int
    public var height: Int
    public var counter: Int

    public init(
        name: String, ext: String, format: String, folder: String, date: Date?,
        make: String?, model: String?, lens: String?, iso: Int?,
        width: Int, height: Int, counter: Int
    ) {
        self.name = name
        self.ext = ext
        self.format = format
        self.folder = folder
        self.date = date
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.width = width
        self.height = height
        self.counter = counter
    }

    // swiftlint:disable function_parameter_count
    /// Builds a context from a source file and its header. The capture date is EXIF
    /// DateTimeOriginal (parsed as GMT, since EXIF has no time zone); otherwise the file's
    /// creation date, shifted so its GMT wall clock equals the wall clock in the user's time zone.
    public static func make(
        source: URL, header: ImageHeader?, outputSize: (Int, Int), format: OutputFormat,
        counter: Int, fileCreationDate: Date?
    ) -> RenameContext {
        let properties = header?.properties ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        var date: Date?
        if let raw = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "GMT")
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            date = parser.date(from: raw)
        }
        if date == nil, let created = fileCreationDate {
            let offset = TimeZone.current.secondsFromGMT(for: created)
            date = created.addingTimeInterval(TimeInterval(offset))
        }

        var iso: Int?
        if let values = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any] {
            iso = (values.first as? NSNumber)?.intValue
        }

        return RenameContext(
            name: source.deletingPathExtension().lastPathComponent,
            ext: format.fileExtensions.first ?? "",
            format: format.displayName,
            folder: source.deletingLastPathComponent().lastPathComponent,
            date: date,
            make: tiff?[kCGImagePropertyTIFFMake as String] as? String,
            model: tiff?[kCGImagePropertyTIFFModel as String] as? String,
            lens: exif?[kCGImagePropertyExifLensModel as String] as? String,
            iso: iso,
            width: outputSize.0,
            height: outputSize.1,
            counter: counter)
    }
    // swiftlint:enable function_parameter_count
}

/// A file-name pattern such as `{date:yyyy-MM-dd}_{camera}_{counter:000}`.
public struct RenameTemplate: Equatable, Sendable {
    public static let maxLength = 200

    private enum Part: Equatable, Sendable {
        case literal(String)
        case token(name: String, arg: String?, raw: String)
    }

    private static let knownTokens: Set<String> = [
        "name", "ext", "date", "time", "camera", "make", "lens", "iso",
        "width", "height", "format", "folder", "counter",
    ]

    private let parts: [Part]

    public init(_ pattern: String) {
        var parts: [Part] = []
        var literal = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            literal += rest[..<open]
            let inner = rest[afterOpen..<close]
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
            let pieces = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0])
            let arg = pieces.count > 1 ? String(pieces[1]) : nil
            parts.append(.token(name: name, arg: arg, raw: "{\(inner)}"))
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        if !literal.isEmpty { parts.append(.literal(literal)) }
        self.parts = parts
    }

    /// Token names outside the supported list, in order of appearance. They render literally.
    public var unknownTokens: [String] {
        parts.compactMap { part in
            if case let .token(name, _, _) = part, !Self.knownTokens.contains(name) { return name }
            return nil
        }
    }

    /// The base name (no extension), sanitised; the context's own name if the result is empty.
    public func render(_ context: RenameContext) -> String {
        var out = ""
        for part in parts {
            switch part {
            case let .literal(text):
                out += text
            case let .token(name, arg, raw):
                if Self.knownTokens.contains(name) {
                    out += Self.sanitize(Self.value(of: name, arg: arg, context: context))
                } else {
                    out += raw
                }
            }
        }
        let cleaned = Self.sanitize(out)
        if !cleaned.isEmpty { return cleaned }
        let fallback = Self.sanitize(context.name)
        return fallback.isEmpty ? context.name : fallback
    }

    private static func value(of name: String, arg: String?, context: RenameContext) -> String {
        switch name {
        case "name": return context.name
        case "ext": return context.ext
        case "date": return format(context.date, arg, default: "yyyy-MM-dd")
        case "time": return format(context.date, arg, default: "HHmmss")
        case "counter":
            let text = String(max(context.counter, 0))
            let width = (arg?.allSatisfy { $0 == "0" } ?? false) ? (arg?.count ?? 0) : 0
            return String(repeating: "0", count: max(width - text.count, 0)) + text
        default: return metadataValue(of: name, context: context)
        }
    }

    private static func metadataValue(of name: String, context: RenameContext) -> String {
        switch name {
        case "camera": return context.model ?? ""
        case "make": return context.make ?? ""
        case "lens": return context.lens ?? ""
        case "iso": return context.iso.map(String.init) ?? ""
        case "width": return String(context.width)
        case "height": return String(context.height)
        case "format": return context.format
        case "folder": return context.folder
        default: return ""
        }
    }

    private static func format(_ date: Date?, _ arg: String?, default fallback: String) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = (arg?.isEmpty ?? true) ? fallback : arg
        return formatter.string(from: date)
    }

    private static let separators: Set<Character> = ["_", "-", " "]

    /// Makes untrusted text safe as a file name: no `/`, `:` or control characters, runs of
    /// separators collapsed, no leading dots or edge separators, at most 200 characters.
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                scalars.append("-")
            } else if scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        var collapsed: [Character] = []
        for char in String(scalars) {
            if separators.contains(char), let last = collapsed.last, separators.contains(last) { continue }
            collapsed.append(char)
        }
        var result = trim(String(collapsed))
        if result.count > maxLength { result = trim(String(result.prefix(maxLength))) }
        return result
    }

    private static func trim(_ text: String) -> String {
        var chars = Substring(text)
        var changed = true
        while changed {
            changed = false
            while let first = chars.first, separators.contains(first) || first == "." {
                chars = chars.dropFirst()
                changed = true
            }
            while let last = chars.last, separators.contains(last) {
                chars = chars.dropLast()
                changed = true
            }
        }
        return String(chars)
    }
}
