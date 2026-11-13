import CoreGraphics
import Foundation
import ImageIO

/// Picks the encode quality for `OutputSettings.compression`. Each search step is a full-size encode,
/// so the searches are capped: at most 8 encodes for the size modes, 7 for smart.
public enum CompressionSearch {
    /// The encoded file, the quality chosen (nil for formats without one) and an optional note for the report.
    public typealias Output = (data: Data, quality: Double?, note: String?) // swiftlint:disable:this large_tuple

    static let sizeEncodeBudget = 8
    static let smartEncodeBudget = 7
    /// Size modes stop once the result is within 1 % under the target.
    static let sizeTolerance = 0.01
    static let smartRange = 0.40...0.95
    static let smartThreshold = 0.985

    public static func encode(
        _ image: CGImage, properties: [String: Any], settings: OutputSettings
    ) throws -> Output {
        guard settings.format.supportsQuality else {
            return (try ImageEncoder.encode(image, properties: properties, settings: settings), nil, nil)
        }
        let encoder = Encoder(image: image, properties: properties, settings: settings)
        switch settings.compression {
        case .quality:
            let quality = encoder.clamp(settings.quality)
            return (try encoder.encode(quality), quality, nil)
        case .targetSize(let bytes):
            return try targetSize(bytes, encoder: encoder)
        case .maxSize(let bytes):
            return try maxSize(bytes, start: encoder.clamp(settings.quality), encoder: encoder)
        case .smart:
            return try smart(encoder: encoder)
        }
    }

    private static func targetSize(_ limit: Int, encoder: Encoder) throws -> Output {
        let best = try encoder.encode(1)
        if best.count <= limit { return (best, 1, nil) }
        let smallest = try encoder.encode(0)
        if smallest.count > limit {
            let note = "Couldn't reach \(ByteSize.format(limit)); smallest is \(ByteSize.format(smallest.count))"
            return (smallest, 0, note)
        }
        let found = try bisect(limit: limit, fits: (0, smallest), tooLarge: 1,
                               encodes: sizeEncodeBudget - 2, encoder: encoder)
        return (found.data, found.quality, nil)
    }

    private static func maxSize(
        _ limit: Int, start: Double, encoder: Encoder
    ) throws -> Output {
        let first = try encoder.encode(start)
        if first.count <= limit { return (first, start, nil) }
        let smallest = try encoder.encode(0)
        if smallest.count > limit { throw ConversionError.sizeUnreachable(limit: limit, smallest: smallest.count) }
        let found = try bisect(limit: limit, fits: (0, smallest), tooLarge: start,
                               encodes: sizeEncodeBudget - 2, encoder: encoder)
        return (found.data, found.quality, nil)
    }

    /// Highest quality in (fits.quality, tooLarge) whose size is ≤ `limit`, in at most `encodes` encodes.
    private static func bisect(
        limit: Int, fits: (quality: Double, data: Data), tooLarge: Double, encodes: Int, encoder: Encoder
    ) throws -> (quality: Double, data: Data) {
        var best = fits
        var high = tooLarge
        let closeEnough = Int(Double(limit) * (1 - sizeTolerance))
        for _ in 0..<encodes where best.data.count < closeEnough {
            let mid = (best.quality + high) / 2
            let data = try encoder.encode(mid)
            if data.count <= limit { best = (mid, data) } else { high = mid }
        }
        return best
    }

    /// Lowest quality in `smartRange` whose decoded result has SSIM ≥ `smartThreshold` against `image`.
    private static func smart(encoder: Encoder) throws -> Output {
        let image = encoder.image
        let scale = min(1, Double(ImageSimilarity.maxEdge) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let reference = ImageSimilarity.luma(image, width: width, height: height) else {
            throw ConversionError.encodeFailed
        }
        func looksSame(_ data: Data) -> Bool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let luma = ImageSimilarity.luma(decoded, width: width, height: height) else { return false }
            return ImageSimilarity.ssim(reference, luma, width: width, height: height) >= smartThreshold
        }

        var low = smartRange.lowerBound
        let lowest = try encoder.encode(low)
        if looksSame(lowest) { return (lowest, low, nil) }
        // `low` fails; search towards the top of the range, which is used when nothing below passes.
        var high = smartRange.upperBound
        var best: (quality: Double, data: Data)?
        for _ in 0..<(smartEncodeBudget - 2) {
            let mid = (low + high) / 2
            let data = try encoder.encode(mid)
            if looksSame(data) {
                best = (mid, data)
                high = mid
            } else {
                low = mid
            }
        }
        if let best { return (best.data, best.quality, nil) }
        return (try encoder.encode(smartRange.upperBound), smartRange.upperBound, nil)
    }

    /// One image and its settings, encoded at varying quality.
    private struct Encoder {
        let image: CGImage
        let properties: [String: Any]
        let settings: OutputSettings

        func clamp(_ quality: Double) -> Double {
            quality.isNaN ? 0.82 : min(1, max(0, quality))
        }

        func encode(_ quality: Double) throws -> Data {
            var settings = settings
            settings.quality = quality
            return try ImageEncoder.encode(image, properties: properties, settings: settings)
        }
    }
}
