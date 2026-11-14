import Foundation

/// Regular expressions from presets and pipelines are untrusted: a pattern such as `(a+)+$` can take exponential
/// time. Every match here stops after `timeLimit`, and a stopped search counts as no match (no replacement).
public enum BoundedRegex {
    public static let timeLimit: TimeInterval = 0.05
    /// The report note for a condition or rename pattern that was stopped.
    public static let timeoutNote = "Pattern took too long"

    /// Every match of `regex` in `text`, or only the first with `first`; nil when the search was stopped.
    static func matches(_ regex: NSRegularExpression, in text: String, first: Bool = false,
                        limit: TimeInterval = timeLimit) -> [NSTextCheckingResult]? {
        let start = Date()
        var found: [NSTextCheckingResult] = []
        var timedOut = false
        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: NSRange(text.startIndex..., in: text)) { result, _, stop in
            if let result {
                found.append(result)
                if first { stop.pointee = true }
            }
            if Date().timeIntervalSince(start) > limit {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut ? nil : found
    }

    /// Whether `regex` matches somewhere in `text`; nil when the search was stopped.
    static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Bool? {
        matches(regex, in: text, first: true).map { !$0.isEmpty }
    }

    /// `text` with every match replaced by `template` (`$1` etc.); nil when the search was stopped.
    static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String? {
        guard let found = matches(regex, in: text) else { return nil }
        let result = NSMutableString(string: text)
        var offset = 0
        for match in found {
            let replacement = regex.replacementString(for: match, in: text, offset: offset, template: template)
            result.replaceCharacters(in: NSRange(location: match.range.location + offset, length: match.range.length),
                                     with: replacement)
            offset += (replacement as NSString).length - match.range.length
        }
        return result as String
    }
}
