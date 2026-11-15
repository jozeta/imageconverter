import CoreGraphics
import Foundation

/// One extra output as encoded: its data, or why it couldn't be made.
struct EncodedVariant {
    let variant: OutputVariant
    let outcome: Result<EncodedItem, ConversionError>
}

/// An extra output that was written.
struct WrittenExtra {
    let url: URL
    /// The output's label (`OutputVariant.displayName`).
    let name: String
    let outputBytes: Int
    var outputSize: (width: Int, height: Int)?
    var note: String?

    /// Its report line: the source and input of the primary output, its own destination, size and note.
    func entry(source: URL, primary: WrittenItem) -> BatchResultEntry {
        var entry = BatchResultEntry(source: source, destination: url, inputBytes: primary.inputBytes,
                                     outputBytes: outputBytes, note: note)
        entry.variant = name
        (entry.inputWidth, entry.inputHeight) = (primary.inputSize?.width, primary.inputSize?.height)
        (entry.outputWidth, entry.outputHeight) = (outputSize?.width, outputSize?.height)
        return entry
    }
}

/// The batch's load and pipeline for one item, run at most once however many outputs ask for it (the primary
/// may not need it at all: a lossless metadata copy never decodes). A failure is kept and given to every asker.
final class ItemPreparation {
    private let make: () throws -> BatchRunner.PreparedItem
    private var result: Result<BatchRunner.PreparedItem, Error>?

    init(_ make: @escaping () throws -> BatchRunner.PreparedItem) {
        self.make = make
    }

    func get() throws -> BatchRunner.PreparedItem {
        if let result { return try result.get() }
        let made = Result { try make() }
        result = made
        return try made.get()
    }
}

extension BatchRunner {
    /// The note on an item whose extra output couldn't be made or saved; the item itself is still written.
    static func variantFailedNote(_ name: String, reason: String) -> String {
        "Extra output “\(name)” failed: \(reason)"
    }

    /// `pipeline` as it applies to one extra output: its settings as the output, its resize as a last step (so the
    /// lossless metadata copy only applies when the output keeps the size), no extra outputs of its own.
    static func pipeline(_ pipeline: Pipeline, for variant: OutputVariant) -> Pipeline {
        var copy = pipeline
        copy.output = variant.settings
        copy.extraOutputs = []
        if let resize = variant.resize { copy.steps.append(PipelineStep(operation: .resize(resize.resizeOptions))) }
        return copy
    }

    /// Encodes each extra output in turn, from the item's processed image (decoded and processed once, shared
    /// with the primary output), resized when the output says so, with its own compression search. One that fails
    /// is recorded and the rest carry on; cancelling stops them all (nothing is written then).
    static func encodeVariants(_ variants: [OutputVariant], url: URL, pipeline: Pipeline, maxPixels: Int,
                               preparation: ItemPreparation) throws -> [EncodedVariant] {
        var encoded: [EncodedVariant] = []
        for variant in variants {
            if Task.isCancelled { throw CancellationError() }
            do {
                let item = try encodeVariant(variant, url: url, pipeline: pipeline, maxPixels: maxPixels,
                                             preparation: preparation)
                encoded.append(EncodedVariant(variant: variant, outcome: .success(item)))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ConversionError {
                encoded.append(EncodedVariant(variant: variant, outcome: .failure(error)))
            } catch {
                encoded.append(EncodedVariant(variant: variant, outcome: .failure(.encodeFailed)))
            }
        }
        return encoded
    }

    private static func encodeVariant(_ variant: OutputVariant, url: URL, pipeline base: Pipeline, maxPixels: Int,
                                      preparation: ItemPreparation) throws -> EncodedItem {
        let pipeline = pipeline(base, for: variant)
        var losslessNote: String?
        if LosslessMetadata.applies(to: pipeline) {
            switch try LosslessMetadata.write(url, pipeline: pipeline, maxPixels: maxPixels) {
            case .written(let data, let properties)?:
                let taken = pipeline.metadata.setFileDates ? MetadataDates.dateTaken(in: properties) : nil
                return EncodedItem(data: data, source: nil, downsampled: false, quality: nil,
                                   note: LosslessMetadata.pixelsUntouchedNote, dateTaken: taken)
            case .reencode(let note)?: losslessNote = note
            case nil: break
            }
        }
        let prepared = try preparation.get()
        let image = try variant.resize.map { try ImageOps.resize(prepared.image, $0.resizeOptions) } ?? prepared.image
        let properties = prepared.properties(for: pipeline)
        let result = try CompressionSearch.encode(image, properties: properties, settings: variant.settings)
        let taken = pipeline.metadata.isActive && pipeline.metadata.setFileDates
            ? MetadataDates.dateTaken(in: properties) : nil
        let notes = [losslessNote, result.note].compactMap { $0 }
        return EncodedItem(data: result.data, source: prepared.source, downsampled: prepared.downsampled,
                           quality: result.quality, note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                           dateTaken: taken)
    }

    /// Commits each encoded extra output to its planned place, in order. Returns the written ones and a note for
    /// each one that failed (to encode or to save).
    static func commitVariants(_ encoded: [EncodedVariant], planned: [PlannedVariant], item: InputItem,
                               setsDates: Bool, sourceDates: (created: Date?, modified: Date?)?)
        -> (written: [WrittenExtra], notes: [String]) {
        var written: [WrittenExtra] = []
        var notes: [String] = []
        for (output, place) in zip(encoded, planned) {
            let name = output.variant.displayName
            do {
                let data = try output.outcome.get()
                try FileCommitter.commit(data.data, for: place.plan(for: item))
                var extra = WrittenExtra(url: place.destination, name: name, outputBytes: data.data.count)
                extra.outputSize = ImageLoader.pixelSize(of: data.data)
                var extraNotes = [data.note].compactMap { $0 }
                if setsDates, let failure = setFileDates(of: place.destination, taken: data.dateTaken,
                                                         source: sourceDates) {
                    extraNotes.append(failure)
                }
                extra.note = extraNotes.isEmpty ? nil : extraNotes.joined(separator: "; ")
                written.append(extra)
            } catch let error as ConversionError {
                notes.append(variantFailedNote(name, reason: error.reason))
            } catch {
                notes.append(variantFailedNote(name, reason: error.localizedDescription))
            }
        }
        return (written, notes)
    }
}

extension Pipeline {
    /// `peakPixels`, plus what the extra outputs hold at once: the processed image stays while each output is
    /// resized from it (one at a time), so the heaviest output's resize counts on top of the output image.
    public func peakPixelsWithVariants(sourceWidth: Int, sourceHeight: Int) -> Int {
        let peak = peakPixels(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let resizes = extraOutputs.compactMap(\.resize)
        guard !resizes.isEmpty else { return peak }
        let output = outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let size = CGSize(width: output.width, height: output.height)
        let held = Self.pixels(size)
        let extra = resizes.map { resize -> Int in
            let options = resize.resizeOptions
            let target = Self.pixels(Self.size(after: .resize(options), from: size))
            return max(Self.resizeWorkingPixels(input: size, options: options), target)
        }.max() ?? 0
        let (sum, overflow) = held.addingReportingOverflow(extra)
        return max(peak, overflow ? Int.max : sum)
    }
}
