import Foundation

/// The privacy panel's opt-in content check: whether an image shows faces or contains text, found on this Mac with
/// the Redact step's detection (`Redaction.detect`) on a copy at most `Redaction.textMaxLongSide` long. A quick
/// check: it never reads full-resolution tiles, so small text in a large image can be missed here that the Redact
/// step itself finds. It only suggests a Redact step; it never changes anything by itself.
public struct ContentFindings: Equatable, Sendable {
    public var faceCount: Int
    public var hasText: Bool

    public init(faceCount: Int = 0, hasText: Bool = false) {
        self.faceCount = faceCount
        self.hasText = hasText
    }

    public var isEmpty: Bool { faceCount == 0 && !hasText }
}

/// One image's content check: what was found, or why it couldn't be checked (never shown as "nothing found").
public enum ContentCheckResult: Equatable, Sendable {
    case found(ContentFindings)
    case failed(String)
}

public enum ContentCheck {
    /// Decodes `url` at most `Redaction.textMaxLongSide` long (within the decode limits) and looks for faces and text.
    public static func run(_ url: URL, detector: any VisionDetector = SystemVisionDetector(),
                           maxPixels: Int = ImageLoader.defaultMaxPixels) -> ContentCheckResult {
        let limits = DecodeLimits.standard.capped(maxPixels: maxPixels)
        guard let image = ImageLoader.thumbnail(of: url, maxPixelSize: Redaction.textMaxLongSide, limits: limits) else {
            return .failed("the image couldn't be read within the decode limits")
        }
        let found = Redaction.detect(.both, in: image, detector: detector)
        if let failure = found.failure { return .failed(failure) }
        return .found(ContentFindings(faceCount: found.faces.count, hasText: !found.text.isEmpty))
    }
}

/// Wording for the content findings in the privacy panel.
public enum ContentPrivacySummary {
    public static let toggleTitle = "Also look for faces and text (on this Mac)"
    public static let toggleHelp = "Uses Vision on this Mac to find images that show faces or contain text, and "
        + "suggests a Redact step. A quick check; the Redact step looks closer. Nothing leaves your Mac; nothing is "
        + "changed until you add the step."
    /// The panel's explanation with the content check on, and off.
    public static let headerWithContent = "Found in the files' metadata and headers, and in the pixels with Vision. "
        + "Nothing leaves your Mac, and the originals are not changed."
    public static let headerMetadataOnly = "Found in the files' metadata and headers. Nothing leaves your Mac, and "
        + "the originals are not changed."

    /// One line per kind found: "2 images show faces", "1 image contains text", each with the Redact target that
    /// hides it, then "Couldn't check 2 images: <first reason>" (no target). Empty when nothing was found.
    public static func lines(_ all: [ContentCheckResult]) -> [(text: String, target: RedactTarget?)] {
        var found: [ContentFindings] = []
        var failures: [String] = []
        for result in all {
            switch result {
            case .found(let findings): found.append(findings)
            case .failed(let reason): failures.append(reason)
            }
        }
        let faces = found.filter { $0.faceCount > 0 }.count
        let text = found.filter(\.hasText).count
        var lines: [(String, RedactTarget?)] = []
        if faces > 0 { lines.append(("\(faces) \(faces == 1 ? "image shows" : "images show") faces", .faces)) }
        if text > 0 { lines.append(("\(text) \(text == 1 ? "image contains" : "images contain") text", .text)) }
        if let first = failures.first {
            lines.append(("Couldn't check \(failures.count) \(failures.count == 1 ? "image" : "images"): \(first)", nil))
        }
        return lines
    }

    /// The short per-image line: "faces", "text", "faces, text".
    public static func line(_ findings: ContentFindings) -> String {
        [findings.faceCount > 0 ? "faces" : nil, findings.hasText ? "text" : nil].compactMap { $0 }
            .joined(separator: ", ")
    }
}
