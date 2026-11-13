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

    /// A decoded pixel, components as 0-255.
    struct Pixel {
        let red: Double, green: Double, blue: Double, alpha: Double
    }

    /// A deterministic pseudo-random image (compresses badly, so quality changes file size).
    static func noise(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info),
              let base = ctx.data else { fatalError("Couldn't create a bitmap context") }
        let bytes = base.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * ctx.bytesPerRow + col * 4
                for channel in 0..<3 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    bytes[offset + channel] = UInt8(truncatingIfNeeded: state >> 33)
                }
                bytes[offset + 3] = 255
            }
        }
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    /// Decodes `data` and returns the RGBA pixel at (x, y), top-left origin.
    static func pixel(of data: Data, x column: Int, y row: Int) throws -> Pixel {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var buf = [UInt8](repeating: 0, count: 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else {
            throw CocoaError(.fileReadUnknown)
        }
        ctx.draw(image, in: CGRect(x: -column, y: row - image.height + 1, width: image.width, height: image.height))
        let alphaValue = Double(buf[3])
        let unpremultiply: (UInt8) -> Double = { alphaValue > 0 ? min(255, Double($0) * 255 / alphaValue) : 0 }
        return Pixel(red: unpremultiply(buf[0]), green: unpremultiply(buf[1]),
                     blue: unpremultiply(buf[2]), alpha: alphaValue)
    }

    /// The property dictionary of the first image in `data`.
    static func properties(of data: Data) throws -> [String: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return props
    }
}
