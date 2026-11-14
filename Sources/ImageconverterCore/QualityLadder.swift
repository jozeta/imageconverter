import CoreGraphics
import Foundation
import ImageIO

/// Renders one image at several fixed qualities, to show where quality stops paying off.
public enum QualityLadder {
    public struct Rung: @unchecked Sendable {
        public let quality: Double
        public let bytes: Int
        /// The encoded bytes decoded again.
        public let image: CGImage
    }

    /// Loads and applies the pipeline once, then encodes and decodes at each quality with the plain
    /// quality mode (the configured compression mode is ignored). Empty for formats without a quality.
    public static func render(
        item: InputItem, pipeline: Pipeline, qualities: [Double] = [0.4, 0.6, 0.8, 0.95],
        maxPixels: Int = ImageLoader.defaultMaxPixels
    ) throws -> [Rung] {
        guard pipeline.output.format.supportsQuality else { return [] }
        return try autoreleasepool {
            let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
            if assets.hasMissing(for: pipeline) { throw ConversionError.watermarkImageUnreadable }
            let loaded = try ImageLoader.load(item.source, maxPixels: maxPixels,
                                              includeMetadata: pipeline.metadata.isActive)
            var notes: [String] = []
            let image = try pipeline.apply(to: loaded.image, assets: assets, notes: &notes)
            let properties = pipeline.outputProperties(from: loaded.properties, metadata: loaded.metadata,
                                                       sourceWidth: loaded.image.width,
                                                       sourceHeight: loaded.image.height)
            return try qualities.map { quality in
                var settings = pipeline.output
                settings.compression = .quality
                settings.quality = quality
                let data = try CompressionSearch.encode(image, properties: properties, settings: settings).data
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConversionError.encodeFailed
                }
                return Rung(quality: quality, bytes: data.count, image: decoded)
            }
        }
    }
}
