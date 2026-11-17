import CoreGraphics
import Foundation

/// Remembers detected focus regions, so the preview doesn't run Vision again on every edit. Keyed by the source
/// file's version, the step and everything before it, so an entry is only reused for the same pixels. The preview,
/// the size estimate and the quality ladder asking at once share one detection (`SharedDetections`).
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

    private let shared: SharedDetections<Key, FocusOutcome>
    /// How many detections ran (for tests).
    public var detectionCount: Int { shared.runCount }

    public init(limit: Int = 256) {
        // A failed detection is asked again next time.
        shared = SharedDetections(limit: limit) { !$0.detectionFailed }
    }

    public func removeAll() {
        shared.removeAll()
    }

    /// The outcome for `key`; lookups for a detection in progress wait for it (`SharedDetections`). A caller
    /// cancelled while it waited gets the anchor (its render is thrown away).
    func outcome(for key: Key, detect: @escaping @Sendable () -> FocusOutcome) -> FocusOutcome {
        shared.value(for: key, detect: detect) ?? FocusOutcome(rect: nil)
    }

    /// The version part of a key: path, modification date and size (a rewritten file changes them).
    public static func sourceKey(for url: URL) -> String {
        let values = try? URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(date)|\(values?.fileSize ?? -1)"
    }
}

/// How a pipeline runs Vision and the ML enlarge model for its steps (a Crop or Resize focus, Redact, ML enlarge):
/// the detector, the model, and the caches for one source file (preview, estimate and ladder; never the batch).
public struct FocusContext: Sendable {
    public let detector: any VisionDetector
    public let cache: FocusCache?
    /// Redact detections per step input (preview, estimate and ladder).
    public let redactCache: RedactCache?
    /// ML enlarge results per step input, and one enlarge at a time (preview, estimate and ladder).
    public let enlargeCache: EnlargeCache?
    /// `FocusCache.sourceKey(for:)` of the image being rendered; without it nothing is cached.
    public let sourceKey: String?
    /// The super-resolution model for a Resize step's ML enlarge (tests inject a fake).
    public let enlarger: any SuperResolutionScaler
    /// Told the target while this render waits for a Redact detection, and nil when it stops waiting (the preview
    /// shows "Finding faces and text…" meanwhile). Only with `redactCache`.
    public var redactActivity: (@Sendable (RedactTarget?) -> Void)?

    public init(detector: any VisionDetector = SystemVisionDetector(), cache: FocusCache? = nil,
                redactCache: RedactCache? = nil, enlargeCache: EnlargeCache? = nil, sourceKey: String? = nil,
                enlarger: any SuperResolutionScaler = SystemSuperResolution.shared) {
        self.detector = detector
        self.cache = cache
        self.redactCache = redactCache
        self.enlargeCache = enlargeCache
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
        let detector = context.detector
        let detect = { @Sendable () -> FocusOutcome in
            // One small copy serves both detections (the detector's own shrink is then a no-op).
            let input = VisionInput.prepared(image)
            return FocusResolution.resolve(focus, faces: { try input.map(detector.faceRects) ?? [] },
                                           subject: { try input.map(detector.subjectRects) ?? [] })
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
