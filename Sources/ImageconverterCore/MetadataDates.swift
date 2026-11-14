import Foundation
import ImageIO

/// Date-taken editing for the Metadata step. Dates in EXIF, IPTC and XMP are wall-clock times; shifts
/// are done on the wall time (in UTC, so no daylight-saving jumps) and keep any suffix (sub-seconds,
/// time-zone) the field had.
enum MetadataDates {
    private static let exifKey = kCGImagePropertyExifDictionary as String
    private static let tiffKey = kCGImagePropertyTIFFDictionary as String
    private static let iptcKey = kCGImagePropertyIPTCDictionary as String

    static let exifDateKeys: [String] = [
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized
    ].map { $0 as String }
    /// Everything "date taken" covers in EXIF (kept together by "keep date taken").
    static let exifDateFamily: [String] = exifDateKeys + [
        kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
        kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifSubsecTimeDigitized
    ].map { $0 as String }
    static let iptcDateFamily: [String] = [
        kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated, kCGImagePropertyIPTCDigitalCreationDate,
        kCGImagePropertyIPTCDigitalCreationTime
    ].map { $0 as String }
    /// xmp:ModifyDate is where ImageIO keeps the TIFF DateTime when a file has XMP.
    static let xmpPaths = ["xmp:CreateDate", "photoshop:DateCreated", "xmp:ModifyDate"]

    /// Formatters are costly to make and a batch asks for the same few over and over; DateFormatter is
    /// thread-safe (macOS 10.9+), so one per format and zone is shared by every worker.
    private static let formatters = FormatterCache()

    private static func formatter(_ format: String, zone: TimeZone = TimeZone(identifier: "UTC")!) -> DateFormatter {
        formatters.formatter(format, zone: zone)
    }

    private static let exifFormat = "yyyy:MM:dd HH:mm:ss"
    private static let xmpFormat = "yyyy-MM-dd'T'HH:mm:ss"

    /// Moves a date string of `format` (the first `format`-length characters) by `seconds`, keeping the rest.
    private static func shifted(_ text: String, format: String, length: Int, by seconds: Int) -> String? {
        guard text.count >= length else { return nil }
        let head = String(text.prefix(length))
        let utc = formatter(format)
        guard let date = utc.date(from: head) else { return nil }
        return utc.string(from: date.addingTimeInterval(TimeInterval(seconds))) + text.dropFirst(length)
    }

