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
    /// Seconds the worker spent on the file (0 when unknown); set by the runner after the fact.
    public var duration: Double = 0

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
    /// Seconds the worker spent on the file, and the pixel sizes read before and after (set by the runner).
    public var duration: Double = 0
    public var inputWidth: Int?
    public var inputHeight: Int?
    public var outputWidth: Int?
    public var outputHeight: Int?

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
    /// The upright image as decoded (smaller than the file when the decode hint applied, see `downsampled`).
    let source: CGImage
    /// True when `source` was decoded below full size (`Pipeline.decodeHint`).
    let downsampled: Bool
    /// The quality the compression mode chose; nil for formats without one.
    let quality: Double?
    let note: String?
    /// The date taken as written, when the Metadata step sets file dates (nil: none written).
    var dateTaken: Date?
}

/// A written file and its note, if any.
struct WrittenItem {
    let url: URL
    var note: String?
    let inputBytes: Int?
    let outputBytes: Int
    var inputSize: (width: Int, height: Int)?
    var outputSize: (width: Int, height: Int)?
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
    /// When the decode hint applies, the peak of the hinted pipeline on the smaller decoded image (ImageIO
    /// decodes JPEG and HEIC at the reduced size directly; other formats may briefly need more while decoding).
    static func weight(of plan: PlannedOutput, pipeline: Pipeline) -> Int {
        guard let size = ImageLoader.pixelSize(of: plan.item.source) else { return 1 }
        if let hint = pipeline.decodeHint(sourceWidth: size.width, sourceHeight: size.height) {
            let decoded = hint.decodedSize(sourceWidth: size.width, sourceHeight: size.height)
            return max(1, hint.pipeline.peakPixels(sourceWidth: decoded.width, sourceHeight: decoded.height))
        }
        return max(1, pipeline.peakPixels(sourceWidth: size.width, sourceHeight: size.height))
    }

    static func makeReport(
        plans: [PlannedOutput], outcomes: [Result<WrittenItem?, ConversionError>?], inputSizes: [Int?],
        cancelled: Bool, durations: [TimeInterval] = []
    ) -> BatchReport {
        var report = BatchReport(cancelled: cancelled)
        for (index, (plan, outcome)) in zip(plans, outcomes).enumerated() {
            switch outcome {
            case .success(let item?):
                report.order.append(plan.item.source)
                report.written.append(item.url)
                if let note = item.note { report.notes.append(BatchNote(source: plan.item.source, text: note)) }
                var entry = BatchResultEntry(
                    source: plan.item.source, destination: item.url, inputBytes: item.inputBytes,
                    outputBytes: item.outputBytes, note: item.note)
                entry.duration = index < durations.count ? durations[index] : 0
                (entry.inputWidth, entry.inputHeight) = (item.inputSize?.width, item.inputSize?.height)
                (entry.outputWidth, entry.outputHeight) = (item.outputSize?.width, item.outputSize?.height)
                report.entries.append(entry)
            case .failure(let error):
                report.order.append(plan.item.source)
                var failure = BatchFailure(source: plan.item.source, reason: error.reason, inputBytes: inputSizes[index])
                failure.duration = index < durations.count ? durations[index] : 0
                report.failures.append(failure)
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
        let inputSize = ImageLoader.pixelSize(of: plan.item.source)
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
                var written = WrittenItem(url: plan.destination, note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                                          inputBytes: inputBytes, outputBytes: encoded.data.count)
                written.inputSize = inputSize
                written.outputSize = ImageLoader.pixelSize(of: encoded.data)
                return .success(written)
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
        let downsampled: Bool
        /// The pipeline's output image.
        let image: CGImage
        /// Output metadata properties.
        let properties: [String: Any]
        /// Step notes (e.g. "No document edges found").
        let notes: [String]
    }

    /// Shared by the batch, the size estimate and the quality ladder so none of them can drift: all of them
    /// decode a pipeline that starts by shrinking at twice the target size (`Pipeline.decodeHint`), the one
    /// decision for all three. Metadata, DPI and the pixel guard still use the full-size source.
    static func prepare(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int,
        options: ItemRunOptions = ItemRunOptions()
    ) throws -> PreparedItem {
        // A watermark image that can't be read fails the file before its source is decoded.
        if let missing = assets.missingError(for: pipeline) { throw missing }
        options.stage(.decoding)
        let fullSize = ImageLoader.header(of: url)?.uprightSize
        let hint = fullSize.flatMap { pipeline.decodeHint(sourceWidth: $0.width, sourceHeight: $0.height) }
        let loaded = try ImageLoader.load(url, maxPixels: maxPixels, maxLongSide: hint?.maxLongSide,
                                          includeMetadata: pipeline.metadata.isActive, lowMemory: options.lowMemory)
        options.stage(.processing)
        var stepNotes: [String] = []
        let textContext = pipeline.watermarkTextContext(source: url, properties: loaded.properties)
        let image = try (hint?.pipeline ?? pipeline).apply(to: loaded.image, assets: assets, textContext: textContext,
                                                           notes: &stepNotes)
        let width = hint != nil ? fullSize?.width ?? loaded.image.width : loaded.image.width
        let height = hint != nil ? fullSize?.height ?? loaded.image.height : loaded.image.height
        let properties = pipeline.outputProperties(from: loaded.properties, metadata: loaded.metadata,
                                                   sourceWidth: width, sourceHeight: height)
        return PreparedItem(source: loaded.image, downsampled: hint != nil, image: image, properties: properties,
                            notes: stepNotes)
    }

    /// Load, apply, metadata and encode for one file: everything the batch does before it commits.
    /// The size estimate shares it so the estimate can't drift from what is written.
    static func encodeItem(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int,
        options: ItemRunOptions = ItemRunOptions()
    ) throws -> EncodedItem {
        let prepared = try prepare(url, pipeline: pipeline, assets: assets, maxPixels: maxPixels, options: options)
        let properties = prepared.properties
        let stepNotes = prepared.notes
        options.stage(.encoding)
        try options.beforeEncode?(url, options.attempt)
        let result = try CompressionSearch.encode(prepared.image, properties: properties, settings: pipeline.output)
        let taken = pipeline.metadata.isActive && pipeline.metadata.setFileDates
            ? MetadataDates.dateTaken(in: properties) : nil
        // Step notes (e.g. "No document edges found") come first, then the encoder's.
        let notes = stepNotes + [result.note].compactMap { $0 }
        return EncodedItem(data: result.data, source: prepared.source, downsampled: prepared.downsampled,
                           quality: result.quality,
                           note: notes.isEmpty ? nil : notes.joined(separator: "; "), dateTaken: taken)
    }
}

/// How one item is run: low-memory decode, the attempt, and where its stages go. The defaults are what the
/// size estimate and the quality ladder use; the batch only adds the attempt, its hooks and its events.
struct ItemRunOptions {
    var lowMemory = false
    /// 1, or 2 on the end-of-batch retry.
    var attempt = 1
    var beforeEncode: (@Sendable (URL, Int) throws -> Void)?
    var stage: (ItemEvent.Stage) -> Void = { _ in }
}
