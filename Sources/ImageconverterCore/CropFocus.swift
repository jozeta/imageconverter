import CoreGraphics
import Foundation

/// Which part of an image a crop keeps: a fixed position, or what Vision finds in the image.
/// Saved as one string: an anchor's raw value (`"center"`), `"subject"` or `"faces"`.
public enum CropFocus: Hashable, Sendable {
    /// A fixed position (today's behaviour; the default is the centre).
    case anchor(Anchor)
    /// The most salient regions (attention and objectness saliency).
    case subject
    /// All faces; falls back to the subject, then the centre.
    case faces

    public static let `default` = CropFocus.anchor(.center)

    /// True when the crop position depends on the image's content.
    public var isDetected: Bool {
        if case .anchor = self { return false }
        return true
    }

    /// The anchor used when nothing is detected (or for a fixed position).
    public var anchor: Anchor {
        if case .anchor(let anchor) = self { return anchor }
        return .center
    }

    /// "top left", "subject", "faces".
    public var displayName: String {
        switch self {
        case .anchor(let anchor): return anchor.displayName
        case .subject: return "subject"
        case .faces: return "faces"
        }
    }
}

extension CropFocus: Codable {
    private static let subjectValue = "subject"
    private static let facesValue = "faces"

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.subjectValue: self = .subject
        case Self.facesValue: self = .faces
        default:
            guard let anchor = Anchor(rawValue: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unknown crop focus"))
            }
            self = .anchor(anchor)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .anchor(let anchor): try container.encode(anchor.rawValue)
        case .subject: try container.encode(Self.subjectValue)
        case .faces: try container.encode(Self.facesValue)
        }
    }
}

public struct CropOptions: Codable, Equatable, Sendable {
    public var mode: CropMode
    /// Which part is kept: a fixed anchor, or the subject or faces Vision finds.
    public var focus: CropFocus

    /// The fixed anchor (the centre while the focus is detected); setting it makes the focus that anchor.
    public var anchor: Anchor {
        get { focus.anchor }
        set { focus = .anchor(newValue) }
    }

    public init(mode: CropMode = .aspect(width: 1, height: 1), anchor: Anchor = .center) {
        self.init(mode: mode, focus: .anchor(anchor))
    }

    public init(mode: CropMode, focus: CropFocus) {
        self.mode = mode
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case mode, anchor, focus
    }

    /// Lenient: crops saved before Focus existed keep their anchor; an unknown focus falls back to the anchor.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(CropMode.self, forKey: .mode)
        let anchor = (try? container.decodeIfPresent(Anchor.self, forKey: .anchor)) ?? .center
        focus = (try? container.decodeIfPresent(CropFocus.self, forKey: .focus)) ?? .anchor(anchor)
    }

    /// Writes the anchor too (the centre for a detected focus), so older versions still read the step.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(focus.anchor, forKey: .anchor)
        try container.encode(focus, forKey: .focus)
    }
}

/// What a detected focus resolved to for one image: the region to keep in view (normalised 0...1, top-left
/// origin), or nil for the centre, and the report note when it had to fall back.
public struct FocusOutcome: Equatable, Sendable {
    public let rect: CGRect?
    public let note: String?
    /// A detection failed (a Vision error, not "nothing found"): the preview doesn't cache it.
    public let detectionFailed: Bool

    public init(rect: CGRect?, note: String? = nil, detectionFailed: Bool = false) {
        self.rect = rect
        self.note = note
        self.detectionFailed = detectionFailed
    }
}

/// The fallback rules of a detected focus, without Vision (the detections are passed in).
public enum FocusResolution {
    public static let facesToSubjectNote = "No faces found; cropped around the subject"
    public static let facesToCenterNote = "No faces or subject found; cropped at the center"
    public static let subjectToCenterNote = "No subject found; cropped at the center"

    /// Every fallback note; they belong in the report only (the preview shows the crop itself).
    public static let notes: Set<String> = [facesToSubjectNote, facesToCenterNote, subjectToCenterNote]

