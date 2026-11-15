import CoreGraphics
import Foundation

/// On-device image analysis per file version (path, modification date and size), shared by the preview, the size
/// estimate, the quality ladder and the batch, so one file is analysed once however often its conditions are
/// resolved. The analysis looks at an upright copy of at most `VisionInput.maxLongSide` pixels, decoded only
/// within the decode limits. Failed analyses aren't kept (the next read tries again).
public final class ImageAnalysisCache: @unchecked Sendable {
    /// The app's, the command line's and the jobs' cache (Vision on this Mac).
    public static let shared = ImageAnalysisCache()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            // A fresh URL: a URL caches its resource values, which would hide a rewritten file.
            let values = try? URL(fileURLWithPath: url.path)
                .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            path = url.standardizedFileURL.path
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private struct Entry {
        var analysis: ImageAnalysis
        /// What was analysed.
        var needs: FactNeeds
        var lastUse: Int
    }

    private let analyzer: ImageAnalyzer
    private let limit: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    private var runs = 0

    public init(analyzer: ImageAnalyzer = SystemImageAnalyzer(), limit: Int = 2000) {
        self.analyzer = analyzer
        self.limit = max(1, limit)
    }

    /// How many times the analyzer ran (for tests).
    public var analysisCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    public func removeAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
    }

    /// The analysis of `url` covering the analysis parts of `needs` (nothing is analysed when there are none).
    /// What an earlier read already found is reused; only the missing parts run, in one pass.
    public func analysis(of url: URL, needs: FactNeeds, maxPixels: Int = ImageLoader.defaultMaxPixels) -> ImageAnalysis {
        let wanted = needs.intersection(.analysis)
        guard !wanted.isEmpty else { return ImageAnalysis() }
        let key = Key(url)
        lock.lock()
        clock += 1
        let cached = entries[key]
        if let cached, cached.needs.isSuperset(of: wanted) {
            entries[key]?.lastUse = clock
            lock.unlock()
            return cached.analysis
        }
        lock.unlock()

        let missing = wanted.subtracting(cached?.needs ?? [])
        let limits = DecodeLimits.standard.capped(maxPixels: maxPixels)
        guard let image = ImageLoader.thumbnail(of: url, maxPixelSize: VisionInput.maxLongSide, limits: limits) else {
            return ImageAnalysis(failure: "the image couldn't be read within the decode limits")
        }
        lock.lock()
        runs += 1
        lock.unlock()
        let found: ImageAnalysis
        do {
            found = try analyzer.analyze(image, needs: missing)
        } catch {
            return ImageAnalysis(failure: ImageAnalysis.reason(error))
        }
        lock.lock()
        defer { lock.unlock() }
        let merged = (cached?.analysis ?? ImageAnalysis()).merged(with: found)
        guard merged.failure == nil else { return merged }
        if entries[key] == nil, entries.count >= limit { evictLeastRecentlyUsed() }
        clock += 1
        entries[key] = Entry(analysis: merged, needs: wanted.union(cached?.needs ?? []), lastUse: clock)
        return merged
    }

    /// Drops the least recently used quarter (at least one). Called with the lock held.
    private func evictLeastRecentlyUsed() {
        let count = max(1, entries.count / 4)
        for key in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }).prefix(count).map(\.key) {
            entries[key] = nil
        }
    }
}
