import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class ImageSimilarityTests: XCTestCase {
    func testSSIMIdenticalIsOne() {
        let img = TestImages.noise(width: 64, height: 48)
        XCTAssertEqual(ImageSimilarity.ssim(img, img), 1, accuracy: 1e-9)
        let flat = TestImages.make(width: 40, height: 40)
        XCTAssertEqual(ImageSimilarity.ssim(flat, flat), 1, accuracy: 1e-9)
    }

    func testSSIMNoisyLower() {
        let clean = CompressionImages.gradient(width: 96, height: 64)
        let light = ImageSimilarity.ssim(clean, CompressionImages.gradient(width: 96, height: 64, noise: 6))
        let heavy = ImageSimilarity.ssim(clean, CompressionImages.gradient(width: 96, height: 64, noise: 40))
        XCTAssertLessThan(light, 1)
        XCTAssertGreaterThan(light, 0.5)
        XCTAssertLessThan(heavy, light)
    }

    func testSSIMUnrelatedImagesScoreLow() {
        let score = ImageSimilarity.ssim(CompressionImages.gradient(width: 96, height: 64),
                                         TestImages.noise(width: 96, height: 64))
        XCTAssertLessThan(score, 0.5)
        XCTAssertGreaterThanOrEqual(score, -1)
    }

    func testSSIMLargeImageIsDownsampled() {
        // 2400 px long edge: compared at ≤ 1024 px, still 1 for identical inputs.
        let img = CompressionImages.gradient(width: 2400, height: 300)
        XCTAssertEqual(ImageSimilarity.ssim(img, img), 1, accuracy: 1e-9)
    }
}

/// Structured test images for compression tests.
enum CompressionImages {
    /// A smooth horizontal gradient (left half) next to a flat area (right half).
    static func gradient(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1),
                                                 CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { fatalError("Couldn't create a context") }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width / 2, y: height), options: [])
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    /// `gradient` with deterministic noise of ±`amplitude` (0-255) added to each colour channel.
    static func gradient(width: Int, height: Int, noise amplitude: Int) -> CGImage {
        let base = gradient(width: width, height: height)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { fatalError("Couldn't create a context") }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        for row in 0..<height {
            for col in 0..<width {
                for channel in 0..<3 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let offset = row * ctx.bytesPerRow + col * 4 + channel
                    let delta = Int(state >> 33) % (2 * amplitude + 1) - amplitude
                    bytes[offset] = UInt8(clamping: Int(bytes[offset]) + delta)
                }
            }
        }
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    /// `gradient` with a soft texture (noise upscaled 4×, 30 % opacity): smart compression lands mid-range on it.
    static func texture(width: Int, height: Int) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Couldn't create a context")
        }
        ctx.draw(gradient(width: width, height: height), in: rect)
        ctx.interpolationQuality = .high
        ctx.setAlpha(0.3)
        ctx.draw(TestImages.noise(width: max(1, width / 4), height: max(1, height / 4)), in: rect)
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    /// Decodes encoded `data` at full size.
    static func decode(_ data: Data) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// Every RGBA byte of the decoded `data`, drawn into one sRGB buffer.
    static func rgbaBytes(of data: Data) throws -> [UInt8] {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
