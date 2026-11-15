import Foundation

/// The privacy panel's opt-in content check: whether an image shows faces or contains text, found on this Mac with
/// the same cached analysis the conditions use (`ImageAnalysisCache`). It only suggests a Redact step; it never
/// changes anything by itself.
public struct ContentFindings: Equatable, Sendable {
    public var faceCount: Int
    public var hasText: Bool

    public init(faceCount: Int = 0, hasText: Bool = false) {
        self.faceCount = faceCount
        self.hasText = hasText
    }

    /// What the check needs from the analysis.
    public static let needs: FactNeeds = [.faces, .text]

    /// The findings of one analysis; nil when it failed (nothing is claimed either way).
    public init?(_ analysis: ImageAnalysis) {
        guard analysis.failure == nil else { return nil }
        self.init(faceCount: max(0, analysis.faceCount ?? 0), hasText: analysis.hasText ?? false)
    }

    public var isEmpty: Bool { faceCount == 0 && !hasText }
}

/// Wording for the content findings in the privacy panel.
public enum ContentPrivacySummary {
    public static let toggleTitle = "Also look for faces and text (on this Mac)"
    public static let toggleHelp = "Uses Vision on this Mac to find images that show faces or contain text, and "
        + "suggests a Redact step. Nothing leaves your Mac; nothing is changed until you add the step."

    /// One line per kind found: "2 images show faces", "1 image contains text", each with the Redact target that
    /// hides it. Empty when nothing was found.
    public static func lines(_ all: [ContentFindings]) -> [(text: String, target: RedactTarget)] {
        let faces = all.filter { $0.faceCount > 0 }.count
        let text = all.filter(\.hasText).count
        var lines: [(String, RedactTarget)] = []
        if faces > 0 { lines.append(("\(faces) \(faces == 1 ? "image shows" : "images show") faces", .faces)) }
        if text > 0 { lines.append(("\(text) \(text == 1 ? "image contains" : "images contain") text", .text)) }
        return lines
    }

    /// The short per-image line: "faces", "text", "faces, text".
    public static func line(_ findings: ContentFindings) -> String {
        [findings.faceCount > 0 ? "faces" : nil, findings.hasText ? "text" : nil].compactMap { $0 }
            .joined(separator: ", ")
    }
}
