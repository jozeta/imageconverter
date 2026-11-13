import CoreGraphics
import Foundation

/// How far a batch has got. `completed` counts successes and failures.
public struct BatchProgress: Equatable, Sendable {
    public let completed: Int
    public let failed: Int
    public let total: Int

    public init(completed: Int, failed: Int, total: Int) {
        self.completed = completed
        self.failed = failed
        self.total = total
    }
}

/// A file that was skipped, and why.
public struct BatchFailure: Equatable, Sendable {
    public let source: URL
    public let reason: String

    public init(source: URL, reason: String) {
        self.source = source
        self.reason = reason
    }
}

/// Something worth telling about a file that was written (e.g. a target size it couldn't reach).
public struct BatchNote: Equatable, Sendable {
    public let source: URL
    public let text: String

    public init(source: URL, text: String) {
        self.source = source
        self.text = text
    }
}

/// One written file with its byte counts.
public struct BatchResultEntry: Equatable, Sendable {
    public let source: URL
    public let destination: URL
    public let inputBytes: Int
    public let outputBytes: Int
    public let note: String?

    public init(source: URL, destination: URL, inputBytes: Int, outputBytes: Int, note: String? = nil) {
        self.source = source
        self.destination = destination
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.note = note
    }
}

/// The outcome of a batch: all lists are in input order. A note is not a failure; its file was written.
public struct BatchReport: Equatable, Sendable {
    public var written: [URL]
    public var failures: [BatchFailure]
    public var notes: [BatchNote]
    public var cancelled: Bool
    /// One entry per written file (same order as `written`).
    public var entries: [BatchResultEntry]

    /// Source bytes of the written files.
    public var inputBytes: Int { entries.reduce(0) { $0 + $1.inputBytes } }
    /// Output bytes of the written files.
    public var outputBytes: Int { entries.reduce(0) { $0 + $1.outputBytes } }

    public init(written: [URL] = [], failures: [BatchFailure] = [], notes: [BatchNote] = [], cancelled: Bool = false,
                entries: [BatchResultEntry] = []) {
        self.written = written
        self.failures = failures
        self.notes = notes
        self.cancelled = cancelled
        self.entries = entries
    }
}

/// What one item encodes to, before it is committed.
struct EncodedItem {
    let data: Data
    /// The upright full-size image as loaded.
    let source: CGImage
    /// The quality the compression mode chose; nil for formats without one.
    let quality: Double?
    let note: String?
}

/// A written file and its note, if any.
struct WrittenItem {
    let url: URL
    let note: String?
    let inputBytes: Int
    let outputBytes: Int
}

public enum BatchRunner {
    /// A quarter of physical memory at about 12 bytes per pixel (a decoded copy plus working copies).
    public static let defaultMemoryBudgetPixels = Int(ProcessInfo.processInfo.physicalMemory / 4 / 12)

