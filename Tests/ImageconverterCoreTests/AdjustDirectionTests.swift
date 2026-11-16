import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Each adjustment moves tones and colours the expected way.
final class AdjustDirectionTests: XCTestCase {
    private func level(_ value: Int) -> CGImage {
        let component = CGFloat(value) / 255
        return TestImages.make(width: 16, height: 16,
                               color: CGColor(srgbRed: component, green: component, blue: component, alpha: 1))
    }

    /// The sRGB 0-255 red level at the centre of `image` adjusted by `options`.
    private func adjusted(_ value: Int, _ change: (inout AdjustOptions) -> Void) throws -> Double {
        var options = AdjustOptions()
        change(&options)
        return TestImages.pixel(of: try Adjustments.apply(options, to: level(value)), x: 8, y: 8).red
    }

    /// Mid-gray with low-amplitude deterministic noise (±10 levels): below edge thresholds, so noise
    /// reduction smooths it and sharpening amplifies it.
    private func mildNoise(size: Int = 48) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = ctx.data else { fatalError("No context") }
        let bytes = base.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
        var state: UInt64 = 42
        for row in 0..<size {
            for col in 0..<size {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = UInt8(118 + Int(state >> 59) % 21)
                let offset = row * ctx.bytesPerRow + col * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        guard let image = ctx.makeImage() else { fatalError("No image") }
        return image
    }

    /// Variance of the red channel over the interior (a 4-pixel border is skipped).
    private func variance(_ image: CGImage) -> Double {
        var values: [Double] = []
        for row in 4..<(image.height - 4) {
            for col in 4..<(image.width - 4) { values.append(TestImages.pixel(of: image, x: col, y: row).red) }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    func testContrastPivotsAtMidGray() throws {
        XCTAssertEqual(try adjusted(128) { $0.contrast = 100 }, 128, accuracy: 3)
        XCTAssertEqual(try adjusted(128) { $0.contrast = -100 }, 128, accuracy: 3)
        XCTAssertLessThan(try adjusted(64) { $0.contrast = 100 }, 64 - 10)
        XCTAssertGreaterThan(try adjusted(192) { $0.contrast = 100 }, 192 + 10)
        XCTAssertGreaterThan(try adjusted(64) { $0.contrast = -100 }, 64 + 10)
    }

    func testBrightnessDirection() throws {
        XCTAssertGreaterThan(try adjusted(100) { $0.brightness = 60 }, 100 + 10)
        XCTAssertLessThan(try adjusted(100) { $0.brightness = -60 }, 100 - 10)
    }

    func testHighlightsDirection() throws {
        XCTAssertLessThan(try adjusted(230) { $0.highlights = -100 }, 230 - 5)
        XCTAssertGreaterThan(try adjusted(191) { $0.highlights = 100 }, 191 + 5)
    }

    func testShadowsDirection() throws {
        XCTAssertGreaterThan(try adjusted(40) { $0.shadows = 100 }, 40 + 5)
        XCTAssertLessThan(try adjusted(40) { $0.shadows = -100 }, 40 - 3)
    }

    func testBrillianceDirection() throws {
        XCTAssertGreaterThan(try adjusted(64) { $0.brilliance = 100 }, 64 + 5)
        XCTAssertLessThan(try adjusted(191) { $0.brilliance = 100 }, 191 - 5)
        XCTAssertLessThan(try adjusted(64) { $0.brilliance = -100 }, 64 - 5)
    }

    func testBlackPointDirection() throws {
        XCTAssertLessThan(try adjusted(40) { $0.blackPoint = 100 }, 40 - 5)
        XCTAssertGreaterThan(try adjusted(0) { $0.blackPoint = -100 }, 20)
    }

    func testVibranceRaisesMutedSaturation() throws {
        let muted = TestImages.make(width: 16, height: 16, color: CGColor(srgbRed: 0.6, green: 0.5, blue: 0.45, alpha: 1))
        let spread: (TestImages.Pixel) -> Double = { max($0.red, $0.green, $0.blue) - min($0.red, $0.green, $0.blue) }
        var options = AdjustOptions()
        options.vibrance = 100
        let after = TestImages.pixel(of: try Adjustments.apply(options, to: muted), x: 8, y: 8)
        XCTAssertGreaterThan(spread(after), spread(TestImages.pixel(of: muted, x: 8, y: 8)) + 5)
    }

    func testNoiseReductionSmooths() throws {
        let noisy = mildNoise()
        let out = try Adjustments.apply(AdjustOptions(noiseReduction: 100), to: noisy)
        XCTAssertLessThan(variance(out), variance(noisy) * 0.8)
    }

    func testSharpnessAndDefinitionRaiseLocalContrast() throws {
        let noisy = mildNoise()
        let before = variance(noisy)
        XCTAssertGreaterThan(variance(try Adjustments.apply(AdjustOptions(sharpness: 100), to: noisy)), before * 1.2)
        XCTAssertGreaterThan(variance(try Adjustments.apply(AdjustOptions(definition: 100), to: noisy)), before * 1.05)
    }

    func testSoftenSmoothsAndGrowsWithTheAmount() throws {
        // 400 px: at −100 the blur radius is a few pixels, enough to flatten single-pixel noise.
        let noisy = mildNoise(size: 400)
        let before = variance(noisy)
        let light = variance(try Adjustments.apply(AdjustOptions(sharpness: -20), to: noisy))
        let strong = variance(try Adjustments.apply(AdjustOptions(sharpness: -100), to: noisy))
        XCTAssertLessThan(light, before * 0.9)
        XCTAssertLessThan(strong, light * 0.5)
    }

    func testOutOfRangeAndNaNAreClampedInApply() throws {
        let image = level(128)
        XCTAssertTrue(try Adjustments.apply(AdjustOptions(exposure: .nan), to: image) === image)
        let clamped = try adjusted(128) { $0.exposure = 100 }
        XCTAssertEqual(try adjusted(128) { $0.exposure = 10_000 }, clamped, accuracy: 1)
    }

    func testGrayInputComesOutAsValidSRGB() throws {
        guard let grayspace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: grayspace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return XCTFail("No gray context") }
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        guard let gray = ctx.makeImage() else { return XCTFail("No image") }
        let out = try Adjustments.apply(AdjustOptions(exposure: 50), to: gray)
        XCTAssertEqual(out.width, 12)
        XCTAssertEqual(out.height, 8)
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.sRGB) // documented fallback for non-RGB spaces
        XCTAssertFalse(ImageOps.hasAlpha(out))
        let before = TestImages.pixel(of: gray, x: 6, y: 4)
        let after = TestImages.pixel(of: out, x: 6, y: 4)
        XCTAssertGreaterThan(after.red, before.red + 20)
        XCTAssertEqual(after.red, after.blue, accuracy: 2)
    }
}