    /// The time zone the file records for its date taken, or the Mac's.
    static func zone(of properties: [String: Any]) -> TimeZone {
        let exif = properties[exifKey] as? [String: Any]
        guard let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
                ?? exif?[kCGImagePropertyExifOffsetTime as String] as? String else { return .current }
        let parts = offset.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              abs(hours) <= 14, (0..<60).contains(minutes) else { return .current }
        let sign = offset.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: hours * 3600 + sign * minutes * 60) ?? .current
    }

    /// Applies `edit` to the EXIF, TIFF and IPTC dates in `props`.
    static func apply(_ edit: DateEdit, to props: inout [String: Any]) {
        switch edit {
        case .keep: return
        case .set(let date):
            let zone = zone(of: props)
            let exifText = formatter(exifFormat, zone: zone).string(from: date)
            var exif = props[exifKey] as? [String: Any] ?? [:]
            for key in exifDateKeys { exif[key] = exifText }
            props[exifKey] = exif
            var tiff = props[tiffKey] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFDateTime as String] = exifText
            props[tiffKey] = tiff
            var iptc = props[iptcKey] as? [String: Any] ?? [:]
            iptc[kCGImagePropertyIPTCDateCreated as String] = formatter("yyyyMMdd", zone: zone).string(from: date)
            iptc[kCGImagePropertyIPTCTimeCreated as String] = formatter("HHmmss", zone: zone).string(from: date)
            props[iptcKey] = iptc
        case .shift(let seconds):
            shiftEXIF(by: seconds, in: &props)
            shiftIPTC(by: seconds, in: &props)
        }
    }

    private static func shiftEXIF(by seconds: Int, in props: inout [String: Any]) {
        let length = exifFormat.count
        if var exif = props[exifKey] as? [String: Any] {
            for key in exifDateKeys {
                guard let text = exif[key] as? String else { continue }
                exif[key] = shifted(text, format: exifFormat, length: length, by: seconds) ?? text
            }
            props[exifKey] = exif
        }
        if var tiff = props[tiffKey] as? [String: Any], let text = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            tiff[kCGImagePropertyTIFFDateTime as String] = shifted(text, format: exifFormat, length: length, by: seconds)
                ?? text
            props[tiffKey] = tiff
        }
    }

    /// IPTC keeps the date and time apart (`yyyyMMdd`, `HHmmss` plus an optional offset); a date without a
    /// time moves by whole days only.
    private static func shiftIPTC(by seconds: Int, in props: inout [String: Any]) {
        guard var iptc = props[iptcKey] as? [String: Any] else { return }
        let pairs = [(kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated),
                     (kCGImagePropertyIPTCDigitalCreationDate, kCGImagePropertyIPTCDigitalCreationTime)]
        for (dateKey, timeKey) in pairs {
            guard let date = iptc[dateKey as String] as? String, date.count == 8 else { continue }
            if let time = iptc[timeKey as String] as? String, time.count >= 6,
               let moved = shifted(date + time, format: "yyyyMMddHHmmss", length: 14, by: seconds) {
                iptc[dateKey as String] = String(moved.prefix(8))
                iptc[timeKey as String] = String(moved.dropFirst(8))
            } else if let moved = shifted(date, format: "yyyyMMdd", length: 8, by: seconds / 86_400 * 86_400) {
                iptc[dateKey as String] = moved
            }
        }
        props[iptcKey] = iptc
    }

    /// The XMP text for `edit`, given the field's current text (nil when it has none).
    static func xmpValue(_ edit: DateEdit, current: String?, zone: TimeZone) -> String? {
        switch edit {
        case .keep: return current
        case .set(let date): return formatter(xmpFormat, zone: zone).string(from: date)
        case .shift(let seconds):
            guard let current else { return nil }
            for (format, length) in [(xmpFormat, 19), ("yyyy-MM-dd'T'HH:mm", 16)] {
                if let moved = shifted(current, format: format, length: length, by: seconds) { return moved }
            }
            return shifted(current, format: "yyyy-MM-dd", length: 10, by: seconds / 86_400 * 86_400) ?? current
        }
    }

    /// `properties` with the TIFF DateTime taken from xmp:ModifyDate when only XMP has it: ImageIO reads it
    /// from there for files with an XMP packet but doesn't write xmp:ModifyDate back, so it would be lost.
    static func restoringTIFFDate(_ properties: [String: Any], from metadata: CGImageMetadata?) -> [String: Any] {
        var tiff = properties[tiffKey] as? [String: Any] ?? [:]
        guard tiff[kCGImagePropertyTIFFDateTime as String] == nil, let metadata,
              let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:ModifyDate" as CFString) as String?,
              let date = formatter(xmpFormat).date(from: String(text.prefix(19))) else { return properties }
        var props = properties
        tiff[kCGImagePropertyTIFFDateTime as String] = formatter(exifFormat).string(from: date)
        props[tiffKey] = tiff
        return props
    }

    /// The date taken written in `props` (DateTimeOriginal, else Digitized, else the TIFF date), as a moment.
    static func dateTaken(in props: [String: Any]) -> Date? {
        let exif = props[exifKey] as? [String: Any]
        let tiff = props[tiffKey] as? [String: Any]
        let candidates = exifDateKeys.compactMap { exif?[$0] as? String }
            + [tiff?[kCGImagePropertyTIFFDateTime as String] as? String].compactMap { $0 }
        let parser = formatter(exifFormat, zone: zone(of: props))
        for text in candidates {
            if let date = parser.date(from: String(text.prefix(exifFormat.count))) { return date }
        }
        return nil
    }
}

/// Shared date formatters by format and time zone.
private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]

    func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let key = "\(format)|\(zone.identifier)|\(zone.secondsFromGMT())"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        cache[key] = formatter
        return formatter
    }
}
