import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Helpers for building and writing small test images.
enum TestImages {
    /// A solid RGBA (premultiplied last) image.
    static func make(width: Int, height: Int,
                     color: CGColor = CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1),
                     alpha: CGFloat = 1) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else {
            fatalError("Couldn't create a bitmap context")
        }
        ctx.setFillColor(color.copy(alpha: alpha) ?? color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    /// Writes `image` to `url` as `type`, with optional image properties (e.g. orientation).
    static func write(_ image: CGImage, to url: URL, type: UTType,
                      properties: [String: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A unique temporary directory; callers remove it in `tearDown`.
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imageconverter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
