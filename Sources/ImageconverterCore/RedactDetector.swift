import CoreGraphics
import Foundation

/// Remembers a Redact step's detections, so the preview doesn't run Vision again on every edit (changing the
/// style or padding never needs a new detection). Keyed like `FocusCache`: the source file's version, the step
/// and everything before it. Lookups for a detection in progress wait for it (`SharedDetections`), so the preview,
/// the size estimate and the quality ladder run one detection per image between them. Failed and cancelled
/// detections aren't kept (every waiter gets the failure), so the next render tries again.
public final class RedactCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let source: String
        let step: Int
        let before: Data
        let width: Int
        let height: Int
        let target: RedactTarget
    }

    private let shared: SharedDetections<Key, RedactDetections>

    public init(limit: Int = 256) {
        shared = SharedDetections(limit: limit) { $0.failure == nil && !$0.cancelled }
    }

    /// How many detections ran (for tests).
    public var detectionCount: Int { shared.runCount }

    public func removeAll() {
        shared.removeAll()
    }

    /// The detections for `key`; cancelled when the caller was cancelled while it waited.
    func detections(for key: Key, waiting: ((Bool) -> Void)? = nil,
                    detect: @escaping @Sendable () -> RedactDetections) -> RedactDetections {
        if let found = shared.value(for: key, waiting: waiting, detect: detect) { return found }
        var cancelled = RedactDetections()
        cancelled.cancelled = true
        return cancelled
    }
}

extension Pipeline {
    /// A Redact step's padded pixel rects in `image` (the image as it arrives at the step), with its report note.
    /// Throws `redactUnchecked` when a detection the step needs failed: fail closed, never write it unchecked.
    func redactRects(_ options: RedactOptions, in image: CGImage, step: Int, context: FocusContext,
                     notes: inout [String]) throws -> [CGRect] {
        let detector = context.detector
        let detect: @Sendable () -> RedactDetections = { Redaction.detect(options.target, in: image, detector: detector) }
        let found: RedactDetections
        let before = steps.prefix(step).filter(\.isEnabled).map(\.operation)
        if let cache = context.redactCache, let source = context.sourceKey,
           let encoded = try? JSONEncoder.sortedKeys.encode(before) {
            let key = RedactCache.Key(source: source, step: step, before: encoded, width: image.width,
                                      height: image.height, target: options.target)
            let activity = context.redactActivity
            found = cache.detections(for: key, waiting: activity.map { report in { report($0 ? options.target : nil) } },
                                     detect: detect)
        } else {
            found = detect()
        }
        // Cancelled (e.g. while waiting for the tile gate): the item is cancelled, nothing written.
        if found.cancelled { throw CancellationError() }
        if let failure = found.failure { throw ConversionError.redactUnchecked(target: options.target, reason: failure) }
        let size = CGSize(width: image.width, height: image.height)
        let rects = Redaction.pixelRects(found.faces + found.text, padding: options.clampedPadding, in: size)
        let note = Redaction.note(faces: found.faces.count, text: TextBoxes.distinctCount(found.text))
        if !notes.contains(note) { notes.append(note) }
        if let raised = options.raisedNote(for: rects), !notes.contains(raised) { notes.append(raised) }
        return rects
    }
}

extension Pipeline {
    /// Where a new Redact step goes: right after the last Crop, Rotate / flip or Perspective step (so it sees the
    /// final framing), else first; but always before the first Watermark (which it mustn't hide).
    public var redactInsertionIndex: Int {
        let framing: Set<StepKind> = [.crop, .rotateFlip, .perspective]
        let afterFraming = steps.lastIndex(where: { framing.contains($0.operation.kind) }).map { $0 + 1 } ?? 0
        let watermark = steps.firstIndex { $0.operation.kind == .watermark } ?? steps.count
        return min(afterFraming, watermark)
    }

    /// Adds a new step where it belongs: Redact at `redactInsertionIndex`, every other kind at the end.
    public mutating func add(_ step: PipelineStep) {
        if step.operation.kind == .redact {
            steps.insert(step, at: redactInsertionIndex)
        } else {
            steps.append(step)
        }
    }

    /// Adds a Redact step for `target` (privacy panel suggestion), never running anything. An enabled Redact step
    /// that already hides `target` (text only with a solid colour) is left as it is; one that fills is widened to
    /// cover `target` too, as is a blurring one asked to add faces. Otherwise a new step (text: solid colour) is
    /// inserted after the existing one, or at `redactInsertionIndex`. Returns the id of the step that covers it.
    @discardableResult
    public mutating func addRedaction(_ target: RedactTarget) -> PipelineStep.ID {
        let existing = steps.indices.filter { steps[$0].isEnabled && steps[$0].operation.kind == .redact }
        for index in existing {
            guard case .redact(var options) = steps[index].operation else { continue }
            let textSafe = !target.includesText || options.style == .fill
            if options.target.adding(target) == options.target, textSafe { return steps[index].id }
            if textSafe {
                options.target = options.target.adding(target)
                steps[index].operation = .redact(options)
                return steps[index].id
            }
        }
        let step = PipelineStep(operation: .redact(RedactOptions(target: target)))
        steps.insert(step, at: existing.last.map { $0 + 1 } ?? redactInsertionIndex)
        return step.id
    }
}
