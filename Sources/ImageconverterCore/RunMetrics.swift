import Foundation

/// Throughput, elapsed time and ETA for one run, fed by `ItemEvent`s. A value type with an injected clock
/// (seconds), so it is pure and testable; the caller owns the synchronisation.
public struct RunMetrics: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let elapsed: TimeInterval
        public let imagesDone: Int
        public let imagesFinished: Int
        public let imagesPerSecond: Double
        public let megapixelsPerSecond: Double
        /// Nil until three items are done (or when no rate is known yet).
        public let eta: TimeInterval?
        public let inputBytes: Int
        public let outputBytes: Int
        /// Output versus input for the items that are done; nil before any.
        public let savingPercent: Double?
    }

    /// Smoothing window of the moving averages.
    public static let window: TimeInterval = 10
    static let minimumItemsForETA = 3

    private let clock: @Sendable () -> TimeInterval
    private let megapixels: [Double]
    private let start: TimeInterval
    private var finishedIndexes = Set<Int>()
    private var done = 0
    private var inBytes = 0
    private var outBytes = 0
    private var doneInBytes = 0
    private var remainingMP: Double
    private var remainingItems: Int
    // Exponentially decayed sums; divided by the window they are a rate.
    private var decayedImages = 0.0
    private var decayedMP = 0.0
    private var lastDecay: TimeInterval

    /// `sourcePixels[i]` is the pixel count of item `i` (0 when unknown, then the ETA uses item counts).
    public init(sourcePixels: [Int], clock: @escaping @Sendable () -> TimeInterval) {
        self.clock = clock
        megapixels = sourcePixels.map { Double(max(0, $0)) / 1_000_000 }
        start = clock()
        lastDecay = start
        remainingMP = megapixels.reduce(0, +)
        remainingItems = sourcePixels.count
    }

    public mutating func record(_ event: ItemEvent) {
        switch event.stage {
        case .done, .failed, .skipped, .cancelled:
            guard finishedIndexes.insert(event.index).inserted else { return }
        default:
            return
        }
        let megapixelRate = megapixels.indices.contains(event.index) ? megapixels[event.index] : 0
        remainingMP = max(0, remainingMP - megapixelRate)
        remainingItems = max(0, remainingItems - 1)
        if let bytes = event.inputBytes, event.stage != .cancelled { inBytes += bytes }
        guard event.stage == .done else { return }
        done += 1
        decay(to: clock())
        decayedImages += 1
        decayedMP += megapixelRate
        if let bytes = event.inputBytes { doneInBytes += bytes }
        if let bytes = event.outputBytes { outBytes += bytes }
    }

    public func snapshot() -> Snapshot {
        let now = clock()
        let elapsed = max(0, now - start)
        let fade = exp(-max(0, now - lastDecay) / Self.window)
        // Until a full window has passed the sums cover less than the window: divide by what they cover.
        let covered = Self.window * (1 - exp(-elapsed / Self.window))
        let images = covered > 0 ? decayedImages * fade / covered : 0
        let megapixelRate = covered > 0 ? decayedMP * fade / covered : 0
        var eta: TimeInterval?
        if done >= Self.minimumItemsForETA {
            if megapixelRate > 0, remainingMP > 0 { eta = remainingMP / megapixelRate
            } else if images > 0 { eta = Double(remainingItems) / images }
            if remainingItems == 0 { eta = 0 }
        }
        let saving = done > 0 && doneInBytes > 0 ? (1 - Double(outBytes) / Double(doneInBytes)) * 100 : nil
        return Snapshot(elapsed: elapsed, imagesDone: done, imagesFinished: finishedIndexes.count,
                        imagesPerSecond: images, megapixelsPerSecond: megapixelRate, eta: eta,
                        inputBytes: inBytes, outputBytes: outBytes, savingPercent: saving)
    }

    private mutating func decay(to now: TimeInterval) {
        let fade = exp(-max(0, now - lastDecay) / Self.window)
        decayedImages *= fade
        decayedMP *= fade
        lastDecay = max(lastDecay, now)
    }
}
