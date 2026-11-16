import CoreGraphics
import Foundation
import ImageIO

/// What one item encodes to, before it is committed.
struct EncodedItem {
    let data: Data
    /// The upright image as decoded (smaller than the file when the decode hint applied, see `downsampled`);
    /// nil for a lossless metadata-only copy, which never decodes (`LosslessMetadata`).
    let source: CGImage?
    /// True when `source` was decoded below full size (`Pipeline.decodeHint`).
    let downsampled: Bool
    /// The quality the compression mode chose; nil for formats without one.
    let quality: Double?
    let note: String?
    /// The date taken as written, when the Metadata step sets file dates (nil: none written).
    var dateTaken: Date?
    /// The extra outputs, encoded from the same processed image, in order.
    var variants: [EncodedVariant] = []
}

/// A written file and its note, if any.
struct WrittenItem {
    let url: URL
    var note: String?
    let inputBytes: Int?
    let outputBytes: Int
    var inputSize: (width: Int, height: Int)?
    var outputSize: (width: Int, height: Int)?
    /// The extra outputs written after this one, and those that failed.
    var extras: [WrittenExtra] = []
    var extraFailures: [BatchExtraFailure] = []
    /// The note needs attention (`ReportEntry.warning`); extra outputs of the item share it.
    var warning = false
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
    /// destination folders (over an hour old, exact `FileCommitter` pattern) are removed; after a cancel, every
    /// temp file of that pattern in them over a minute old that this process isn't writing (`FileCommitter.cleanUp`).
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
        presets: PresetLibrary = .standard,
        enlarger: any SuperResolutionScaler = SystemSuperResolution.shared,
        altText: any AltTextGenerator = AltText.standardGenerator,
        variantFolders: VariantFolderPolicy = .confirmedOnly,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in },
        events: @escaping @Sendable (ItemEvent) -> Void = { _ in }
    ) async -> BatchReport {
        var hooks = BatchHooks()
        hooks.enlarger = enlarger
        hooks.altText = altText
        hooks.variantFolders = variantFolders
        return await run(items, pipeline: pipeline, mode: mode, maxPixels: maxPixels, concurrency: concurrency,
                         memoryBudgetPixels: memoryBudgetPixels, trash: trash, control: control, journal: journal,
                         presets: presets, hooks: hooks, progress: progress, events: events)
    }

    /// Peak pixels of one item, from a header-only read; unreadable files weigh 1 and fail later in `convert`.
    /// The smaller downsampled weight is used only when the decode hint applies and the file is a format ImageIO
    /// decodes at the reduced size directly (`decodesAtReducedSize`); anything else may hold the full image
    /// while decoding, so it keeps the full-size weight and the budget never under-counts.
    static func weight(of plan: PlannedOutput, pipeline: Pipeline) -> Int {
        guard let size = ImageLoader.pixelSize(of: plan.item.source) else { return 1 }
        if let hint = pipeline.decodeHint(sourceWidth: size.width, sourceHeight: size.height),
           decodesAtReducedSize(plan.item.source) {
            let decoded = hint.decodedSize(sourceWidth: size.width, sourceHeight: size.height)
            var hinted = hint.pipeline
            hinted.extraOutputs = pipeline.extraOutputs
            return max(1, hinted.peakPixelsWithVariants(sourceWidth: decoded.width, sourceHeight: decoded.height))
        }
        return max(1, pipeline.peakPixelsWithVariants(sourceWidth: size.width, sourceHeight: size.height))
    }

    /// Formats ImageIO decodes at reduced size (shared with the decode limits' memory check).
    static var reducedSizeDecodeTypes: Set<String> { DecodeLimits.reducedSizeDecodeTypes }

    /// The file's actual format from its content (not its extension).
    static func decodesAtReducedSize(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { return false }
        return reducedSizeDecodeTypes.contains(type)
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
                entry.warning = item.warning
                (entry.inputWidth, entry.inputHeight) = (item.inputSize?.width, item.inputSize?.height)
                (entry.outputWidth, entry.outputHeight) = (item.outputSize?.width, item.outputSize?.height)
                report.entries.append(entry)
                for extra in item.extras {
                    report.written.append(extra.url)
                    var extraEntry = extra.entry(source: plan.item.source, primary: item)
                    extraEntry.warning = item.warning
                    report.entries.append(extraEntry)
                }
                report.extraFailures += item.extraFailures
            case .failure(let error) where error.outputWasCommitted:
                // Saved, only the Trash failed: a written file with a warning, so a job records the new file as an
                // output and the original's version as done (it would otherwise rename its own output again).
                // The note is the detail itself: "Converted, but couldn't move the original to the Trash: …".
                let warning = if case .writeFailed(let detail) = error { detail } else { error.reason }
                report.order.append(plan.item.source)
                report.written.append(plan.destination)
                report.notes.append(BatchNote(source: plan.item.source, text: warning))
                var entry = BatchResultEntry(
                    source: plan.item.source, destination: plan.destination, inputBytes: inputSizes[index],
                    outputBytes: fileSize(plan.destination) ?? 0, note: warning)
                entry.duration = index < durations.count ? durations[index] : 0
                entry.warning = true
                report.entries.append(entry)
            case .failure(let error):
                report.order.append(plan.item.source)
                var failure = BatchFailure(source: plan.item.source, reason: error.reason, inputBytes: inputSizes[index])
                failure.duration = index < durations.count ? durations[index] : 0
                failure.awaitsModelDownload = error.awaitsModelDownload
                report.failures.append(failure)
            case .success(nil), nil: break
            }
        }
        return report
    }

    /// Encodes the item and its extra outputs (`variants`, planned with it), then commits the primary output and,
    /// only once it is in place, each extra output (a new file each). In overwrite mode the original goes to the
    /// Trash last, after the extra outputs; if that fails, everything stays written and the item has a warning.
    static func convert(
        _ plan: PlannedOutput, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int, trash: Trasher,
        options: ItemRunOptions = ItemRunOptions(), variants: [PlannedVariant] = []
    ) -> (Result<WrittenItem?, ConversionError>, Int?) {
        // Read on the worker, before overwrite mode replaces the source.
        let inputBytes = fileSize(plan.item.source)
        let inputSize = ImageLoader.pixelSize(of: plan.item.source)
        return (autoreleasepool { () -> Result<WrittenItem?, ConversionError> in
            do {
                let encoded = try encodeItem(plan.item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels,
                                             options: options, variants: variants.map(\.variant))
                let setsDates = pipeline.metadata.isActive && pipeline.metadata.setFileDates
                // Read before the commit: overwrite mode replaces or trashes the source.
                let sourceDates = setsDates ? fileDates(plan.item.source) : nil
                options.stage(.writing)
                let primary = PlannedOutput(item: plan.item, destination: plan.destination,
                                            replacesSource: plan.replacesSource, trashesSource: false)
                try FileCommitter.commit(encoded.data, for: primary, trash: trash)
                var notes = [encoded.note].compactMap { $0 }
                if setsDates, let failure = setFileDates(of: plan.destination, taken: encoded.dateTaken,
                                                         source: sourceDates) {
                    notes.append(failure)
                }
                let setDates: ((URL, Date?) -> String?)? = setsDates
                    ? { setFileDates(of: $0, taken: $1, source: sourceDates) } : nil
                let (extras, extraFailures) = commitVariants(encoded.variants, planned: variants, item: plan.item,
                                                             trash: trash, setDates: setDates)
                notes += extraFailures.map(\.message)
                var trashFailed = false
                if plan.trashesSource {
                    do { try trash(plan.item.source) } catch {
                        // Saved, only the Trash failed: the warning leads the note.
                        notes.insert(FileCommitter.trashFailurePrefix + error.localizedDescription, at: 0)
                        trashFailed = true
                    }
                }
                var written = WrittenItem(url: plan.destination, note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                                          inputBytes: inputBytes, outputBytes: encoded.data.count)
                written.inputSize = inputSize
                written.outputSize = ImageLoader.pixelSize(of: encoded.data)
                written.extras = extras
                written.extraFailures = extraFailures
                written.warning = trashFailed
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
        /// The generated alt text written with every output of the item (nil: none asked for, or it failed).
        var altText: String?
        /// What the output properties are made from, so an extra output can make its own (its format's DPI keys).
        var sourceProperties: [String: Any] = [:]
        var sourceMetadata: CGImageMetadata?
        var sourceWidth = 0
        var sourceHeight = 0

        /// The metadata properties `pipeline` writes for this item.
        func properties(for pipeline: Pipeline) -> [String: Any] {
            pipeline.withGeneratedAltText(altText)
                .outputProperties(from: sourceProperties, metadata: sourceMetadata, sourceWidth: sourceWidth,
                                  sourceHeight: sourceHeight)
        }
    }

    /// Shared by the batch, the size estimate and the quality ladder so none of them can drift: all of them
    /// decode a pipeline that starts by shrinking at twice the target size (`Pipeline.decodeHint`), the one
    /// decision for all three. Metadata, DPI and the pixel guard still use the full-size source.
    ///
    /// Alt text (`altText`, the batch only) is generated after the pixel steps, from the image they made, so a
    /// crop or a Redact step is reflected in what the model sees.
    static func prepare(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int,
        options: ItemRunOptions = ItemRunOptions(), altText: AltTextSlot? = nil
    ) throws -> PreparedItem {
        // A watermark image that can't be read fails the file before its source is decoded.
        if let missing = assets.missingError(for: pipeline) { throw missing }
        options.stage(.decoding)
        let fullSize = ImageLoader.header(of: url)?.uprightSize
        let hint = fullSize.flatMap { pipeline.decodeHint(sourceWidth: $0.width, sourceHeight: $0.height) }
        let loaded = try ImageLoader.load(url, maxPixels: maxPixels, maxLongSide: hint?.maxLongSide,
                                          includeMetadata: pipeline.effectiveMetadata.isActive,
                                          lowMemory: options.lowMemory)
        options.stage(.processing)
        var stepNotes: [String] = []
        let textContext = pipeline.watermarkTextContext(source: url, properties: loaded.properties)
        let image = try (hint?.pipeline ?? pipeline).apply(to: loaded.image, assets: assets, textContext: textContext,
                                                           focus: options.focus, notes: &stepNotes)
        let width = hint != nil ? fullSize?.width ?? loaded.image.width : loaded.image.width
        let height = hint != nil ? fullSize?.height ?? loaded.image.height : loaded.image.height
        let generated = try altText?.resolve(pipeline.metadata) { image }
        let (properties, removedFaces) = pipeline.withGeneratedAltText(generated?.text)
            .outputPropertiesNoting(from: loaded.properties, metadata: loaded.metadata,
                                    sourceWidth: width, sourceHeight: height)
        if removedFaces { stepNotes.append(Redaction.faceRegionsRemovedNote) }
        if let note = generated?.note { stepNotes.append(note) }
        var prepared = PreparedItem(source: loaded.image, downsampled: hint != nil, image: image,
                                    properties: properties, notes: stepNotes)
        prepared.altText = generated?.text
        prepared.sourceProperties = loaded.properties
        prepared.sourceMetadata = loaded.metadata
        (prepared.sourceWidth, prepared.sourceHeight) = (width, height)
        return prepared
    }

    /// Load, apply, metadata and encode for one file: everything the batch does before it commits.
    /// The size estimate shares it so the estimate can't drift from what is written. A pipeline that only
    /// changes metadata copies the image data untouched instead (`LosslessMetadata`), or says in the note why
    /// it was re-encoded after all.
    /// `variants` are encoded after the primary output from the same processed image (`encodeVariants`).
    static func encodeItem(
        _ url: URL, pipeline: Pipeline, assets: WatermarkAssets, maxPixels: Int,
        options: ItemRunOptions = ItemRunOptions(), variants: [OutputVariant] = []
    ) throws -> EncodedItem {
        let altText = AltTextSlot(generator: options.altText)
        let preparation = ItemPreparation(altText: altText) {
            try prepare(url, pipeline: pipeline, assets: assets, maxPixels: maxPixels, options: options,
                        altText: altText)
        }
        var encoded = try encodePrimary(url, pipeline: pipeline, maxPixels: maxPixels, options: options,
                                        preparation: preparation)
        encoded.variants = try encodeVariants(variants, url: url, pipeline: pipeline, maxPixels: maxPixels,
                                              preparation: preparation)
        return encoded
    }

    private static func encodePrimary(
        _ url: URL, pipeline: Pipeline, maxPixels: Int, options: ItemRunOptions, preparation: ItemPreparation
    ) throws -> EncodedItem {
        var losslessNote: String?
        if LosslessMetadata.applies(to: pipeline) {
            options.stage(.decoding)
            let (copying, altNote) = try preparation.losslessPipeline(pipeline, url: url)
            switch try LosslessMetadata.write(url, pipeline: copying, maxPixels: maxPixels) {
            case .written(let data, let properties)?:
                options.stage(.encoding)
                try options.beforeEncode?(url, options.attempt)
                let taken = pipeline.metadata.setFileDates ? MetadataDates.dateTaken(in: properties) : nil
                let note = [LosslessMetadata.pixelsUntouchedNote, altNote].compactMap { $0 }.joined(separator: "; ")
                return EncodedItem(data: data, source: nil, downsampled: false, quality: nil,
                                   note: note, dateTaken: taken)
            case .reencode(let note)?: losslessNote = note
            case nil: break
            }
        }
        let prepared = try preparation.get()
        let properties = prepared.properties
        let stepNotes = prepared.notes
        options.stage(.encoding)
        try options.beforeEncode?(url, options.attempt)
        let (image, matteNote) = pipeline.matted(prepared.image, for: pipeline.output.format)
        let result = try CompressionSearch.encode(image, properties: properties, settings: pipeline.output,
                                                 indexedPNG: pipeline.reducesColors)
        let taken = pipeline.metadata.isActive && pipeline.metadata.setFileDates
            ? MetadataDates.dateTaken(in: properties) : nil
        // Step notes (e.g. "No document edges found") come first, then the encoder's.
        let notes = stepNotes + [losslessNote, matteNote, result.note].compactMap { $0 }
        return EncodedItem(data: result.data, source: prepared.source, downsampled: prepared.downsampled,
                           quality: result.quality,
                           note: notes.isEmpty ? nil : notes.joined(separator: "; "), dateTaken: taken)
    }
}

extension BatchRunner {
    static func fileDates(_ url: URL) -> (created: Date?, modified: Date?)? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
            return nil
        }
        return (values.creationDate, values.contentModificationDate)
    }

    /// Sets the written file's creation and modification dates to the date taken, or to the source's own
    /// dates when there is none. Returns a note for the report when that fails (the file itself is fine).
    static func setFileDates(of url: URL, taken: Date?,
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
}

/// How one item is run: low-memory decode, the attempt, and where its stages go. The defaults are what the
/// size estimate and the quality ladder use; the batch only adds the attempt, its hooks and its events.
struct ItemRunOptions {
    var lowMemory = false
    /// 1, or 2 on the end-of-batch retry.
    var attempt = 1
    var beforeEncode: (@Sendable (URL, Int) throws -> Void)?
    var stage: (ItemEvent.Stage) -> Void = { _ in }
    /// Finds a detected crop focus (Vision; tests inject a detector).
    var focus: FocusContext = .system
    /// Writes alt text when the Metadata step asks for it; nil generates none. Only the batch sets it: the size
    /// estimate and the quality ladder leave it nil, since a sentence of XMP doesn't change the size meaningfully
    /// and the model takes seconds per image.
    var altText: (any AltTextGenerator)?
}
