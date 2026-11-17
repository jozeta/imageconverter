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
    public var focalLength: Double?
    public var aperture: Double?
    /// Shutter time in seconds.
    public var exposureTime: Double?
    /// What `{labels}` gives (the image's classification labels); nil where the token isn't offered (file names),
    /// so it stays literal there.
    public var labels: [String]?
    /// The source file's creation and modification dates (`{created}`, `{modified}`), as wall clocks stored as GMT.
    public var created: Date?
    public var modified: Date?
    /// The source file's own extension, lower-cased (`{srcext}`).
    public var sourceExtension = ""
    /// The name of the preset the batch runs (`{preset}`), if any.
    public var preset: String?
    /// What `{random}` and `{uuid}` are derived from (the source file's path): the same file gets the same value
    /// in the preview and in the batch.
    public var seed = ""

    public init(
        name: String, ext: String, format: String, folder: String, date: Date?,
        make: String?, model: String?, lens: String?, iso: Int?,
        width: Int, height: Int, counter: Int,
        focalLength: Double? = nil, aperture: Double? = nil, exposureTime: Double? = nil
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
        self.focalLength = focalLength
        self.aperture = aperture
        self.exposureTime = exposureTime
    }

    // swiftlint:disable function_parameter_count
    /// Builds a context from a source file and its header. The capture date is EXIF
    /// DateTimeOriginal (parsed as GMT, since EXIF has no time zone); otherwise the file's
    /// creation date, shifted so its GMT wall clock equals the wall clock in the user's time zone.
    /// `fileCreationDate` and `fileModificationDate` also give `{created}` and `{modified}`, shifted the same way.
    public static func make(
        source: URL, header: ImageHeader?, outputSize: (Int, Int), format: OutputFormat,
        counter: Int, fileCreationDate: Date?, fileModificationDate: Date? = nil
    ) -> RenameContext {
        let properties = header?.properties ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        let date = captureDate(properties: properties, fileCreationDate: fileCreationDate)

        var iso: Int?
        if let values = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any] {
            iso = (values.first as? NSNumber)?.intValue
        }

        var context = RenameContext(
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
            counter: counter,
            focalLength: (exif?[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue,
            aperture: (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,
            exposureTime: (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue)
        context.created = fileCreationDate.map(wallClock)
        context.modified = fileModificationDate.map(wallClock)
        context.sourceExtension = source.pathExtension.lowercased()
        context.seed = source.standardizedFileURL.path
        return context
    }
    // swiftlint:enable function_parameter_count

    /// `date` shifted so its GMT wall clock equals the wall clock in the user's time zone (file dates are instants;
    /// names show them as the Mac's clock showed them).
    static func wallClock(_ date: Date) -> Date {
        date.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: date)))
    }

    /// EXIF DateTimeOriginal (parsed as GMT, since EXIF has no time zone); otherwise the file's creation
    /// date, shifted so its GMT wall clock equals the wall clock in the user's time zone.
    static func captureDate(properties: [String: Any], fileCreationDate: Date?) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        if let raw = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "GMT")
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = parser.date(from: raw) { return date }
        }
        return fileCreationDate.map(wallClock)
    }
}

/// A file-name pattern such as `{date:yyyy-MM-dd}_{camera}_{counter:000}`.
public struct RenameTemplate: Equatable, Sendable {
    public static let maxLength = 200

    private enum Part: Equatable, Sendable {
        case literal(String)
        case token(name: String, arg: String?, raw: String)
    }

    static let knownTokens: Set<String> = [
        "name", "ext", "date", "time", "camera", "make", "lens", "iso",
        "width", "height", "format", "folder", "counter", "seq", "focal", "aperture", "shutter", "datetime",
        "created", "modified", "megapixels", "orientation", "srcext", "preset", "random", "uuid", labelsToken,
    ]

    /// Every supported token, in menu order (`tokenMenu` flattened, each once); formatted tokens carry an example
    /// argument.
    public static let tokenExamples: [String] = {
        var seen = Set<String>()
        return tokenMenu.flatMap(\.items).map(\.token).filter { seen.insert($0).inserted }
    }()

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

    private func uses(_ names: Set<String>) -> Bool {
        parts.contains { part in
            if case let .token(name, _, _) = part { return names.contains(name) }
            return false
        }
    }

    /// True when the pattern reads the image header (size, camera, lens, ISO or a capture date).
    public var needsHeader: Bool {
        uses(["date", "time", "datetime", "camera", "make", "lens", "iso", "width", "height", "focal", "aperture", "shutter",
              "megapixels", "orientation"])
    }

    /// True when the pattern uses a date or time (and so the file's creation date as a fallback), or the file's
    /// own creation or modification date.
    public var needsDate: Bool { uses(["date", "time", "datetime", "created", "modified"]) }

    /// True when the pattern uses `{labels}` (so the images must be analysed).
    public var usesLabels: Bool { uses([Self.labelsToken]) }

