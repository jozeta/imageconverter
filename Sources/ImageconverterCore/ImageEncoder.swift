import CoreGraphics
import Foundation
import ImageIO

public enum ImageEncoder {
    /// Encodes `image` in `settings.format`, carrying over `properties` (metadata) with orientation reset to 1.
    /// An `OutputXMP` under `MetadataOps.xmpPropertyKey` is written as the file's XMP; the rest of
    /// `properties` (EXIF, IPTC, GPS, DPI, compression) still applies.
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
            props[kCGImageDestinationLossyCompressionQuality as String] = settings.clampedQuality
        }
        if format == .tiff {
            let tiffKey = kCGImagePropertyTIFFDictionary as String
            var tiff = props[tiffKey] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = settings.tiffCompression == .lzw ? 5 : 1
            props[tiffKey] = tiff
        }

        if format == .jpeg, settings.progressive {
            let jfifKey = kCGImagePropertyJFIFDictionary as String
            var jfif = props[jfifKey] as? [String: Any] ?? [:]
            jfif[kCGImagePropertyJFIFIsProgressive as String] = true
            props[jfifKey] = jfif
        }

        if format == .png, settings.optimizePNG, let best = smallestPNG(source, props: props) { return best }
        return try write(source, props: props, type: format)
    }

    /// The smallest of the PNG filter candidates. Filter choice only changes size, never pixels.
    private static func smallestPNG(_ image: CGImage, props: [String: Any]) -> Data? {
        let pngKey = kCGImagePropertyPNGDictionary as String
        // Raw values of IMAGEIO_PNG_FILTER_* (the "all" macro isn't importable into Swift);
        // nil is ImageIO's own default choice, which is sometimes the smallest.
        let filters: [Int?] = [nil, 0x08, 0x10, 0x20, 0x40, 0x80, 0xF8]
        var best: Data?
        for filter in filters {
            var candidate = props
            if let filter {
                var png = candidate[pngKey] as? [String: Any] ?? [:]
                png[kCGImagePropertyPNGCompressionFilter as String] = filter
                candidate[pngKey] = png
            }
            guard let data = try? write(image, props: candidate, type: .png) else { continue }
            if best == nil || data.count < best!.count { best = data }
        }
        return best
    }

    private static func write(_ image: CGImage, props: [String: Any], type format: OutputFormat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.encodeFailed
        }
        var props = props
        if let xmp = props.removeValue(forKey: MetadataOps.xmpPropertyKey) as? OutputXMP {
            // ImageIO still honours the property dictionaries passed as options here.
            CGImageDestinationAddImageAndMetadata(dest, image, xmp.metadata, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.encodeFailed }
        return data as Data
    }

    private static func needsOpaque(_ format: OutputFormat) -> Bool {
        !format.supportsAlpha
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        flattened(image, onto: .white)
    }

    /// `image` drawn over `matte` (its alpha ignored: opaque) into an opaque 8-bit RGB image.
    static func flattened(_ image: CGImage, onto matte: RGBAColor) -> CGImage? {
        // Prefer the image's own RGB color space (wide gamut); extended-range spaces can't back an
        // 8-bit context, so fall back to sRGB.
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        spaces.append(srgb)
        let clean: (Double) -> CGFloat = { CGFloat($0.isFinite ? min(1, max(0, $0)) : 1) }
        // The matte is an sRGB colour, matched into the context's space.
        guard let color = CGColor(colorSpace: srgb,
                                  components: [clean(matte.red), clean(matte.green), clean(matte.blue), 1]) else {
            return nil
        }
        for space in spaces {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.setFillColor(color)
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
