import CryptoKit
import Foundation

// MARK: - Token values

extension RenameTemplate {
    static func value(of name: String, arg: String?, context: RenameContext) -> String {
        switch name {
        case "name": return context.name
        case "ext": return context.ext
        case "date": return format(context.date, arg, default: "yyyy-MM-dd")
        case "time": return format(context.date, arg, default: "HHmmss")
        case "datetime":
            let day = format(context.date, nil, default: "yyyy-MM-dd")
            return day.isEmpty ? "" : day + "_" + format(context.date, nil, default: "HHmmss")
        case "created": return format(context.created, arg, default: "yyyy-MM-dd")
        case "modified": return format(context.modified, arg, default: "yyyy-MM-dd")
        case "counter", "seq":
            let text = String(max(context.counter, 0))
            let width = (arg?.allSatisfy { $0 == "0" } ?? false) ? (arg?.count ?? 0) : 0
            return String(repeating: "0", count: max(width - text.count, 0)) + text
        default: return metadataValue(of: name, arg: arg, context: context)
        }
    }

    static func metadataValue(of name: String, arg: String?, context: RenameContext) -> String {
        switch name {
        case "camera": return context.model ?? ""
        case "make": return context.make ?? ""
        case "lens": return context.lens ?? ""
        case "iso": return context.iso.map(String.init) ?? ""
        case "width": return String(context.width)
        case "height": return String(context.height)
        case "format": return context.format
        case "folder": return context.folder
        case labelsToken:
            // Model output: each label cleaned like metadata text, at most 10.
            return (context.labels ?? []).prefix(ImageAnalysis.maxTokenLabels).map { MetadataFields.sanitized($0) }
                .filter { !$0.isEmpty }.joined(separator: labelSeparator(arg))
        default: return exposureValue(of: name, arg: arg, context: context)
        }
    }

    /// `{labels:-}`: up to 3 of ` -_.,+` between the labels; anything else (or none) gives ", ".
    static func labelSeparator(_ arg: String?) -> String {
        guard let arg, !arg.isEmpty, arg.count <= 3, arg.allSatisfy({ " -_.,+".contains($0) }) else { return ", " }
        return arg
    }

    static func exposureValue(of name: String, arg: String?, context: RenameContext) -> String {
        switch name {
        case "focal":
            // EXIF numbers are untrusted: out-of-range or non-finite values render nothing (and never reach Int()).
            guard let focal = context.focalLength, focal.isFinite, focal >= 0.5, focal <= 10_000 else { return "" }
            return "\(Int(focal.rounded()))mm"
        case "aperture":
            guard let value = context.aperture, value.isFinite, value >= 0.1, value <= 1000 else { return "" }
            return "f" + trimmed(value)
        case "shutter":
            guard let seconds = context.exposureTime, seconds.isFinite, seconds >= 1e-6, seconds <= 3600 else { return "" }
            return shutter(seconds)
        default: return fileValue(of: name, arg: arg, context: context)
        }
    }

    static func fileValue(of name: String, arg: String?, context: RenameContext) -> String {
        switch name {
        case "megapixels":
            let pixels = Double(max(context.width, 0)) * Double(max(context.height, 0)) / 1_000_000
            return trimmed(pixels) + "MP"
        case "orientation":
            if context.width == context.height { return "square" }
            return context.width > context.height ? "landscape" : "portrait"
        case "srcext": return context.sourceExtension
        case "preset": return context.preset ?? ""
        case "random":
            let length = arg.flatMap(Int.init).flatMap { (1...32).contains($0) ? $0 : nil } ?? 8
            return randomText(context.seed, length: length)
        case "uuid": return stableUUID(context.seed)
        default: return ""
        }
    }

    /// Letters and digits that look random but come from `seed` (the source path), so the preview shows the name
    /// the batch writes. Lower case only, so names never differ by case alone.
    static func randomText(_ seed: String, length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let digest = SHA256.hash(data: Data(("random\u{0}" + seed).utf8))
        return String(digest.prefix(length).map { alphabet[Int($0) % alphabet.count] })
    }

    /// A version 4 style UUID derived from `seed` (stable per file, like `randomText`).
    static func stableUUID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(("uuid\u{0}" + seed).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    /// One decimal place, without a trailing `.0` (so f/1.78 becomes `1.8`).
    static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// `0.004` becomes `1-250s` (no `/` in file names). From 0.3 s up it is plain seconds to one decimal
    /// (`0.8s`, `1s`, `2s`, `1.5s`), so `1-1s` never appears. The caller has range-checked `seconds`.
    static func shutter(_ seconds: Double) -> String {
        if seconds < 0.3 { return "1-\(Int((1 / seconds).rounded()))s" }
        return trimmed(seconds) + "s"
    }

    static func format(_ date: Date?, _ arg: String?, default fallback: String) -> String {
        guard let date else { return "" }
        return formatDate(date, (arg?.isEmpty ?? true) ? fallback : arg ?? fallback)
    }

    /// `date` in `pattern` (POSIX locale, Gregorian, GMT: dates here are wall clocks stored as GMT).
    static func formatDate(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