    /// "Subject detection unavailable: …" and "Face detection unavailable: …" notes (with their fallback).
    private static let unavailablePattern = try? NSRegularExpression(
        pattern: "(No faces found; subject|Face|Subject) detection unavailable: [^;]*; cropped (around the subject|at the center)")

    /// An item's joined note ("a; b") without the focus notes (fallbacks and unavailable detection); nil when
    /// nothing is left.
    public static func withoutFocusNotes(_ note: String?) -> String? {
        guard var text = note else { return nil }
        // The notes contain "; " themselves, so they are marked as whole texts first, then removed with their
        // separators (not split).
        let mark = "\u{0}"
        for focusNote in notes { text = text.replacingOccurrences(of: focusNote, with: mark) }
        if let unavailablePattern {
            text = unavailablePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                               withTemplate: mark)
        }
        text = text.replacingOccurrences(of: "; " + mark, with: "").replacingOccurrences(of: mark + "; ", with: "")
            .replacingOccurrences(of: mark, with: "")
        return text.isEmpty ? nil : text
    }

    /// Faces: the union of all faces, else the subject, else the centre. Subject: the union of the salient
    /// regions, else the centre. A fixed anchor detects nothing. The closures run only when needed. A detection
    /// that throws falls back the same way, but its note says detection was unavailable and why (never "nothing
    /// found"); Vision never fails a run.
    public static func resolve(_ focus: CropFocus, faces: () throws -> [CGRect],
                               subject: () throws -> [CGRect]) -> FocusOutcome {
        switch focus {
        case .anchor:
            return FocusOutcome(rect: nil)
        case .subject:
            switch Result(catching: subject) {
            case .success(let rects):
                if let rect = union(rects) { return FocusOutcome(rect: rect) }
                return FocusOutcome(rect: nil, note: subjectToCenterNote)
            case .failure(let error):
                return unavailable("Subject", error, rect: nil)
            }
        case .faces:
            return resolveFaces(faces, subject: subject)
        }
    }

    private static func resolveFaces(_ faces: () throws -> [CGRect], subject: () throws -> [CGRect]) -> FocusOutcome {
        let found = Result(catching: faces)
        if case .success(let rects) = found, let rect = union(rects) { return FocusOutcome(rect: rect) }
        switch (found, Result(catching: subject)) {
        case (.failure(let error), .success(let rects)):
            return unavailable("Face", error, rect: union(rects))
        case (.failure(let error), .failure):
            return unavailable("Face", error, rect: nil)
        case (.success, .failure(let error)):
            return unavailable("No faces found; subject", error, rect: nil)
        case (.success, .success(let rects)):
            if let rect = union(rects) { return FocusOutcome(rect: rect, note: facesToSubjectNote) }
            return FocusOutcome(rect: nil, note: facesToCenterNote)
        }
    }

    private static func unavailable(_ what: String, _ error: Error, rect: CGRect?) -> FocusOutcome {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        var reason = MetadataFields.sanitized(text, limit: 160).replacingOccurrences(of: ";", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.isEmpty { reason = "Vision failed" }
        let fallback = rect == nil ? "cropped at the center" : "cropped around the subject"
        return FocusOutcome(rect: rect, note: "\(what) detection unavailable: \(reason); \(fallback)", detectionFailed: true)
    }

    /// The union of the usable rectangles, each clamped to the unit square; nil when none is left.
    /// Detections are untrusted numbers: non-finite or empty ones are dropped.
    public static func union(_ rects: [CGRect]) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let usable = rects.compactMap { rect -> CGRect? in
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
                return nil
            }
            let clipped = rect.standardized.intersection(unit)
            return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? nil : clipped
        }
        guard let first = usable.first else { return nil }
        return usable.dropFirst().reduce(first) { $0.union($1) }
    }

    /// A normalised rectangle in the pixels of a `size` image.
    public static func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }
}
