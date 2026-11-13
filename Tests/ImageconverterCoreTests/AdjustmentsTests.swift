import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class AdjustmentsTests: XCTestCase {
    private let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    private func luminance(_ pixel: TestImages.Pixel) -> Double {
        0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
    }

    func testNeutralReturnsSameImage() throws {
        let image = TestImages.noise(width: 8, height: 8)
        XCTAssertTrue(AdjustOptions().isNeutral)
        XCTAssertTrue(try Adjustments.apply(AdjustOptions(), to: image) === image)
    }

    func testExposurePositiveBrightens() throws {
        let image = TestImages.make(width: 16, height: 16, color: gray)
        var options = AdjustOptions()
        options.exposure = 50
        XCTAssertFalse(options.isNeutral)
        let out = try Adjustments.apply(options, to: image)
        XCTAssertGreaterThan(luminance(TestImages.pixel(of: out, x: 8, y: 8)),
                             luminance(TestImages.pixel(of: image, x: 8, y: 8)) + 20)
    }

    func testSaturationMinus100IsGray() throws {
        let image = TestImages.make(width: 16, height: 16) // red-ish
        var options = AdjustOptions()
        options.saturation = -100
        let pixel = TestImages.pixel(of: try Adjustments.apply(options, to: image), x: 8, y: 8)
        XCTAssertEqual(pixel.red, pixel.green, accuracy: 2)
        XCTAssertEqual(pixel.green, pixel.blue, accuracy: 2)
    }

    func testWarmthPositiveIsWarmer() throws {
        let image = TestImages.make(width: 16, height: 16, color: gray)
        var options = AdjustOptions()
        options.warmth = 60
        let warm = TestImages.pixel(of: try Adjustments.apply(options, to: image), x: 8, y: 8)
        let before = TestImages.pixel(of: image, x: 8, y: 8)
        XCTAssertGreaterThan(warm.red / max(warm.blue, 1), before.red / max(before.blue, 1) + 0.05)
        options.warmth = -60
        let cool = TestImages.pixel(of: try Adjustments.apply(options, to: image), x: 8, y: 8)
        XCTAssertLessThan(cool.red / max(cool.blue, 1), before.red / max(before.blue, 1) - 0.05)
    }

    func testTintPositiveIsMagenta() throws {
        let image = TestImages.make(width: 16, height: 16, color: gray)
        var options = AdjustOptions()
        options.tint = 80
        let pixel = TestImages.pixel(of: try Adjustments.apply(options, to: image), x: 8, y: 8)
        XCTAssertLessThan(pixel.green + 3, (pixel.red + pixel.blue) / 2)
    }

    func testHue180SwapsRedTowardsCyan() throws {
        let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let image = TestImages.make(width: 16, height: 16, color: red)
        var options = AdjustOptions()
        options.hue = 180
        let pixel = TestImages.pixel(of: try Adjustments.apply(options, to: image), x: 8, y: 8)
        XCTAssertLessThan(pixel.red, pixel.green)
        XCTAssertLessThan(pixel.red, pixel.blue)
    }

    func testKeepsSizeColorSpaceAndAlpha() throws {
        var options = AdjustOptions()
        options.contrast = 30
        options.sharpness = 50

        // 16-bit Display P3 with a translucent alpha channel.
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 16, bytesPerRow: 0, space: displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("No P3 context")
        }
        ctx.setFillColor(CGColor(colorSpace: displayP3, components: [0.8, 0.4, 0.2, 0.5]) ?? gray)
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        guard let translucent = ctx.makeImage() else { return XCTFail("No image") }
        let out = try Adjustments.apply(options, to: translucent)
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 10)
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(out.bitsPerComponent, 16)
        XCTAssertTrue(ImageOps.hasAlpha(out))
        XCTAssertEqual(TestImages.pixel(of: out, x: 0, y: 0).alpha, 128, accuracy: 3) // edges keep alpha too
        XCTAssertEqual(TestImages.pixel(of: out, x: 10, y: 5).alpha, 128, accuracy: 3)

        // Opaque 8-bit sRGB stays opaque and 8-bit; edges don't darken.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let opaqueCtx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return XCTFail("No sRGB context")
        }
        opaqueCtx.setFillColor(gray)
        opaqueCtx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        guard let opaque = opaqueCtx.makeImage() else { return XCTFail("No image") }
        options.definition = 80
        options.noiseReduction = 50
        let flat = try Adjustments.apply(options, to: opaque)
        XCTAssertFalse(ImageOps.hasAlpha(flat))
        XCTAssertEqual(flat.bitsPerComponent, 8)
        XCTAssertEqual(flat.colorSpace?.name, CGColorSpace.sRGB)
        let corner = TestImages.pixel(of: flat, x: 0, y: 0)
        let middle = TestImages.pixel(of: flat, x: 10, y: 5)
        XCTAssertEqual(corner.red, middle.red, accuracy: 2)
        XCTAssertEqual(corner.alpha, 255)
    }

    func testDecodesClampsAndDefaults() throws {
        let json = #"{"exposure": 500, "hue": -999, "sharpness": -5, "contrast": 12.5}"#
        let options = try JSONDecoder().decode(AdjustOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.exposure, 100)
        XCTAssertEqual(options.hue, -180)
        XCTAssertEqual(options.sharpness, 0)
        XCTAssertEqual(options.contrast, 12.5)
        XCTAssertEqual(options.saturation, 0)
        XCTAssertEqual(options.noiseReduction, 0)
        XCTAssertEqual(AdjustOptions.ranges[.hue], -180...180)
        XCTAssertEqual(AdjustOptions.ranges[.definition], 0...100)
        XCTAssertEqual(AdjustOptions.ranges.count, AdjustOptions.Field.allCases.count)

        let roundTrip = try JSONDecoder().decode(AdjustOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(roundTrip, options)
        let operation = ImageOperation.adjust(options)
        XCTAssertEqual(try JSONDecoder().decode(ImageOperation.self, from: JSONEncoder().encode(operation)), operation)
    }

    func testModelAndSummary() {
        XCTAssertEqual(StepKind.adjust.displayName, "Adjust")
        XCTAssertEqual(StepKind.adjust.defaultOperation, .adjust(AdjustOptions()))
        XCTAssertEqual(ImageOperation.adjust(AdjustOptions()).summary, "no changes")
        var options = AdjustOptions()
        options.exposure = 20
        options.contrast = 10
        options.hue = -30
        options.sharpness = 40
        XCTAssertEqual(ImageOperation.adjust(options).summary, "exposure +20, contrast +10, hue −30°, sharpness 40")
    }

    func testPeakPixelsCountsWorkingCopies() {
        let pipe = Pipeline(steps: [PipelineStep(operation: .adjust(AdjustOptions(exposure: 10)))])
        XCTAssertEqual(pipe.peakPixels(sourceWidth: 100, sourceHeight: 100), 30_000)
        XCTAssertEqual(pipe.outputSize(sourceWidth: 100, sourceHeight: 50).width, 100)
        // Neutral or disabled: nothing extra.
        XCTAssertEqual(Pipeline(steps: [PipelineStep(operation: .adjust(AdjustOptions()))])
            .peakPixels(sourceWidth: 100, sourceHeight: 100), 10_000)
    }

    func testPipelineRunsAdjustStep() throws {
        let image = TestImages.make(width: 16, height: 16, color: gray)
        let pipe = Pipeline(steps: [PipelineStep(operation: .adjust(AdjustOptions(exposure: -50)))])
        let out = try pipe.apply(to: image)
        XCTAssertLessThan(luminance(TestImages.pixel(of: out, x: 8, y: 8)),
                          luminance(TestImages.pixel(of: image, x: 8, y: 8)) - 20)
    }

    func testEveryFieldRendersAtRangeEnds() throws {
        let image = TestImages.twoColor(width: 24, height: 24,
                                        left: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.7, alpha: 1),
                                        right: CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        for field in AdjustOptions.Field.allCases {
            var options = AdjustOptions()
            options[field] = field.range.upperBound
            let out = try Adjustments.apply(options, to: image)
            XCTAssertEqual(out.width, 24, "\(field)")
            options[field] = field.range.lowerBound
            _ = try Adjustments.apply(options, to: image)
        }
    }
}
