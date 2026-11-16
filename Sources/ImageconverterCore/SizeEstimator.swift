import CoreGraphics
import Foundation
import ImageIO

/// A full-size encode of one item: the original and what the batch would write, for the size
/// readout and the zoomed comparison.
public struct EncodedPreview: @unchecked Sendable {
    /// Byte count of exactly what the batch would write for this item.
    public let bytes: Int
    /// The full-size upright source; nil for a copy of the original, which is never decoded.
    public let original: CGImage?
    /// The encoded bytes decoded again, so encoder artifacts show when zoomed; nil for a copy.
    public let encoded: CGImage?
    /// The quality the compression mode chose; nil for formats without one.
    public let quality: Double?
    /// Something to show with the estimate (a target size it couldn't reach, or that the PNG estimate
    /// is unoptimised).
    public let note: String?
    /// What the output still carries (the privacy scan of the encoded bytes, or of the copied original).
    public let privacy: PrivacyFindings?
    /// The extra outputs' sizes, in order (empty for a copy).
    public var variants: [VariantEstimate] = []
}

/// The estimate of one extra output: exactly what the batch would write for it, or why it can't.
public struct VariantEstimate: Equatable, Sendable {
    public let name: String
    /// Nil when the output can't be made (`failure` says why).
    public let bytes: Int?
    public let failure: String?
    public let note: String?
}

public enum SizeEstimator {
    static let unoptimisedPNGNote = "Optimised PNG may be smaller"

    /// Runs the batch's load, apply, metadata and encode steps for `item`; nothing is written.
    /// PNG optimisation (seven encodes) is left to the batch so the estimate stays quick; the estimate
    /// is then the unoptimised size, which the batch never exceeds, and says so in `note`.
    /// Conditions are resolved for `item` first: a copied original is its own file size (no decode, so no pixel
    /// limit either), and a skipped
    /// item throws `.skippedByCondition`.
    public static func render(
        item: InputItem, pipeline unresolved: Pipeline, maxPixels: Int = ImageLoader.defaultMaxPixels,
        presets: PresetLibrary = .standard, enlarger: any SuperResolutionScaler = SystemSuperResolution.shared
    ) throws -> EncodedPreview {
        let resolved = unresolved.resolved(forSource: item.source, maxPixels: maxPixels, presets: presets)
        switch resolved.disposition {
        case .skip: throw ConversionError.skippedByCondition
        case .copyOriginal:
            guard let bytes = BatchRunner.fileSize(item.source) else { throw ConversionError.unreadable }
            return EncodedPreview(bytes: bytes, original: nil, encoded: nil, quality: nil, note: ConditionalStep.copiedNote,
                                  privacy: PrivacyScanner.scan(item.source))
        case .process: break
        }
        let pipeline = resolved.pipeline
        return try autoreleasepool {
            let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
            var pipeline = pipeline
            var note: String?
            if pipeline.output.format == .png, pipeline.output.optimizePNG {
                pipeline.output.optimizePNG = false
                note = unoptimisedPNGNote
            }
            let variants = OutputVariant.validated(pipeline.extraOutputs).kept.map(withoutPNGOptimising)
            let result = try BatchRunner.encodeItem(item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels,
                                                    options: ItemRunOptions(focus: FocusContext(enlarger: enlarger)),
                                                    variants: variants.map(\.variant))
            let estimates = zip(variants, result.variants).map { estimate($1, unoptimised: $0.unoptimised) }
            let data = result.data
            guard let decodedSource = result.source else {
                // A lossless metadata-only copy: its pixels are the original's, so both views show the original.
                let original = try ImageLoader.load(item.source, maxPixels: maxPixels).image
                var preview = EncodedPreview(bytes: data.count, original: original, encoded: original, quality: nil,
                                             note: FocusResolution.withoutFocusNotes(result.note),
                                             privacy: PrivacyScanner.scan(data: data))
                preview.variants = estimates
                return preview
            }
            // The app encoded this itself, so no file-size heuristic; the hard limits still apply.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  (try? DecodeLimits.standard.check(source, fileBytes: nil)) != nil,
                  let encoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.encodeFailed
            }
            // The comparison views want the full-size original; decode it only when the render didn't.
            let original = result.downsampled
                ? try ImageLoader.load(item.source, maxPixels: maxPixels).image : decodedSource
            var preview = EncodedPreview(bytes: data.count, original: original, encoded: encoded,
                                         quality: result.quality, note: FocusResolution.withoutFocusNotes(result.note) ?? note,
                                         privacy: PrivacyScanner.scan(data: data))
            preview.variants = estimates
            return preview
        }
    }

    /// A PNG output estimated without its seven-encode optimisation, like the primary.
    private static func withoutPNGOptimising(_ variant: OutputVariant) -> (variant: OutputVariant, unoptimised: Bool) {
        guard variant.settings.format == .png, variant.settings.optimizePNG else { return (variant, false) }
        var copy = variant
        copy.settings.optimizePNG = false
        return (copy, true)
    }

    private static func estimate(_ encoded: EncodedVariant, unoptimised: Bool) -> VariantEstimate {
        switch encoded.outcome {
        case .success(let item):
            return VariantEstimate(name: encoded.variant.displayName, bytes: item.data.count, failure: nil,
                                   note: item.note ?? (unoptimised ? unoptimisedPNGNote : nil))
        case .failure(let error):
            return VariantEstimate(name: encoded.variant.displayName, bytes: nil, failure: error.reason, note: nil)
        }
    }

    /// "Primary 1.1 MB · Thumbnail 48 KB · Web 620 KB"; nil without extra outputs.
    public static func variantLine(primary: Int, variants: [VariantEstimate]) -> String? {
        guard !variants.isEmpty else { return nil }
        let parts = variants.map { "\($0.name) \($0.bytes.map(SizeFormat.bytes) ?? "—")" }
        return (["Primary \(SizeFormat.bytes(primary))"] + parts).joined(separator: " · ")
    }
}
