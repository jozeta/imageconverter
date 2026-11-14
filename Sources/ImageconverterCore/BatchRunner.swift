import CoreGraphics
import Foundation

/// How far a batch has got. `completed` counts successes, failures and files skipped by a condition.
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
    /// Size of the source file, read on the worker before it was touched; nil if it couldn't be read.
    public let inputBytes: Int?

    public init(source: URL, reason: String, inputBytes: Int? = nil) {
        self.source = source
        self.reason = reason
        self.inputBytes = inputBytes
    }
}

/// A file a condition left alone: nothing was written for it, and it isn't a failure.
public struct BatchSkip: Equatable, Sendable {
    public let source: URL
    public let reason: String
    public let inputBytes: Int?

    public init(source: URL, reason: String = ConditionalStep.skippedReason, inputBytes: Int? = nil) {
        self.source = source
        self.reason = reason
        self.inputBytes = inputBytes
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
    /// Nil when the source size couldn't be read.
    public let inputBytes: Int?
    public let outputBytes: Int
    public let note: String?

    public init(source: URL, destination: URL, inputBytes: Int?, outputBytes: Int, note: String? = nil) {
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

    /// Every processed file's source, written, failed or skipped, in input order (so reports can interleave them).
    public var order: [URL] = []
    /// Files a condition skipped (in input order); always listed, even when the run was cancelled.
    public var skipped: [BatchSkip] = []

    /// Source bytes of the written files whose size is known (files with an unknown size are left out of both totals).
    public var inputBytes: Int { entries.reduce(0) { $0 + ($1.inputBytes ?? 0) } }
    /// Output bytes of the same files.
    public var outputBytes: Int { entries.filter { $0.inputBytes != nil }.reduce(0) { $0 + $1.outputBytes } }

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
    /// The upright image as decoded (full size unless the batch's decode hint applied).
    let source: CGImage
    /// The quality the compression mode chose; nil for formats without one.
    let quality: Double?
    let note: String?
    /// The date taken as written, when the Metadata step sets file dates (nil: none written).
    var dateTaken: Date?
}

/// A written file and its note, if any.
struct WrittenItem {
    let url: URL
    let note: String?
    let inputBytes: Int?
    let outputBytes: Int
}

public enum BatchRunner {
    /// A quarter of physical memory at about 12 bytes per pixel (a decoded copy plus working copies).
    public static let defaultMemoryBudgetPixels = Int(ProcessInfo.processInfo.physicalMemory / 4 / 12)

    /// Converts `items` in parallel (at most `concurrency` at a time, and while their combined pixel
    /// count stays within `memoryBudgetPixels`; a single oversized image still runs, alone). A file that fails is
    /// recorded and skipped; the rest carry on. A failure that can be transient (decode, processing or encode:
    /// `ConversionError.isRetryable`) is tried once more at the end of the batch, alone and in low-memory mode;
    /// if that works the file's note says "Succeeded on retry". `progress` is called once per finished item, in
    /// completion order (not input order), from the collecting side of the batch; `completed` (successes,
    /// failures, and files a condition skips, which count at once) increases monotonically, and `total` is
    /// `items.count`. `events` reports each item's stages (see `ItemEvent`): `queued`/`skipped`, `done`,
    /// `failed` and `cancelled` from the collecting side, the working stages from the item's worker; one item's
    /// events arrive in order. Conditions are resolved per item before planning. `BatchReport.cancelled` is
    /// false if cancellation arrives after the last item was scheduled. Cancelling the calling task stops new
    /// files from starting; files already in flight stop between compression search encodes (nothing written,
    /// and the report is then `cancelled`) or finish their atomic commit, so no temp files remain.
    ///
    /// The worker count adapts between items: halved when the Mac is hot (`thermalState` serious), one when
    /// critical; a memory warning halves the budget and critical pressure leaves one worker. `control` pauses,
    /// resumes, reorders and switches low-memory mode (2 workers, a quarter of the budget). With `journal`, a
    /// `RunJournal` is kept there for the length of the run. Before planning, temp files a crash left in the
    /// destination folders (over an hour old, exact `FileCommitter` pattern) are removed.
    public static func run(
        _ items: [InputItem],
        pipeline: Pipeline,
        mode: OutputMode,
        maxPixels: Int = 250_000_000,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryBudgetPixels: Int = BatchRunner.defaultMemoryBudgetPixels,
        trash: @escaping Trasher = systemTrash,
        control: BatchControl? = nil,
        journal: URL? = nil,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in },
        events: @escaping @Sendable (ItemEvent) -> Void = { _ in }
    ) async -> BatchReport {
        await run(items, pipeline: pipeline, mode: mode, maxPixels: maxPixels, concurrency: concurrency,
                  memoryBudgetPixels: memoryBudgetPixels, trash: trash, control: control, journal: journal,
                  hooks: BatchHooks(), progress: progress, events: events)
    }

    /// Peak pixels of one item, from a header-only read; unreadable files weigh 1 and fail later in `convert`.
    static func weight(of plan: PlannedOutput, pipeline: Pipeline) -> Int {
        max(1, ImageLoader.pixelSize(of: plan.item.source).map {
            pipeline.peakPixels(sourceWidth: $0.width, sourceHeight: $0.height)
        } ?? 1)
    }

    static func makeReport(
        plans: [PlannedOutput], outcomes: [Result<WrittenItem?, ConversionError>?], inputSizes: [Int?],
        cancelled: Bool
    ) -> BatchReport {
        var report = BatchReport(cancelled: cancelled)
        for (index, (plan, outcome)) in zip(plans, outcomes).enumerated() {
            switch outcome {
            case .success(let item?):
                report.order.append(plan.item.source)
                report.written.append(item.url)
                if let note = item.note { report.notes.append(BatchNote(source: plan.item.source, text: note)) }
                report.entries.append(BatchResultEntry(
                    source: plan.item.source, destination: item.url, inputBytes: item.inputBytes,
                    outputBytes: item.outputBytes, note: item.note))
            case .failure(let error):
                report.order.append(plan.item.source)
                report.failures.append(BatchFailure(source: plan.item.source, reason: error.reason,
                                                    inputBytes: inputSizes[index]))
            case .success(nil), nil: break
            }
        }
        return report
    }

    static func convert(
        _ plan: PlannedOutput, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int, trash: Trasher,
        options: ItemRunOptions = ItemRunOptions()
    ) -> (Result<WrittenItem?, ConversionError>, Int?) {
        // Read on the worker, before overwrite mode replaces the source.
        let inputBytes = fileSize(plan.item.source)
        return (autoreleasepool { () -> Result<WrittenItem?, ConversionError> in
            do {
                let encoded = try encodeItem(plan.item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels,
                                             options: options)
                let setsDates = pipeline.metadata.isActive && pipeline.metadata.setFileDates
                // Read before the commit: overwrite mode replaces or trashes the source.
                let sourceDates = setsDates ? fileDates(plan.item.source) : nil
                options.stage(.writing)
                try FileCommitter.commit(encoded.data, for: plan, trash: trash)
                var notes = [encoded.note].compactMap { $0 }
                if setsDates, let failure = setFileDates(of: plan.destination, taken: encoded.dateTaken,
                                                         source: sourceDates) {
                    notes.append(failure)
                }
                return .success(WrittenItem(url: plan.destination, note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                                            inputBytes: inputBytes, outputBytes: encoded.data.count))
            } catch is CancellationError {
                return .success(nil)
            } catch let error as ConversionError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }, inputBytes)
    }

    private static func fileDates(_ url: URL) -> (created: Date?, modified: Date?)? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
            return nil
        }
        return (values.creationDate, values.contentModificationDate)
    }

    /// Sets the written file's creation and modification dates to the date taken, or to the source's own
    /// dates when there is none. Returns a note for the report when that fails (the file itself is fine).
    private static func setFileDates(of url: URL, taken: Date?,
                                     source: (created: Date?, modified: Date?)?) -> String? {
        var attributes: [FileAttributeKey: Any] = [:]
        if let taken {
            attributes = [.creationDate: taken, .modificationDate: taken]
        } else {
            if let created = source?.created { attributes[.creationDate] = created }
            if let modified = source?.modified { attributes[.modificationDate] = modified }
        }
        guard !attributes.isEmpty else { return nil }
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            return nil
        } catch {
            return "Couldn't set the file dates: \(error.localizedDescription)"
        }
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Everything the batch does to a file before encoding: load, watermark check, pipeline, metadata.
    struct PreparedItem {
        /// The upright image as decoded: full size, or smaller when a decode hint applied.
        let source: CGImage
        /// The pipeline's output image.
        let image: CGImage
        /// Output metadata properties.
        let properties: [String: Any]
        /// Step notes (e.g. "No document edges found").
        let notes: [String]
    }

    /// Shared by the batch, the size estimate and the quality ladder so none of them can drift. With
    /// `downsample` (the batch), a pipeline that starts by shrinking is decoded at twice the target size
    /// (`Pipeline.decodeHint`); metadata, DPI and the pixel guard still use the full-size source.
    static func prepare(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int, downsample: Bool = false,
        lowMemory: Bool = false, stage: (ItemEvent.Stage) -> Void = { _ in }
    ) throws -> PreparedItem {
        // A watermark image that can't be read fails the file before its source is decoded.
        if let missing = assets.missingError(for: pipeline) { throw missing }
        stage(.decoding)
        let header = downsample ? ImageLoader.header(of: url) : nil
        let fullSize = header?.uprightSize
        let hint = fullSize.flatMap { pipeline.decodeHint(sourceWidth: $0.width, sourceHeight: $0.height) }
        let loaded = try ImageLoader.load(url, maxPixels: maxPixels, maxLongSide: hint?.maxLongSide,
                                          includeMetadata: pipeline.metadata.isActive, lowMemory: lowMemory)
        stage(.processing)
        var stepNotes: [String] = []
        let textContext = pipeline.watermarkTextContext(source: url, properties: loaded.properties)
        let image = try (hint?.pipeline ?? pipeline).apply(to: loaded.image, assets: assets, textContext: textContext,
                                                           notes: &stepNotes)
        let width = hint != nil ? fullSize?.width ?? loaded.image.width : loaded.image.width
        let height = hint != nil ? fullSize?.height ?? loaded.image.height : loaded.image.height
        let properties = pipeline.outputProperties(from: loaded.properties, metadata: loaded.metadata,
                                                   sourceWidth: width, sourceHeight: height)
        return PreparedItem(source: loaded.image, image: image, properties: properties, notes: stepNotes)
    }

    /// Load, apply, metadata and encode for one file: everything the batch does before it commits.
    /// The size estimate shares it so the estimate can't drift from what is written.
    static func encodeItem(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int,
        options: ItemRunOptions = ItemRunOptions(downsample: false)
    ) throws -> EncodedItem {
        let prepared = try prepare(url, pipeline: pipeline, assets: assets, maxPixels: maxPixels,
                                   downsample: options.downsample, lowMemory: options.lowMemory, stage: options.stage)
        let properties = prepared.properties
        let stepNotes = prepared.notes
        options.stage(.encoding)
        try options.beforeEncode?(url, options.attempt)
        let result = try CompressionSearch.encode(prepared.image, properties: properties, settings: pipeline.output)
        let taken = pipeline.metadata.isActive && pipeline.metadata.setFileDates
            ? MetadataDates.dateTaken(in: properties) : nil
        // Step notes (e.g. "No document edges found") come first, then the encoder's.
        let notes = stepNotes + [result.note].compactMap { $0 }
        return EncodedItem(data: result.data, source: prepared.source, quality: result.quality,
                           note: notes.isEmpty ? nil : notes.joined(separator: "; "), dateTaken: taken)
    }
}

/// How the batch runs one item: decode options, the attempt, and where its stages go.
struct ItemRunOptions {
    /// Use the pipeline's decode hint (the batch); the estimate and the preview decode at full size.
    var downsample = true
    var lowMemory = false
    /// 1, or 2 on the end-of-batch retry.
    var attempt = 1
    var beforeEncode: (@Sendable (URL, Int) throws -> Void)?
    var stage: (ItemEvent.Stage) -> Void = { _ in }
}
