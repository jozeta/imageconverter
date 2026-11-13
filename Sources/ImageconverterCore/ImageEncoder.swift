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
        let source: CGImage
        if needsOpaque(format), ImageOps.hasAlpha(image) {
            guard let flat = flattenedOnWhite(image) else { throw ConversionError.encodeFailed }
            source = flat
        } else {
            source = image
        }

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

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        // Prefer the image's own RGB color space (wide gamut); extended-range spaces can't back an
        // 8-bit context, so fall back to sRGB.
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
        for space in spaces {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            ctx.draw(image, in: rect)
            return ctx.makeImage()
        }
        return nil
    }

    /// Copy of `properties` with orientation 1 and without stale pixel dimensions or color description.
    private static func sanitized(_ properties: [String: Any]) -> [String: Any] {
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        props.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        // Describe the old color; ImageIO derives these from the image being written.
        props.removeValue(forKey: kCGImagePropertyProfileName as String)
        props.removeValue(forKey: kCGImagePropertyColorModel as String)
        props.removeValue(forKey: kCGImagePropertyDepth as String)

        let exifKey = kCGImagePropertyExifDictionary as String
        if var exif = props[exifKey] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifColorSpace as String)
            props[exifKey] = exif
        }
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        if var tiff = props[tiffKey] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[tiffKey] = tiff
        }
        let pngKey = kCGImagePropertyPNGDictionary as String
        if var png = props[pngKey] as? [String: Any] {
            png.removeValue(forKey: kCGImagePropertyPNGGamma as String)
            png.removeValue(forKey: kCGImagePropertyPNGChromaticities as String)
            png.removeValue(forKey: kCGImagePropertyPNGsRGBIntent as String)
            props[pngKey] = png
        }
        return props
    }
}
