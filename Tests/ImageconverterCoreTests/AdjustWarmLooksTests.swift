import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// The warm built-in looks must look golden on real photos: warmer (mean red minus blue up) and not greener.
final class AdjustWarmLooksTests: XCTestCase {
    private static let samples = URL(fileURLWithPath: #filePath)
        .appendingPathComponent("../../../docs/screenshots/samples").standardizedFileURL

    private struct Means {
        let red: Double, green: Double, blue: Double
    }

    /// Mean R, G and B (0…255) of `image` drawn into an 8-bit sRGB buffer.
    private func means(_ image: CGImage) throws -> Means {
        let width = min(image.width, 400)
        let height = max(1, image.height * width / image.width)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var red = 0.0, green = 0.0, blue = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index]); green += Double(pixels[index + 1]); blue += Double(pixels[index + 2])
        }
        let count = Double(width * height)
        return Means(red: red / count, green: green / count, blue: blue / count)
    }

    func testWarmLooksAreGoldenOnTheSamplePhotos() throws {
        let warm = ["Golden Hour", "Vivid Warm", "Dramatic Warm"]
        for name in ["meadow.jpg", "sunset.jpg"] {
            let source = try ImageLoader.load(Self.samples.appendingPathComponent(name)).image
            let before = try means(source)
            for look in warm {
                let preset = try XCTUnwrap(AdjustPresets.builtIns.first { $0.name == look })
                let after = try means(try Adjustments.apply(preset.options, to: source))
                let warmer = (after.red - after.blue) - (before.red - before.blue)
                let greener = (after.green - after.red) - (before.green - before.red)
                XCTAssertGreaterThan(warmer, 15, "\(look) on \(name) is not visibly warmer")
                XCTAssertLessThanOrEqual(greener, 0, "\(look) on \(name) turns greener")
            }
        }
    }
}
