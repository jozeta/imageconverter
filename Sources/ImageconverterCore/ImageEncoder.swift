import CoreGraphics
import Foundation
import ImageIO

public enum ImageEncoder {
    /// Encodes `image` in `settings.format`, carrying over `properties` (metadata) with orientation reset to 1.
    ///
    /// Stale pixel-size keys are dropped so ImageIO derives the real size from `image`.
    /// Formats without alpha (JPEG, BMP) get transparent pixels flattened onto white.
    public static func encode(_ image: CGImage, properties: [String: Any], settings: OutputSettings) throws -> Data {
        let format = settings.format
        let source = needsOpaque(format) && hasAlpha(image) ? (flattenedOnWhite(image) ?? image) : image

        var props = sanitized(properties)
        if format.supportsQuality {
            let quality = settings.quality.isNaN ? 0.82 : min(1, max(0, settings.quality))
            props[kCGImageDestinationLossyCompressionQuality as String] = quality
        }
        if format == .tiff {
            let tiffKey = kCGImagePropertyTIFFDictionary as String
            var tiff = props[tiffKey] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = settings.tiffCompression == .lzw ? 5 : 1
            props[tiffKey] = tiff
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.encodeFailed
        }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.encodeFailed }
        return data as Data
    }

    private static func needsOpaque(_ format: OutputFormat) -> Bool {
        format == .jpeg || format == .bmp
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Copy of `properties` with orientation 1 and without the (possibly pre-rotation) pixel dimensions.
    private static func sanitized(_ properties: [String: Any]) -> [String: Any] {
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        props.removeValue(forKey: kCGImagePropertyPixelHeight as String)

        let exifKey = kCGImagePropertyExifDictionary as String
        if var exif = props[exifKey] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            props[exifKey] = exif
        }
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        if var tiff = props[tiffKey] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[tiffKey] = tiff
        }
        return props
    }
}
