import CoreGraphics
import Foundation
import ImageIO

/// A full-size encode of one item: the original and what the batch would write, for the size
/// readout and the zoomed comparison.
public struct EncodedPreview: @unchecked Sendable {
    /// Byte count of exactly what the batch would write for this item.
    public let bytes: Int
    /// The full-size upright source.
    public let original: CGImage
    /// The encoded bytes decoded again, so encoder artifacts show when zoomed.
    public let encoded: CGImage
    /// The quality the compression mode chose; nil for formats without one.
    public let quality: Double?
    /// Something to show with the estimate (a target size it couldn't reach, or that the PNG estimate
    /// is unoptimised).
    public let note: String?
}

public enum SizeEstimator {
    static let unoptimisedPNGNote = "Optimised PNG may be smaller"

    /// Runs the batch's load, apply, metadata and encode steps for `item`; nothing is written.
    /// PNG optimisation (seven encodes) is left to the batch so the estimate stays quick; the estimate
    /// is then the unoptimised size, which the batch never exceeds, and says so in `note`.
    public static func render(
        item: InputItem, pipeline: Pipeline, maxPixels: Int = ImageLoader.defaultMaxPixels
    ) throws -> EncodedPreview {
        try autoreleasepool {
            let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
            var pipeline = pipeline
            var note: String?
            if pipeline.output.format == .png, pipeline.output.optimizePNG {
                pipeline.output.optimizePNG = false
                note = unoptimisedPNGNote
            }
            let result = try BatchRunner.encodeItem(item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels)
            let data = result.data
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let encoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.encodeFailed
            }
            return EncodedPreview(bytes: data.count, original: result.source, encoded: encoded,
                                  quality: result.quality, note: result.note ?? note)
        }
    }
}
