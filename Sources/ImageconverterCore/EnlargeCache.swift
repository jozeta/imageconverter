import CoreGraphics
import Foundation

/// Remembers ML enlarge results for the preview, the size estimate and the quality ladder, so an edit after the
/// Resize step (the output quality, an Adjust slider) doesn't run the model again. Keyed like `FocusCache`: the
/// source file's version, the step and everything before it, the input's size and the factor.
///
/// It also keeps those three to **one ML enlarge at a time, app-wide** (they run outside the batch's memory
/// scheduler): a miss waits for any enlarge in progress, then looks again, so the preview and the estimate asking
/// for the same input at once share one run. Results are big (a 12 MP photo at 4× is 192 MP), so at most
/// `maxEntries` are kept and none larger than `maxPixels` in all; the batch never uses this cache.
public final class EnlargeCache: @unchecked Sendable {
    struct Key: Hashable {
        let source: String
        let step: Int
        let before: Data
        let width: Int
        let height: Int
        let factor: Int
    }

    struct Entry {
        let image: CGImage
        let notes: [String]
    }

    /// One enlarge at a time across every cache (the preview, estimate and ladder share one in the app anyway).
    private static let running = NSLock()
    public static let maxEntries = 2
    public static let maxPixels = 200_000_000

    private let lock = NSLock()
    private var entries: [(key: Key, entry: Entry)] = []
    private var runs = 0
    private let active = WaitingCounter()

    public init() {}

    /// How many enlarges ran through this cache (for tests).
    public var runCount: Int { lock.withLock { runs } }

    /// The most enlarges that ran through this cache at once (for tests).
    var peakRunning: Int { active.peak }

    public func removeAll() {
        lock.withLock { entries = [] }
    }

    func result(for key: Key, enlarge: () throws -> Entry) throws -> Entry {
        if let hit = lookup(key) { return hit }
        Self.running.lock()
        defer { Self.running.unlock() }
        // Another render may have made it while this one waited.
        if let hit = lookup(key) { return hit }
        active.enter()
        defer { active.leave() }
        let made = try enlarge()
        store(made, for: key)
        return made
    }

    private func lookup(_ key: Key) -> Entry? {
        lock.withLock { entries.first { $0.key == key }?.entry }
    }

    private func store(_ entry: Entry, for key: Key) {
        lock.withLock {
            runs += 1
            let pixels = entry.image.width * entry.image.height
            guard pixels <= Self.maxPixels else { return }
            entries.removeAll { $0.key == key }
            entries.append((key, entry))
            // Oldest first out, until both limits hold.
            while entries.count > Self.maxEntries
                    || entries.reduce(0, { $0 + $1.entry.image.width * $1.entry.image.height }) > Self.maxPixels {
                entries.removeFirst()
            }
        }
    }
}

/// The detection and model caches the preview keeps, shared with the size estimate and the quality ladder so the
/// three run Vision and ML enlarge once per file version and step input between them.
public struct PreviewCaches: Sendable {
    public let focus: FocusCache
    public let redact: RedactCache
    public let enlarge: EnlargeCache
    /// The last full-size decode, so the estimate and the ladder don't decode the preview's source again.
    public let sources: SourceCache

    public init(focus: FocusCache = FocusCache(), redact: RedactCache = RedactCache(),
                enlarge: EnlargeCache = EnlargeCache(), sources: SourceCache = SourceCache()) {
        self.focus = focus
        self.redact = redact
        self.enlarge = enlarge
        self.sources = sources
    }

    /// The Vision and model context for rendering `source` with these caches.
    public func context(for source: URL, detector: any VisionDetector = SystemVisionDetector(),
                        enlarger: any SuperResolutionScaler) -> FocusContext {
        FocusContext(detector: detector, cache: focus, redactCache: redact, enlargeCache: enlarge,
                     sourceKey: FocusCache.sourceKey(for: source), enlarger: enlarger)
    }
}

extension Pipeline {
    /// Step `index`'s ML enlarge of `image`, from `context`'s cache when it has one (preview, estimate, ladder).
    func mlEnlarged(_ image: CGImage, factor: Int, step index: Int, context: FocusContext,
                    notes: inout [String]) throws -> CGImage {
        let run = { () throws -> EnlargeCache.Entry in
            var added: [String] = []
            let enlarged = try MLEnlarge.enlarge(image, factor: factor, scaler: context.enlarger, notes: &added)
            return EnlargeCache.Entry(image: enlarged, notes: added)
        }
        let entry: EnlargeCache.Entry
        if let cache = context.enlargeCache, let source = context.sourceKey,
           let before = try? JSONEncoder.sortedKeys.encode(steps.prefix(index).filter(\.isEnabled).map(\.operation)) {
            let key = EnlargeCache.Key(source: source, step: index, before: before, width: image.width,
                                       height: image.height, factor: factor)
            entry = try cache.result(for: key, enlarge: run)
        } else {
            entry = try run()
        }
        for note in entry.notes where !notes.contains(note) { notes.append(note) }
        return entry.image
    }
}
