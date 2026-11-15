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
    func redactRects(_ options: RedactOptions, in image: CGImage, step: Int, context: FocusContext,
                     notes: inout [String]) -> [CGRect] {
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
        let size = CGSize(width: image.width, height: image.height)
        let rects = Redaction.pixelRects(found.faces + found.text, padding: options.clampedPadding, in: size)
        let note = Redaction.note(faces: found.faces.count, text: found.text.count, failure: found.failure)
        if !notes.contains(note) { notes.append(note) }
        return rects
    }
}

extension Pipeline {
    /// Where a new Redact step goes: right after the last Crop, Rotate / flip or Perspective step (so it sees the
    /// final framing, and comes before a Watermark it shouldn't blur), else first.
    public var redactInsertionIndex: Int {
        let framing: Set<StepKind> = [.crop, .rotateFlip, .perspective]
        guard let last = steps.lastIndex(where: { framing.contains($0.operation.kind) }) else { return 0 }
        return last + 1
    }

    /// Adds a new step where it belongs: Redact at `redactInsertionIndex`, every other kind at the end.
    public mutating func add(_ step: PipelineStep) {
        if step.operation.kind == .redact {
            steps.insert(step, at: redactInsertionIndex)
        } else {
            steps.append(step)
        }
    }

    /// Adds a Redact step for `target` (privacy panel suggestion): an enabled Redact step already there is
    /// widened to cover `target` too; else a new one is inserted at `redactInsertionIndex`. Returns its id.
    @discardableResult
    public mutating func addRedaction(_ target: RedactTarget) -> PipelineStep.ID {
        if let index = steps.firstIndex(where: { $0.operation.kind == .redact && $0.isEnabled }),
           case .redact(var options) = steps[index].operation {
            options.target = options.target.adding(target)
            steps[index].operation = .redact(options)
            return steps[index].id
        }
        let step = PipelineStep(operation: .redact(RedactOptions(target: target)))
        steps.insert(step, at: redactInsertionIndex)
        return step.id
    }
}
