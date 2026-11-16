import CoreGraphics
import Foundation

/// Remembers detected focus regions, so the preview doesn't run Vision again on every edit. Keyed by the source
/// file's version, the step and everything before it, so an entry is only reused for the same pixels.
public final class FocusCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        /// The source file's path, modification date and size.
        let source: String
        let step: Int
        /// The enabled operations before the step, encoded: a change there changes the step's input.
        let before: Data
        let width: Int
        let height: Int
        let focus: CropFocus
    }

    private let lock = NSLock()
    private var entries: [Key: FocusOutcome] = [:]
    private let limit: Int
    private var detections = 0
    /// How many detections ran (for tests).
    public var detectionCount: Int { lock.withLock { detections } }

    public init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
    }

    func outcome(for key: Key, detect: () -> FocusOutcome) -> FocusOutcome {
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let outcome = detect()
        lock.lock()
        defer { lock.unlock() }
        detections += 1
        // A failed detection is asked again next time.
        guard !outcome.detectionFailed else { return outcome }
        if entries.count >= limit { entries = [:] }
        entries[key] = outcome
        return outcome
    }

    /// The version part of a key: path, modification date and size (a rewritten file changes them).
    public static func sourceKey(for url: URL) -> String {
        let values = try? URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(date)|\(values?.fileSize ?? -1)"
    }
}

/// How a pipeline runs Vision for its steps (a Crop or Resize focus, Redact): the detector, and the caches for
/// one source file (preview only).
public struct FocusContext: Sendable {
    public let detector: any VisionDetector
    public let cache: FocusCache?
    /// Redact detections per step input (preview only).
    public let redactCache: RedactCache?
    /// `FocusCache.sourceKey(for:)` of the image being rendered; without it nothing is cached.
    public let sourceKey: String?
    /// The super-resolution model for a Resize step's ML enlarge (tests inject a fake).
    public let enlarger: any SuperResolutionScaler

    public init(detector: any VisionDetector = SystemVisionDetector(), cache: FocusCache? = nil,
                redactCache: RedactCache? = nil, sourceKey: String? = nil,
                enlarger: any SuperResolutionScaler = SystemSuperResolution.shared) {
        self.detector = detector
        self.cache = cache
        self.redactCache = redactCache
        self.sourceKey = sourceKey
        self.enlarger = enlarger
    }

    public static let system = FocusContext()
}

/// Where a step sits: its index and the enabled operations before it (what made its input).
struct StepPosition {
    let index: Int
    let before: [ImageOperation]
}

/// Runs the detection for a Crop or Resize focus on the image as it arrives at the step.
enum FocusDetector {
    /// The focus region in `image`'s pixels (top-left origin), or nil to use the anchor (always nil for a fixed
    /// anchor). A fallback adds its note to `notes`.
    static func focusRect(_ focus: CropFocus, in image: CGImage, at position: StepPosition,
                          context: FocusContext, notes: inout [String]) -> CGRect? {
        guard focus.isDetected else { return nil }
        let detect = { () -> FocusOutcome in
            // One small copy serves both detections (the detector's own shrink is then a no-op).
            let input = VisionInput.prepared(image)
            return FocusResolution.resolve(focus, faces: { try input.map(context.detector.faceRects) ?? [] },
                                           subject: { try input.map(context.detector.subjectRects) ?? [] })
        }
        let outcome: FocusOutcome
        if let cache = context.cache, let source = context.sourceKey,
           let encoded = try? JSONEncoder.sortedKeys.encode(position.before) {
            let key = FocusCache.Key(source: source, step: position.index, before: encoded, width: image.width,
                                     height: image.height, focus: focus)
            outcome = cache.outcome(for: key, detect: detect)
        } else {
            outcome = detect()
        }
        if let note = outcome.note, !notes.contains(note) { notes.append(note) }
        return outcome.rect.map { FocusResolution.pixelRect($0, in: CGSize(width: image.width, height: image.height)) }
    }
}

extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
