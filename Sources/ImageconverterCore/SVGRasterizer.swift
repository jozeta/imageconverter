import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Turns an SVG watermark into a bitmap. SVG files are untrusted: the file is size-checked, parsed and checked
/// against an allowlist of shapes, gradients and text (`SVGSanitizer`), and only the re-serialised result is
/// drawn by AppKit. Nothing is ever fetched.
public enum SVGRasterizer {
    /// Largest SVG file accepted.
    public static let maxFileSize = 1_048_576
    /// Longest side of the rendered bitmap.
    public static let maxLongSide = 4096

    /// Whether `url` names an SVG file (by extension).
    public static func isSVG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "svg" }

    /// Renders the SVG at `url` with its long side at `maxLongSide` px (fewer when that would exceed
    /// `maxPixels`), keeping its aspect ratio, on a transparent background.
    public static func rasterize(url: URL, maxPixels: Int = ImageLoader.defaultMaxPixels) throws -> CGImage {
        let data = try readLimited(url)
        // Only the sanitised, re-serialised SVG reaches AppKit.
        return try render(try SVGSanitizer.sanitize(data), maxPixels: maxPixels)
    }

    /// Opens without following links or blocking, refuses non-regular files, reads at most the limit + 1 byte.
    static func readLimited(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ConversionError.watermarkImageUnreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ConversionError.watermarkImageUnreadable
        }
        guard info.st_size <= maxFileSize else { throw ConversionError.watermarkSVGTooLarge }
        guard let data = try? handle.read(upToCount: maxFileSize + 1) else {
            throw ConversionError.watermarkImageUnreadable
        }
        guard data.count <= maxFileSize else { throw ConversionError.watermarkSVGTooLarge }
        return data
    }

    static func render(_ data: Data, maxPixels: Int) throws -> CGImage {
        // The content is known to be SVG (`SVGSanitizer`); whether AppKit can draw it is a property of this macOS.
        guard NSImage.imageTypes.contains(UTType.svg.identifier) else { throw ConversionError.watermarkSVGUnsupported }
        guard let image = NSImage(data: data), !image.representations.isEmpty else {
            throw ConversionError.watermarkImageUnreadable
        }
        let natural = image.size
        guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0 else {
            throw ConversionError.watermarkImageUnreadable
        }
        var scale = CGFloat(maxLongSide) / max(natural.width, natural.height)
        let pixels = Double(natural.width * scale) * Double(natural.height * scale)
        if pixels > Double(max(1, maxPixels)) { scale *= CGFloat((Double(max(1, maxPixels)) / pixels).squareRoot()) }
        let width = max(1, Int((natural.width * scale).rounded()))
        let height = max(1, Int((natural.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.watermarkImageUnreadable
        }
        ctx.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = ctx.makeImage() else { throw ConversionError.watermarkImageUnreadable }
        return result
    }
}
