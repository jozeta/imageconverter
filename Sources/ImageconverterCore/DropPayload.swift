import Foundation

/// Text a drop on a step row carries. The rows take `String` payloads for reordering (a step id), but a file drag
/// from another app can offer its locations as text too, and an inner drop target that swallows it would hide the
/// window's own file drop. Such text is read here as file locations instead. Untrusted: only `file://` URLs and
/// absolute paths count, one per line, at most `maxFiles`.
public enum DropPayload {
    public static let maxFiles = 10_000

    /// The file URLs in `strings` (step ids, web links and other text are ignored), in order, once each.
    public static func fileURLs(in strings: [String]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for line in strings.lazy.flatMap({ $0.split(whereSeparator: \.isNewline) }) {
            guard urls.count < maxFiles else { break }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.value == 0 })
            else { continue }
            let url: URL
            if text.hasPrefix("/") {
                url = URL(fileURLWithPath: text)
            } else if let parsed = URL(string: text), parsed.isFileURL, parsed.path.hasPrefix("/") {
                url = parsed
            } else {
                continue
            }
            let standard = url.standardizedFileURL
            if seen.insert(standard.path).inserted { urls.append(standard) }
        }
        return urls
    }
}