    /// Converts `items` in parallel (at most `concurrency` at a time, and while their combined pixel
    /// count stays within `memoryBudgetPixels`; a single oversized image still runs, alone). A file that fails is
    /// recorded and skipped; the rest carry on. `progress` is called once per finished item, in
    /// completion order (not input order), from the collecting side of the batch; `completed`
    /// (successes plus failures) increases monotonically. `BatchReport.cancelled` is false if
    /// cancellation arrives after the last item was scheduled. Cancelling the calling task stops new files
    /// from starting; files already in flight stop between compression search encodes (nothing written,
    /// and the report is then `cancelled`) or finish their atomic commit, so no temp files remain.
    public static func run(
        _ items: [InputItem],
        pipeline: Pipeline,
        mode: OutputMode,
        maxPixels: Int = 250_000_000,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryBudgetPixels: Int = BatchRunner.defaultMemoryBudgetPixels,
        trash: @escaping Trasher = systemTrash,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async -> BatchReport {
        let baseNames = renderedBaseNames(items, pipeline: pipeline)
        if baseNames == nil, pipeline.rename.isActive { return BatchReport(cancelled: true) }
        let plans = OutputPlanner.plan(items, format: pipeline.output.format, mode: mode, baseNames: baseNames)
        let total = plans.count
        if Task.isCancelled { return BatchReport(cancelled: true) }
        let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
        let missingAsset = assets.hasMissing(for: pipeline)
        var window = WorkWindow(maxItems: max(1, concurrency), maxWeight: memoryBudgetPixels)
        var weights = [Int](repeating: 1, count: total)
        var outcomes = [Result<WrittenItem?, ConversionError>?](repeating: nil, count: total)
        var cancelled = false

        await withTaskGroup(of: (Int, Result<WrittenItem?, ConversionError>).self) { group in
            var next = 0
            var completed = 0
            var failed = 0

            while true {
                while next < total {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    let index = next
                    let plan = plans[index]
                    let weight = weight(of: plan, pipeline: pipeline)
                    guard window.canStart(weight: weight) else { break }
                    weights[index] = weight
                    window.start(weight: weight)
                    next += 1
                    group.addTask {
                        // A watermark image that can't be read fails every file, before any source is decoded.
                        if missingAsset { return (index, .failure(.watermarkImageUnreadable)) }
                        return (index, convert(plan, pipeline: pipeline, assets: assets, maxPixels: maxPixels,
                                               trash: trash))
                    }
                }
                if cancelled { next = total }
                guard let (index, result) = await group.next() else { break }
                window.finish(weight: weights[index])
                outcomes[index] = result
                // Nil: cancelled during its compression search, before anything was written.
                if case .success(nil) = result {
                    cancelled = true
                    continue
                }
                completed += 1
                failed += result.isFailure ? 1 : 0
                progress(BatchProgress(completed: completed, failed: failed, total: total))
            }
        }

        return makeReport(plans: plans, outcomes: outcomes, cancelled: cancelled)
    }

    /// Peak pixels of one item, from a header-only read; unreadable files weigh 1 and fail later in `convert`.
    private static func weight(of plan: PlannedOutput, pipeline: Pipeline) -> Int {
        max(1, ImageLoader.pixelSize(of: plan.item.source).map {
            pipeline.peakPixels(sourceWidth: $0.width, sourceHeight: $0.height)
        } ?? 1)
    }

    /// Renders the rename template for every item, serially in input order (the counter depends on
    /// it). Nil when renaming is off, or when the task is cancelled part-way (nothing is written then).
    /// The header and creation date are only read when the template uses them.
    private static func renderedBaseNames(_ items: [InputItem], pipeline: Pipeline) -> [String]? {
        guard pipeline.rename.isActive else { return nil }
        var names: [String] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled { return nil }
            guard let name = RenameRendering.baseName(for: item, index: index, pipeline: pipeline) else { return nil }
            names.append(name)
        }
        return names
    }

    private static func makeReport(
        plans: [PlannedOutput], outcomes: [Result<WrittenItem?, ConversionError>?], cancelled: Bool
    ) -> BatchReport {
        var report = BatchReport(cancelled: cancelled)
        for (plan, outcome) in zip(plans, outcomes) {
            switch outcome {
            case .success(let item?):
                report.written.append(item.url)
                if let note = item.note { report.notes.append(BatchNote(source: plan.item.source, text: note)) }
                report.entries.append(BatchResultEntry(
                    source: plan.item.source, destination: item.url, inputBytes: item.inputBytes,
                    outputBytes: item.outputBytes, note: item.note))
            case .failure(let error):
                report.failures.append(BatchFailure(source: plan.item.source, reason: error.reason))
            case .success(nil), nil: break
            }
        }
        return report
    }

    private static func convert(
        _ plan: PlannedOutput, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int, trash: Trasher
    ) -> Result<WrittenItem?, ConversionError> {
        autoreleasepool {
            do {
                // Read before the commit: overwrite mode replaces the source.
                let inputBytes = fileSize(plan.item.source)
                let encoded = try encodeItem(plan.item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels)
                try FileCommitter.commit(encoded.data, for: plan, trash: trash)
                return .success(WrittenItem(url: plan.destination, note: encoded.note,
                                            inputBytes: inputBytes, outputBytes: encoded.data.count))
            } catch is CancellationError {
                return .success(nil)
            } catch let error as ConversionError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// Load, apply, metadata and encode for one file: everything the batch does before it commits.
    /// The size estimate shares it so the estimate can't drift from what is written.
    static func encodeItem(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int
    ) throws -> EncodedItem {
        // A watermark image that can't be read fails the file before its source is decoded.
        if assets.hasMissing(for: pipeline) { throw ConversionError.watermarkImageUnreadable }
        let loaded = try ImageLoader.load(url, maxPixels: maxPixels)
        let image = try pipeline.apply(to: loaded.image, assets: assets)
        let properties = MetadataOps.apply(pipeline.metadata, to: loaded.properties)
        let result = try CompressionSearch.encode(image, properties: properties, settings: pipeline.output)
        return EncodedItem(data: result.data, source: loaded.image, quality: result.quality, note: result.note)
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
