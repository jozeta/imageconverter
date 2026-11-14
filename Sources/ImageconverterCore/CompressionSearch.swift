import CoreGraphics
import Foundation
import ImageIO

/// Picks the encode quality for `OutputSettings.compression`. Each search step is a full-size encode,
/// so the searches are capped: at most 8 encodes for the size modes, 7 for smart. At most two encoded
/// files are kept in memory at once, and cancellation is checked between encodes.
public enum CompressionSearch {
    /// The encoded file, the quality chosen (nil for formats without one) and an optional note for the report.
    public typealias Output = (data: Data, quality: Double?, note: String?) // swiftlint:disable:this large_tuple
    /// Encodes the image at a quality; injectable so tests can count encodes.
    typealias QualityEncoder = (Double) throws -> Data

    static let sizeEncodeBudget = 8
    static let smartEncodeBudget = 7
    /// Size modes stop once the result is within 1 % under the target.
    static let sizeTolerance = 0.01
    static let smartRange = 0.40...0.95
    static let smartThreshold = 0.985

    /// Throws `CancellationError` if the task is cancelled during a search.
    public static func encode(
        _ image: CGImage, properties: [String: Any], settings: OutputSettings
    ) throws -> Output {
        try encode(image, settings: settings) { quality in
            var settings = settings
            settings.quality = quality
            return try ImageEncoder.encode(image, properties: properties, settings: settings)
        }
    }

    static func encode(_ image: CGImage, settings: OutputSettings, encoder: QualityEncoder) throws -> Output {
        guard settings.format.supportsQuality else {
            // The quality is ignored by these formats; the encoder's argument doesn't matter.
            return (try encoder(settings.clampedQuality), nil, nil)
        }
        switch settings.compression {
        case .quality:
            return (try encoder(settings.clampedQuality), settings.clampedQuality, nil)
        case .targetSize(let bytes):
            return try targetSize(bytes, encoder: encoder)
        case .maxSize(let bytes):
            return try maxSize(bytes, start: settings.clampedQuality, encoder: encoder)
        case .smart:
            return try smart(image, encoder: encoder)
        }
    }

    private static func targetSize(_ limit: Int, encoder: QualityEncoder) throws -> Output {
        // Scoped so the full-quality encode is released before the search continues.
        do {
            let best = try encoder(1)
            if best.count <= limit { return (best, 1, nil) }
        }
        try Task.checkCancellation()
        let smallest = try encoder(0)
        if smallest.count > limit {
            let note = "Couldn't reach \(ByteSize.format(limit)); smallest is \(ByteSize.format(smallest.count))"
            return (smallest, 0, note)
        }
        let found = try bisect(limit: limit, fits: (0, smallest), tooLarge: 1,
                               encodes: sizeEncodeBudget - 2, encoder: encoder)
        return (found.data, found.quality, nil)
    }

    private static func maxSize(_ limit: Int, start: Double, encoder: QualityEncoder) throws -> Output {
        let firstSize: Int
        do {
            let first = try encoder(start)
            if first.count <= limit { return (first, start, nil) }
            firstSize = first.count
        }
        // Already at the lowest quality: no need to encode it again.
        if start == 0 { throw ConversionError.sizeUnreachable(limit: limit, smallest: firstSize) }
        try Task.checkCancellation()
        let smallest = try encoder(0)
        if smallest.count > limit { throw ConversionError.sizeUnreachable(limit: limit, smallest: smallest.count) }
        let found = try bisect(limit: limit, fits: (0, smallest), tooLarge: start,
                               encodes: sizeEncodeBudget - 2, encoder: encoder)
        return (found.data, found.quality, nil)
    }

    /// Highest quality in (fits.quality, tooLarge) whose size is ≤ `limit`, in at most `encodes` encodes.
    private static func bisect(
        limit: Int, fits: (quality: Double, data: Data), tooLarge: Double, encodes: Int, encoder: QualityEncoder
    ) throws -> (quality: Double, data: Data) {
        var best = fits
        var high = tooLarge
        let closeEnough = Int(Double(limit) * (1 - sizeTolerance))
        for _ in 0..<encodes where best.data.count < closeEnough {
            try Task.checkCancellation()
            let mid = (best.quality + high) / 2
            let data = try encoder(mid)
            if data.count <= limit { best = (mid, data) } else { high = mid }
        }
        return best
    }

    /// Lowest quality in `smartRange` whose decoded result has SSIM ≥ `smartThreshold` against `image`.
    private static func smart(_ image: CGImage, encoder: QualityEncoder) throws -> Output {
        let (width, height) = ImageSimilarity.comparisonSize(width: image.width, height: image.height)
        guard let reference = ImageSimilarity.luma(image, width: width, height: height) else {
            throw ConversionError.encodeFailed
        }
        func looksSame(_ data: Data) -> Bool {
            // Decode straight to the comparison size rather than a full-size bitmap.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  (try? DecodeLimits.standard.check(source, fileBytes: nil)) != nil,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let luma = ImageSimilarity.luma(decoded, width: width, height: height) else { return false }
            return ImageSimilarity.ssim(reference, luma, width: width, height: height) >= smartThreshold
        }

        var low = smartRange.lowerBound
        do {
            let lowest = try encoder(low)
            if looksSame(lowest) { return (lowest, low, nil) }
        }
        // `low` fails; search towards the top of the range, which is used when nothing below passes.
        var high = smartRange.upperBound
        var best: (quality: Double, data: Data)?
        for _ in 0..<(smartEncodeBudget - 2) {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let data = try encoder(mid)
            if looksSame(data) {
                best = (mid, data)
                high = mid
            } else {
                low = mid
            }
        }
        if let best { return (best.data, best.quality, nil) }
        try Task.checkCancellation()
        return (try encoder(smartRange.upperBound), smartRange.upperBound, nil)
    }
}
