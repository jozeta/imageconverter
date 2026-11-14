import Foundation

/// How a text condition compares a name (or a metadata value) with its text.
public enum TextOperation: String, Codable, CaseIterable, Sendable {
    case contains, startsWith, endsWith, equals, matchesRegex

    /// In words, as the editor and the step summary show it ("starts with").
    public var phrase: String {
        switch self {
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .equals: return "is"
        case .matchesRegex: return "matches the pattern"
        }
    }

    /// The negative form ("does not start with").
    public var negatedPhrase: String {
        switch self {
        case .contains: return "does not contain"
        case .startsWith: return "does not start with"
        case .endsWith: return "does not end with"
        case .equals: return "is not"
        case .matchesRegex: return "does not match the pattern"
        }
    }
}

/// A text test: `name starts with "IMG_"`. Case is ignored unless `ignoresCase` is off. A regular expression
/// that doesn't compile never matches (the editor shows why).
public struct TextMatch: Codable, Equatable, Sendable {
    public var operation: TextOperation
    public var text: String
    public var ignoresCase: Bool

    public init(_ operation: TextOperation = .contains, _ text: String, ignoresCase: Bool = true) {
        self.operation = operation
        self.text = text
        self.ignoresCase = ignoresCase
    }

    private enum CodingKeys: String, CodingKey { case operation, text, ignoresCase }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(TextOperation.self, forKey: .operation)
        text = try container.decode(String.self, forKey: .text)
        ignoresCase = try container.decodeIfPresent(Bool.self, forKey: .ignoresCase) ?? true
    }

    /// The editor's message for an invalid regular expression; nil when the text is fine.
    public var regexError: String? {
        guard operation == .matchesRegex else { return nil }
        return (try? NSRegularExpression(pattern: text)) == nil ? "Invalid regular expression" : nil
    }

    public func matches(_ value: String) -> Bool {
        guard !text.isEmpty else { return false }
        if operation == .matchesRegex {
            let options: NSRegularExpression.Options = ignoresCase ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: text, options: options) else { return false }
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        let options: String.CompareOptions = ignoresCase ? [.caseInsensitive, .diacriticInsensitive] : []
        switch operation {
        case .contains: return value.range(of: text, options: options) != nil
        case .startsWith: return value.range(of: text, options: options.union(.anchored)) != nil
        case .endsWith: return value.range(of: text, options: options.union([.anchored, .backwards])) != nil
        case .equals: return value.compare(text, options: options) == .orderedSame
        case .matchesRegex: return false
        }
    }
}

/// Which of a file's dates a date condition reads.
public enum DateField: String, Codable, CaseIterable, Sendable {
    /// EXIF DateTimeOriginal, then the XMP date created; none when neither is there (never the file's dates).
    case taken
    case created
    case modified

    public var displayName: String {
        switch self {
        case .taken: return "date taken"
        case .created: return "file created"
        case .modified: return "file modified"
        }
    }
}

/// A calendar day, compared in the Mac's own time zone.
public struct CalendarDay: Codable, Equatable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = CalendarDay.calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public static let years = 1800...9999

    /// Gregorian, in the Mac's time zone.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// True for a real day (no 31 February) in 1800...9999.
    public var isValid: Bool {
        guard Self.years.contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        let calendar = Self.calendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        return CalendarDay(date, calendar: calendar) == self
    }

    /// Midnight at the start of the day.
    public var date: Date? {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// `2026-11-14`.
    public var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// What a date condition asks about the date.
public enum DateRule: Codable, Equatable, Sendable {
    /// The file has this date at all (only date taken can be missing).
    case exists
    case before(CalendarDay)
    case after(CalendarDay)
    /// Both days included.
    case between(CalendarDay, CalendarDay)
    case withinLastDays(Int)
    case inYear(Int)
    /// 1...12, in any year.
    case inMonth(Int)

    public static let maxDays = 36_500

    public var isValid: Bool {
        switch self {
        case .exists: return true
        case .before(let day), .after(let day): return day.isValid
        case .between(let from, let until): return from.isValid && until.isValid
        case .withinLastDays(let days): return (1...Self.maxDays).contains(days)
        case .inYear(let year): return CalendarDay.years.contains(year)
        case .inMonth(let month): return (1...12).contains(month)
        }
    }

    /// Whether `date` passes; a missing date passes nothing.
    public func matches(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let day = CalendarDay(date)
        switch self {
        case .exists: return true
        case .before(let limit): return day < limit
        case .after(let limit): return day > limit
        case .between(let from, let until): return min(from, until) <= day && day <= max(from, until)
        case .withinLastDays(let days):
            return date <= now && date >= now.addingTimeInterval(-Double(days) * 86_400)
        case .inYear(let year): return day.year == year
        case .inMonth(let month): return day.month == month
        }
    }
}

/// An aspect-ratio test (width divided by height).
public enum AspectRule: Codable, Equatable, Sendable {
    case widerThan(Double)
    case tallerThan(Double)
    /// Within 1 % of square.
    case square

    public var isValid: Bool {
        switch self {
        case .widerThan(let ratio), .tallerThan(let ratio): return ratio.isFinite && (0.01...100).contains(ratio)
        case .square: return true
        }
    }

    public func matches(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        switch self {
        case .widerThan(let limit): return ratio > limit
        case .tallerThan(let limit): return 1 / ratio > limit
        case .square: return abs(ratio - 1) <= 0.01
        }
    }
}

/// Bits per color channel.
public enum BitDepth: Int, Codable, CaseIterable, Sendable {
    case eight = 8, sixteen = 16, thirtyTwoFloat = 32

    public var displayName: String { self == .thirtyTwoFloat ? "32-bit float" : "\(rawValue)-bit" }
}

/// The color space a file declares (its embedded profile, or its color model).
public enum ColorSpaceKind: String, Codable, CaseIterable, Sendable {
    case sRGB, displayP3, adobeRGB, gray, cmyk, other

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB"
        case .gray: return "Gray"
        case .cmyk: return "CMYK"
        case .other: return "another color space"
        }
    }

    /// From the header's color model and profile name. RGB without a profile counts as sRGB (what apps assume).
    public init(colorModel: String?, profileName: String?) {
        switch colorModel?.lowercased() {
        case "gray": self = .gray
        case "cmyk": self = .cmyk
        case "rgb", nil:
            guard let name = profileName?.lowercased() else {
                self = colorModel == nil ? .other : .sRGB
                return
            }
            self = Self.rgbProfiles.first { name.contains($0.fragment) }?.kind ?? .other
        default: self = .other
        }
    }

    private static let rgbProfiles: [(fragment: String, kind: ColorSpaceKind)] = [
        ("srgb", .sRGB), ("p3", .displayP3), ("adobe rgb", .adobeRGB),
    ]
}
