import CoreGraphics
import Foundation

/// The last full-size decode of a source, shared by the preview, the size estimate and the quality ladder of the same
/// item (`PreviewCaches.sources`; never the batch). Keyed by file version and pixel limit. A decode in progress is
/// shared too: a second caller for the same file waits for it instead of decoding again (both run synchronous work
/// anyway: the preview's actor and the estimate's detached task).
public final class SourceCache: @unchecked Sendable {
    /// Sources above this many pixels are shared while decoding but not kept.
    static let maxCachedPixels = 50_000_000

    private struct Key: Equatable {
        let version: String
        let maxPixels: Int
    }

    private final class Flight {
        var result: Result<LoadedImage, Error>?
    }

    private let condition = NSCondition()
    private var entry: (key: Key, loaded: LoadedImage)?
    private var flights: [String: (key: Key, flight: Flight)] = [:]
    private var decodes = 0

    public init() {}

    /// How many full decodes were started (for tests).
    public var decodeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return decodes
    }

    /// The full-size upright decode of `url` with its properties and metadata view, from the cache, from a decode
    /// another caller has in progress, or decoded now (`ImageLoader.load`, so the same limits).
    public func load(_ url: URL, maxPixels: Int) throws -> LoadedImage {
        let key = Key(version: FocusCache.sourceKey(for: url), maxPixels: maxPixels)
        condition.lock()
        if let entry, entry.key == key {
            condition.unlock()
            return entry.loaded
        }
        if let running = flights[url.path], running.key == key {
            while running.flight.result == nil { condition.wait() }
            let shared = running.flight.result
            condition.unlock()
            guard let shared else { throw ConversionError.unreadable }
            return try shared.get()
        }
        // One kept source at a time: a decode of another file (or version) lets the old one go first.
        entry = nil
        let flight = Flight()
        flights[url.path] = (key, flight)
        decodes += 1
        condition.unlock()

        let result = Result { try ImageLoader.load(url, maxPixels: maxPixels, includeMetadata: true) }
        condition.lock()
        flight.result = result
        if flights[url.path]?.flight === flight { flights[url.path] = nil }
        if case .success(let loaded) = result, loaded.image.width <= Self.maxCachedPixels / max(1, loaded.image.height) {
            entry = (key, loaded)
        }
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }

    /// The cached decode of `url` if there is one now (never waits or decodes).
    public func cached(_ url: URL, maxPixels: Int) -> LoadedImage? {
        let key = Key(version: FocusCache.sourceKey(for: url), maxPixels: maxPixels)
        condition.lock()
        defer { condition.unlock() }
        return entry?.key == key ? entry?.loaded : nil
    }

    /// Drops the kept decode (a batch starts or finishes, the list is cleared).
    public func removeAll() {
        condition.lock()
        entry = nil
        condition.unlock()
    }
}

extension BatchRunner {
    /// The decode `prepare` works on: the preview's shared full-size decode for the estimate and the ladder
    /// (`ItemRunOptions.sources`, only when no hint applies), else its own, at the hint's size when there is one.
    static func load(_ url: URL, pipeline: Pipeline, hint: DecodeHint?, maxPixels: Int,
                     options: ItemRunOptions) throws -> LoadedImage {
        let metadata = pipeline.effectiveMetadata.isActive
        if hint == nil, let sources = options.sources {
            let shared = try sources.load(url, maxPixels: maxPixels)
            // As the batch's own decode: the metadata view only when the Metadata step needs it.
            return metadata ? shared : LoadedImage(image: shared.image, properties: shared.properties, metadata: nil)
        }
        return try ImageLoader.load(url, maxPixels: maxPixels, maxLongSide: hint?.maxLongSide, includeMetadata: metadata,
                                    lowMemory: options.lowMemory)
    }
}
