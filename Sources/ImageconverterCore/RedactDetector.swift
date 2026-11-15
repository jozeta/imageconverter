import CoreGraphics
import Foundation

/// Remembers a Redact step's detections, so the preview doesn't run Vision again on every edit (changing the
/// style or padding never needs a new detection). Keyed like `FocusCache`: the source file's version, the step
/// and everything before it. Failed detections aren't kept, so the next render tries again.
public final class RedactCache: @unchecked Sendable {
    struct Key: Hashable {
        let source: String
        let step: Int
        let before: Data
        let width: Int
        let height: Int
        let target: RedactTarget
    }

    private let lock = NSLock()
    private var entries: [Key: RedactDetections] = [:]
    private let limit: Int
    private var runs = 0

    public init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    /// How many detections ran (for tests).
    public var detectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
    }

    func detections(for key: Key, detect: () -> RedactDetections) -> RedactDetections {
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let found = detect()
        lock.lock()
        defer { lock.unlock() }
        runs += 1
        guard found.failure == nil else { return found }
        if entries.count >= limit { entries = [:] }
        entries[key] = found
        return found
    }
}

extension Pipeline {
    /// A Redact step's padded pixel rects in `image` (the image as it arrives at the step), with its report note.
    /// Throws `redactUnchecked` when a detection the step needs failed: fail closed, never write it unchecked.
    func redactRects(_ options: RedactOptions, in image: CGImage, step: Int, context: FocusContext,
                     notes: inout [String]) throws -> [CGRect] {
        let detect = { Redaction.detect(options.target, in: image, detector: context.detector) }
        let found: RedactDetections
        let before = steps.prefix(step).filter(\.isEnabled).map(\.operation)
        if let cache = context.redactCache, let source = context.sourceKey,
           let encoded = try? JSONEncoder.sortedKeys.encode(before) {
            let key = RedactCache.Key(source: source, step: step, before: encoded, width: image.width,
                                      height: image.height, target: options.target)
            found = cache.detections(for: key, detect: detect)
        } else {
            found = detect()
        }
        if let failure = found.failure { throw ConversionError.redactUnchecked(target: options.target, reason: failure) }
        let size = CGSize(width: image.width, height: image.height)
        let rects = Redaction.pixelRects(found.faces + found.text, padding: options.clampedPadding, in: size)
        let note = Redaction.note(faces: found.faces.count, text: found.text.count)
        if !notes.contains(note) { notes.append(note) }
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
