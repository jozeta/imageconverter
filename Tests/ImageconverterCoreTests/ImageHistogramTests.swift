import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class ImageHistogramTests: XCTestCase {
    private typealias RGBA = (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) // swiftlint:disable:this large_tuple

    /// An 8-bit sRGB image whose pixel at `index` (row-major) is `pixel(index)` (straight alpha; stored premultiplied).
    private func image(width: Int, height: Int, _ pixel: (Int) -> RGBA) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for index in 0..<(width * height) {
            let value = pixel(index)
            let alpha = Int(value.alpha)
            bytes[index * 4] = UInt8((Int(value.red) * alpha + 127) / 255)
            bytes[index * 4 + 1] = UInt8((Int(value.green) * alpha + 127) / 255)
            bytes[index * 4 + 2] = UInt8((Int(value.blue) * alpha + 127) / 255)
            bytes[index * 4 + 3] = value.alpha
        }
        return ctx.makeImage()!
    }

    func testBinsAndCountsSolidColour() {
        let histogram = ImageHistogram.compute(image(width: 10, height: 10) { _ in (200, 100, 0, 255) })
        XCTAssertEqual(histogram.counted, 100)
        XCTAssertEqual(histogram.red[200], 100)
        XCTAssertEqual(histogram.green[100], 100)
        XCTAssertEqual(histogram.blue[0], 100)
        XCTAssertEqual(histogram.luminance[Int((0.2126 * 200 + 0.7152 * 100).rounded())], 100)
        XCTAssertEqual(histogram.red.count, 256)
        XCTAssertEqual(histogram.luminance.reduce(0, +), 100)
    }

    func testTransparentPixelsNotCounted() {
        let histogram = ImageHistogram.compute(image(width: 10, height: 10) { $0 < 50 ? (0, 0, 0, 0) : (10, 20, 30, 255) })
        XCTAssertEqual(histogram.counted, 50)
        XCTAssertEqual(histogram.red[10], 50)
        // Transparent black is not a crushed shadow.
        XCTAssertEqual(histogram.shadowFraction, 0)
    }

    func testNearlyTransparentPixelsNotCounted() throws {
        // Straight grey 128 at alpha 1 is stored premultiplied as 0 or 1: neither a value nor a crushed shadow.
        let faint = image(width: 4, height: 4) { _ in (128, 128, 128, 1) }
        let histogram = ImageHistogram.compute(faint)
        XCTAssertEqual(histogram.counted, 0)
        XCTAssertEqual(histogram.highlightFraction, 0)
        XCTAssertEqual(histogram.shadowFraction, 0)
        let mask = try XCTUnwrap(ImageHistogram.clippingMask(for: faint))
        XCTAssertTrue(rgba(of: mask).allSatisfy { $0.alpha == 0 })
    }

    func testMultiThreadedPathMatchesExpectedCounts() {
        // 1024 × 1024 is over 1 MP, so the rows are split across threads.
        let side = 1024
        let value: (Int) -> RGBA = { index in
            (UInt8(index % 256), UInt8((index / 3) % 256), UInt8((index * 5) % 256), 255)
        }
        let histogram = ImageHistogram.compute(image(width: side, height: side, value))
        var red = [Int](repeating: 0, count: 256), green = red, blue = red
        for index in 0..<(side * side) {
            let pixel = value(index)
            red[Int(pixel.red)] += 1; green[Int(pixel.green)] += 1; blue[Int(pixel.blue)] += 1
        }
        XCTAssertEqual(histogram.counted, side * side)
        XCTAssertEqual(histogram.red, red)
        XCTAssertEqual(histogram.green, green)
        XCTAssertEqual(histogram.blue, blue)
        XCTAssertEqual(histogram.luminance.reduce(0, +), side * side)
    }

    func testClippingFractions() {
        let histogram = ImageHistogram.compute(image(width: 10, height: 10) { index -> RGBA in
            if index < 25 { return (255, 255, 255, 255) }
            if index < 50 { return (0, 0, 0, 255) }
            return (128, 128, 128, 255)
        })
        XCTAssertEqual(histogram.highlightFraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(histogram.shadowFraction, 0.25, accuracy: 1e-9)
        XCTAssertTrue(histogram.isHighlightClipped)
        XCTAssertTrue(histogram.isShadowClipped)
        let clean = ImageHistogram.compute(image(width: 10, height: 10) { _ in (128, 128, 128, 255) })
        XCTAssertFalse(clean.isHighlightClipped)
        XCTAssertFalse(clean.isShadowClipped)
        XCTAssertEqual(ImageHistogram.warnFraction, 0.001)
    }

    func testExtendedRangeCountsAsHighlight() {
        let width = 8, height = 8
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16,
                            space: space, bitmapInfo: info)!
        let floats = ctx.data!.bindMemory(to: Float.self, capacity: width * height * 4)
        for index in 0..<(width * height) {
            floats[index * 4] = 1.5
            floats[index * 4 + 1] = 0.2
            floats[index * 4 + 2] = 0.2
            floats[index * 4 + 3] = 1
        }
        let histogram = ImageHistogram.compute(ctx.makeImage()!)
        XCTAssertEqual(histogram.counted, 64)
        XCTAssertEqual(histogram.highlightFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(histogram.red[255], 64)
    }

    func testSixteenBitInput() {
        let width = 16, height = 16
        let value: (Int) -> RGBA = { index in
            (UInt8(index % 256), UInt8((index * 7) % 256), UInt8(255 - index % 256), 255)
        }
        let eight = ImageHistogram.compute(image(width: width, height: height, value))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                            space: space, bitmapInfo: info)!
        let words = ctx.data!.bindMemory(to: UInt16.self, capacity: width * height * 4)
        for index in 0..<(width * height) {
            let pixel = value(index)
            words[index * 4] = UInt16(pixel.red) * 257
            words[index * 4 + 1] = UInt16(pixel.green) * 257
            words[index * 4 + 2] = UInt16(pixel.blue) * 257
            words[index * 4 + 3] = 65535
        }
        let sixteen = ImageHistogram.compute(ctx.makeImage()!)
        XCTAssertEqual(sixteen.counted, eight.counted)
        for (name, lhs, rhs) in [("red", eight.red, sixteen.red), ("green", eight.green, sixteen.green),
                                 ("blue", eight.blue, sixteen.blue)] {
            // Every count of the 8-bit twin sits within one bin of the 16-bit one.
            for bin in 0..<256 where lhs[bin] > 0 {
                let nearby = (max(bin - 1, 0)...min(bin + 1, 255)).reduce(0) { $0 + rhs[$1] }
                XCTAssertGreaterThanOrEqual(nearby, lhs[bin], "\(name) bin \(bin)")
            }
        }
    }

    func testMaskColours() throws {
        let source = image(width: 3, height: 1) { index -> RGBA in
            [(255, 255, 255, 255), (0, 0, 0, 255), (128, 128, 128, 255)][index]
        }
        let mask = try XCTUnwrap(ImageHistogram.clippingMask(for: source))
        XCTAssertEqual(mask.width, 3)
        XCTAssertEqual(mask.height, 1)
        let pixels = rgba(of: mask)
        XCTAssertEqual(pixels[0].alpha, 255)
        XCTAssertEqual(pixels[0].red, 255)
        XCTAssertEqual(pixels[0].green, 0)
        XCTAssertEqual(pixels[0].blue, 0)
        XCTAssertEqual(pixels[1].alpha, 255)
        XCTAssertEqual(pixels[1].red, 0)
        XCTAssertEqual(pixels[1].green, 80)
        XCTAssertEqual(pixels[1].blue, 255)
        XCTAssertEqual(pixels[2].alpha, 0)
    }

    func testLargeImageIsDownsampled() {
        let histogram = ImageHistogram.compute(TestImages.make(width: 4000, height: 3000))
        XCTAssertGreaterThan(histogram.counted, 0)
        XCTAssertLessThanOrEqual(histogram.counted, 1024 * 768)
        let mask = ImageHistogram.clippingMask(for: TestImages.make(width: 4000, height: 3000))
        XCTAssertLessThanOrEqual(max(mask?.width ?? 0, mask?.height ?? 0), 2048)
    }

    func testDisplayPeakIgnoresOneSpike() {
        var bins = [Int](repeating: 10, count: 256)
        bins[0] = 100_000
        XCTAssertEqual(ImageHistogram.displayPeak(bins), 10)
        XCTAssertEqual(ImageHistogram.displayPeak([Int](repeating: 0, count: 256)), 1)
    }

    func testPreviewResultMeasuresBothSides() {
        let before = image(width: 4, height: 4) { _ in (0, 0, 0, 255) }
        let after = image(width: 4, height: 4) { _ in (255, 255, 255, 255) }
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        let result = PreviewResult(before: before, after: after, source: url, sourceName: "a.jpg", outputName: "a.jpg",
                                   sourceSize: (4, 4), outputSize: (4, 4), outputURL: url, sourceFileSize: nil,
                                   disposition: .process, statusNote: nil).withHistograms()
        XCTAssertEqual(result.beforeHistogram?.shadowFraction, 1)
        XCTAssertEqual(result.afterHistogram?.highlightFraction, 1)
    }

    /// The image's pixels as 8-bit sRGB, premultiplied (fine for opaque and fully transparent pixels).
    private func rgba(of image: CGImage) -> [RGBA] {
        let count = image.width * image.height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<count).map { (bytes[$0 * 4], bytes[$0 * 4 + 1], bytes[$0 * 4 + 2], bytes[$0 * 4 + 3]) }
    }
}
