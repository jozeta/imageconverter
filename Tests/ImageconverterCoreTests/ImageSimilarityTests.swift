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
        let noisy = TestImages.noise(width: 96, height: 64)
        let score = ImageSimilarity.ssim(clean, noisy)
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
