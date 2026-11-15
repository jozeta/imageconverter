import CoreGraphics
import Foundation
import ImageIO

/// Renders one image at several fixed qualities, to show where quality stops paying off.
public enum QualityLadder {
    public struct Rung: @unchecked Sendable {
        public let quality: Double
        public let bytes: Int
        /// The encoded file, kept so another region can be cropped without encoding again.
        public let data: Data
        /// The requested region of the encoded bytes decoded again, at most `maxSide` pixels on the longer side.
        public let image: CGImage

        public init(quality: Double, bytes: Int, data: Data, image: CGImage) {
            self.quality = quality
            self.bytes = bytes
            self.data = data
            self.image = image
        }
    }

    public enum LadderError: Error, Equatable {
        /// The source has more pixels than `maxComparePixels`.
        case tooLarge
    }

    /// Above this many source pixels the ladder is refused: four encodes of the full image would need too much memory.
    public static let defaultMaxComparePixels = 100_000_000
    public static let unitRegion = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Loads and applies the pipeline once, then encodes at each quality with the plain quality mode (the
    /// configured compression mode is ignored) and keeps the encoded bytes plus a crop of `region` (unit
    /// coordinates, origin top left) of each decode. Full-size decodes are dropped right away. Empty for formats
    /// without a quality, for items a condition copies or skips, and for metadata-only edits written losslessly.
    public static func render(
        item: InputItem, pipeline: Pipeline, qualities: [Double] = [0.4, 0.6, 0.8, 0.95],
        region: CGRect = unitRegion, maxSide: Int = 1024,
        maxPixels: Int = ImageLoader.defaultMaxPixels, maxComparePixels: Int = defaultMaxComparePixels,
        presets: PresetLibrary = .standard
    ) throws -> [Rung] {
        // A copied or skipped item has no quality to choose.
        let resolved = pipeline.resolved(forSource: item.source, maxPixels: maxPixels, presets: presets)
        guard resolved.disposition == .process else { return [] }
        let pipeline = resolved.pipeline
        // A metadata-only edit copies the image data: the quality isn't used.
        guard pipeline.output.format.supportsQuality, !LosslessMetadata.wouldCopy(item.source, pipeline: pipeline)
        else { return [] }
        if let pixels = ImageLoader.pixelCount(of: item.source), pixels > maxComparePixels { throw LadderError.tooLarge }
        return try autoreleasepool {
            let assets = WatermarkAssets.load(for: pipeline, maxPixels: maxPixels)
            let prepared = try BatchRunner.prepare(item.source, pipeline: pipeline, assets: assets, maxPixels: maxPixels)
            return try qualities.map { quality in
                try Task.checkCancellation()
                return try autoreleasepool {
                    var settings = pipeline.output
                    settings.compression = .quality
                    settings.quality = quality
                    let data = try CompressionSearch.encode(prepared.image, properties: prepared.properties,
                                                            settings: settings).data
                    guard let image = crop(data, region: region, maxSide: maxSide) else { throw ConversionError.encodeFailed }
                    return Rung(quality: quality, bytes: data.count, data: data, image: image)
                }
            }
        }
    }

    /// Decodes `data` and keeps only `region`, at most `maxSide` pixels on the longer side.
    public static func crop(_ data: Data, region: CGRect, maxSide: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              (try? DecodeLimits.standard.check(source, fileBytes: nil)) != nil,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return RegionCrop.draw(decoded, region: region, maxSide: maxSide)
    }
}
