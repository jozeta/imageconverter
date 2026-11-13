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
}

public enum SizeEstimator {
    /// Runs the batch's load, apply, metadata and encode steps for `item`; nothing is written.
    public static func render(
        item: InputItem, pipeline: Pipeline, maxPixels: Int = ImageLoader.defaultMaxPixels
    ) throws -> EncodedPreview {
        try autoreleasepool {
            let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
            if assets.hasMissing(for: pipeline) { throw ConversionError.watermarkImageUnreadable }
            let (data, original) = try BatchRunner.encodeItem(
                item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let encoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.encodeFailed
            }
            return EncodedPreview(bytes: data.count, original: original, encoded: encoded)
        }
    }
}