    /// Known only where the context offers it (condition subfolders and notes).
    static let labelsToken = "labels"

    private static func isKnown(_ name: String, _ context: RenameContext) -> Bool {
        knownTokens.contains(name) && (name != labelsToken || context.labels != nil)
    }

    /// Token names outside the supported list, in order of appearance. They render literally.
    public var unknownTokens: [String] {
        parts.compactMap { part in
            if case let .token(name, _, _) = part, !Self.knownTokens.contains(name) { return name }
            return nil
        }
    }

    /// The base name (no extension), sanitised; the context's own name if the result is empty.
    /// `transform` runs on the raw joined name before sanitising, so it cannot add unsafe characters.
    public func render(_ context: RenameContext, transform: (String) -> String = { $0 }) -> String {
        let cleaned = Self.sanitize(transform(joined(context)))
        if !cleaned.isEmpty { return cleaned }
        let fallback = Self.sanitize(context.name)
        return fallback.isEmpty ? "image" : fallback
    }

    /// One folder name: rendered and sanitised like a file name, but empty when nothing visible is left (no
    /// fall-back to the file's name).
    public func renderFolderName(_ context: RenameContext) -> String {
        Self.sanitize(joined(context))
    }

    /// Text for a report line: token values as they are (no file-name rules), control and format characters removed,
    /// at most `ConditionalAction.maxNoteLength` characters.
    public func renderText(_ context: RenameContext) -> String {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let text): out += text
            case let .token(name, arg, raw):
                out += Self.isKnown(name, context) ? Self.value(of: name, arg: arg, context: context) : raw
            }
        }
        // As for names: no control, bidi, zero-width or other format characters (metadata could spoof the report).
        let scalars = out.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
                && !Self.invisible.contains($0.value)
        }
        return String(String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(ConditionalAction.maxNoteLength))
    }

    /// The parts joined, each token value sanitised and separators next to empty values dropped.
    private func joined(_ context: RenameContext) -> String {
        var out = ""
        // How many characters at the end of `out` came from literal text (only those may be dropped).
        var literalTail = 0
        var dropNextSeparator = false
        for part in parts {
            switch part {
            case var .literal(text):
                if dropNextSeparator, let first = text.first, Self.separators.contains(first) {
                    text.removeFirst()
                }
                dropNextSeparator = false
                out += text
                literalTail += text.count
            case let .token(name, arg, raw):
                let value = Self.isKnown(name, context)
                    ? Self.sanitize(Self.value(of: name, arg: arg, context: context)) : raw
                if value.isEmpty {
                    if literalTail > 0, let last = out.last, Self.separators.contains(last) {
                        out.removeLast()
                        literalTail -= 1
                    } else if out.isEmpty {
                        // Nothing before it to separate from: drop the separator after it instead.
                        dropNextSeparator = true
                    }
                } else {
                    dropNextSeparator = false
                    out += value
                    literalTail = 0
                }
            }
        }
        return out
    }

    /// Date-field letters a user pattern may use (year, month, day, weekday, hour, minute, second, AM/PM).
    private static let dateLetters = Set("yMLdEeHhKkmsSa")
    /// Separators a user pattern may use besides those letters.
    private static let dateSeparators = Set(" -_.,/:")

    /// True for a short pattern made only of date-field letters and plain separators (no quoted text,
    /// time zones or other fields), at most 40 characters.
    static func isSafeDateFormat(_ pattern: String) -> Bool {
        !pattern.isEmpty && pattern.count <= 40
            && pattern.allSatisfy { dateLetters.contains($0) || dateSeparators.contains($0) }
    }

    private static let separators: Set<Character> = ["_", "-", " "]

    /// Scalars removed from names: bidi controls, zero-width and line/paragraph separators.
    private static let invisible: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
        0x200E, 0x200F, 0x061C, 0x200B, 0x2060, 0xFEFF, 0x2028, 0x2029,
    ]

    /// Longest name in UTF-8 bytes (APFS allows 255; leaves room for a suffix and extension).
    static let maxBytes = 240

    /// Makes untrusted text safe as a file name: no `/`, `:`, control, bidi or zero-width
    /// characters, no leading dots or edge separators, at most 200 characters and 240 bytes.
    /// Text with no visible character becomes empty.
    static func sanitize(_ text: String) -> String {
        var result = trim(cleanScalars(text))
        if result.count > maxLength { result = String(result.prefix(maxLength)) }
        while result.utf8.count > maxBytes { result.removeLast() }
        result = trim(result)
        let visible = result.unicodeScalars.contains {
            !$0.properties.isWhitespace && $0.properties.generalCategory != .format
        }
        return visible ? result : ""
    }

    /// `text` with `/` and `:` turned into `-` and control, bidi and zero-width characters removed (no trimming).
    static func cleanScalars(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                scalars.append("-")
            } else if scalar.properties.generalCategory != .control, !invisible.contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
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
