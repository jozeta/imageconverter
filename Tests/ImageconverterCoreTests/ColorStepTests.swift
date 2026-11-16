import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

/// The Color step's saved format: old profile-only steps, the new object form, lenient decoding.
final class ColorStepModelTests: XCTestCase {
    private func decode(_ json: String) throws -> Pipeline {
        try JSONDecoder().decode(Pipeline.self, from: Data(json.utf8))
    }

    func testOldProfileStepDecodesProfileOnly() throws {
        let pipeline = try decode("""
            {"schemaVersion":1,"steps":[{"id":"\(UUID().uuidString)","isEnabled":true,
            "operation":{"colorProfile":{"_0":"displayP3"}}}]}
            """)
        guard case .colorProfile(let options) = pipeline.steps.first?.operation else {
            return XCTFail("no Color step")
        }
        XCTAssertEqual(options, ColorOptions(profile: .displayP3))
        XCTAssertTrue(options.isProfileOnly)
        XCTAssertEqual(StepKind.colorProfile.displayName, "Color")
    }

    func testProfileOnlyStepSavesTheOldForm() throws {
        let data = try JSONEncoder().encode(ImageOperation.colorProfile(.sRGB))
        XCTAssertEqual(String(bytes: data, encoding: .utf8), #"{"colorProfile":{"_0":"sRGB"}}"#)
    }

    func testFullOptionsRoundTrip() throws {
        var options = ColorOptions(profile: .keep)
        options.recolor = RecolorOptions(kind: .replace, source: HexColor(hex: "#112233")!,
                                         target: HexColor(hex: "#AABBCC")!, tolerance: 40, softness: 10)
        options.reduce = ColorReduction(isEnabled: true, count: 8, dither: false)
        let step = PipelineStep(operation: .colorProfile(options))
        let data = try JSONEncoder().encode(Pipeline(steps: [step]))
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"#112233\""), json)
        XCTAssertEqual(try JSONDecoder().decode(Pipeline.self, from: data).steps, [step])
    }

    func testInactiveSettingsStillRoundTrip() throws {
        var options = ColorOptions.sRGB
        options.recolor.tint = HexColor(hex: "#FF0000")!
        let data = try JSONEncoder().encode(ImageOperation.colorProfile(options))
        XCTAssertEqual(try JSONDecoder().decode(ImageOperation.self, from: data), .colorProfile(options))
    }

    func testLenientNewerParts() throws {
        let pipeline = try decode("""
            {"steps":[{"id":"\(UUID().uuidString)","isEnabled":true,"operation":{"colorProfile":{"_0":
            {"profile":"gray","recolor":{"kind":"sparkle","tint":"red","strength":900,"hueShift":-999},
            "reduce":{"isEnabled":true,"count":9999}}}}}]}
            """)
        guard case .colorProfile(let options) = pipeline.steps.first?.operation else {
            return XCTFail("no Color step")
        }
        XCTAssertEqual(options.profile, .gray)
        XCTAssertEqual(options.recolor.kind, RecolorKind.none)
        XCTAssertEqual(options.recolor.tint, RecolorOptions().tint)
        XCTAssertEqual(options.recolor.strength, 100)
        XCTAssertEqual(options.recolor.hueShift, -180)
        XCTAssertEqual(options.reduce.count, 256)
        XCTAssertTrue(options.reduce.dither)
    }

    func testUnknownProfileStillSkipsTheStep() throws {
        let pipeline = try decode("""
            {"steps":[{"id":"\(UUID().uuidString)","isEnabled":true,"operation":{"colorProfile":{"_0":"adobeRGB"}}}]}
            """)
        XCTAssertTrue(pipeline.steps.isEmpty)
    }

    func testHexParsing() {
        XCTAssertEqual(HexColor(hex: "#0a0B0c"), HexColor(red: 10, green: 11, blue: 12))
        XCTAssertEqual(HexColor(hex: "0A0B0C")?.hex, "#0A0B0C")
        XCTAssertNil(HexColor(hex: "#12345"))
        XCTAssertNil(HexColor(hex: "#GG0000"))
        XCTAssertEqual(HexColor(unitRed: 1, green: .nan, blue: 0.5), HexColor(red: 255, green: 0, blue: 128))
    }

    func testSummary() {
        XCTAssertEqual(ImageOperation.colorProfile(.displayP3).summary, "Display P3")
        var options = ColorOptions(profile: .keep)
        options.recolor.kind = .hueShift
        options.recolor.hueShift = 30
        options.reduce = ColorReduction(isEnabled: true, count: 16, dither: true)
        XCTAssertEqual(options.summary, "keep profile · hue +30° · 16 colours, dithered")
    }

    func testReducesColorsFlag() {
        var options = ColorOptions.sRGB
        options.reduce.isEnabled = true
        XCTAssertTrue(Pipeline(steps: [PipelineStep(operation: .colorProfile(options))]).reducesColors)
        XCTAssertFalse(Pipeline(steps: [PipelineStep(isEnabled: false, operation: .colorProfile(options))])
            .reducesColors)
        XCTAssertFalse(Pipeline(steps: [PipelineStep(operation: .colorProfile(.sRGB))]).reducesColors)
    }
}

/// Re-color: tint, duotone, sepia, replace a colour, hue shift.
final class RecolorTests: XCTestCase {
    private func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private func recolor(_ image: CGImage, _ options: RecolorOptions) throws -> CGImage {
        try ImageOps.color(image, ColorOptions(profile: .keep, recolor: options))
    }

    func testNeutralSettingsReturnTheSameImage() throws {
        let image = TestImages.make(width: 4, height: 4)
        XCTAssertTrue(try recolor(image, RecolorOptions(kind: .tint, strength: 0)) === image)
        XCTAssertTrue(try recolor(image, RecolorOptions(kind: .hueShift, hueShift: 0)) === image)
        XCTAssertTrue(try recolor(image, RecolorOptions(kind: .none)) === image)
    }

    func testTintTonesGreyInTheTintColour() throws {
        let grey = TestImages.make(width: 4, height: 4, color: srgb(0.5, 0.5, 0.5))
        let out = try recolor(grey, RecolorOptions(kind: .tint, tint: HexColor(hex: "#2060D0")!))
        let pixel = TestImages.pixel(of: out, x: 1, y: 1)
        XCTAssertGreaterThan(pixel.blue, pixel.red + 40, "\(pixel)")
        // Half strength lies between grey and the full tint.
        let half = TestImages.pixel(of: try recolor(grey, RecolorOptions(kind: .tint, tint: HexColor(hex: "#2060D0")!,
                                                                         strength: 50)), x: 1, y: 1)
        XCTAssertLessThan(half.blue - half.red, pixel.blue - pixel.red)
        XCTAssertGreaterThan(half.blue - half.red, 10)
    }

    func testDuotoneMapsDarkAndLight() throws {
        let image = TestImages.twoColor(width: 8, height: 2, left: srgb(0, 0, 0), right: srgb(1, 1, 1))
        let options = RecolorOptions(kind: .duotone, shadows: HexColor(hex: "#800000")!,
                                     highlights: HexColor(hex: "#FFFF80")!)
        let out = try recolor(image, options)
        let dark = TestImages.pixel(of: out, x: 0, y: 0)
        let light = TestImages.pixel(of: out, x: 7, y: 0)
        XCTAssertEqual(dark.red, 128, accuracy: 3)
        XCTAssertEqual(dark.green, 0, accuracy: 3)
        XCTAssertEqual(light.blue, 128, accuracy: 3)
        XCTAssertEqual(light.green, 255, accuracy: 3)
    }

    func testSepiaIsWarm() throws {
        let grey = TestImages.make(width: 4, height: 4, color: srgb(0.6, 0.6, 0.6))
        let pixel = TestImages.pixel(of: try recolor(grey, RecolorOptions(kind: .sepia)), x: 0, y: 0)
        XCTAssertGreaterThan(pixel.red, pixel.blue + 20, "\(pixel)")
    }

    func testHueShiftTurnsRedTowardsCyan() throws {
        let red = TestImages.make(width: 4, height: 4, color: srgb(0.8, 0.2, 0.2))
        let pixel = TestImages.pixel(of: try recolor(red, RecolorOptions(kind: .hueShift, hueShift: 180)), x: 0, y: 0)
        XCTAssertGreaterThan(pixel.green, pixel.red, "\(pixel)")
        XCTAssertGreaterThan(pixel.blue, pixel.red, "\(pixel)")
    }

    func testReplaceKeepsShadingAndLeavesGreysAlone() throws {
        // Light blue, dark blue and grey.
        let width = 9
        guard let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("no context")
        }
        for (index, color) in [srgb(0.25, 0.45, 0.95), srgb(0.08, 0.16, 0.45), srgb(0.5, 0.5, 0.5)].enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: index * 3, y: 0, width: 3, height: 1))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let options = RecolorOptions(kind: .replace, source: HexColor(hex: "#3F72F2")!,
                                     target: HexColor(hex: "#E02020")!, tolerance: 20, softness: 50)
        let out = try recolor(image, options)
        let light = TestImages.pixel(of: out, x: 1, y: 0)
        let dark = TestImages.pixel(of: out, x: 4, y: 0)
        let grey = TestImages.pixel(of: out, x: 7, y: 0)
        XCTAssertGreaterThan(light.red, light.blue + 80, "light \(light)")
        XCTAssertGreaterThan(dark.red, dark.blue + 20, "dark \(dark)")
        XCTAssertLessThan(dark.red + dark.green + dark.blue, light.red + light.green + light.blue, "shading kept")
        XCTAssertEqual(grey.red, 128, accuracy: 1)
        XCTAssertEqual(grey.blue, 128, accuracy: 1)
    }

    func testReplaceLeavesOtherHues() throws {
        let green = TestImages.make(width: 2, height: 2, color: srgb(0.2, 0.8, 0.2))
        let options = RecolorOptions(kind: .replace, source: HexColor(hex: "#2050E0")!,
                                     target: HexColor(hex: "#E02020")!, tolerance: 20)
        let pixel = TestImages.pixel(of: try recolor(green, options), x: 0, y: 0)
        XCTAssertEqual(pixel.green, 204, accuracy: 1)
        XCTAssertEqual(pixel.red, 51, accuracy: 1)
    }

    func testGreySourceMatchesOnlyGreys() {
        let transform = Recolor.PixelTransform(RecolorOptions(kind: .replace, source: HexColor(hex: "#808080")!,
                                                              target: HexColor(hex: "#FF0000")!, tolerance: 30))
        XCTAssertGreaterThan(transform.weight(OKLab(HexColor(hex: "#848484")!)), 0.9)
        XCTAssertEqual(transform.weight(OKLab(HexColor(hex: "#2050E0")!)), 0)
    }

    func testTransparentPixelsStayTransparent() throws {
        let clear = TestImages.make(width: 2, height: 2, alpha: 0)
        let out = try recolor(clear, RecolorOptions(kind: .sepia))
        XCTAssertEqual(TestImages.pixel(of: out, x: 0, y: 0).alpha, 0)
        XCTAssertTrue(ImageOps.hasAlpha(out))
    }

    func testKeepsWideGamutAndDepth() throws {
        let out = try recolor(TestImages.displayP3(width: 4, height: 4), RecolorOptions(kind: .hueShift, hueShift: 20))
        XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(out.bitsPerComponent, 16)
    }

    func testProfileRunsFirst() throws {
        // Gray, then tint: the tint still shows (the result is colour).
        let options = ColorOptions(profile: .gray, recolor: RecolorOptions(kind: .tint, tint: HexColor(hex: "#D04020")!))
        let out = try ImageOps.color(TestImages.make(width: 2, height: 2), options)
        let pixel = TestImages.pixel(of: out, x: 0, y: 0)
        XCTAssertGreaterThan(pixel.red, pixel.blue + 20, "\(pixel)")
    }
}

/// Replace colour's Shading: Exact colour, the gamut and the saved field.
final class ReplaceExactTests: XCTestCase {
    private func replace(_ image: CGImage, _ options: RecolorOptions) throws -> CGImage {
        try ImageOps.color(image, ColorOptions(profile: .keep, recolor: options))
    }

    func testExactColourMakesFlatAreasTheTarget() throws {
        // A light blue that isn't the picked source colour.
        let light = TestImages.make(width: 4, height: 4, color: CGColor(srgbRed: 0.45, green: 0.62, blue: 0.9, alpha: 1))
        let options = RecolorOptions(kind: .replace, source: HexColor(hex: "#1E5AC8")!,
                                     target: HexColor(hex: "#C81E2D")!, exact: true, tolerance: 30, softness: 0)
        let pixel = TestImages.pixel(of: try replace(light, options), x: 1, y: 1)
        XCTAssertEqual(pixel.red, 200, accuracy: 2)
        XCTAssertEqual(pixel.green, 30, accuracy: 2)
        XCTAssertEqual(pixel.blue, 45, accuracy: 2)
        // Keep (the default) gives a lighter red instead.
        var keep = options
        keep.exact = false
        XCTAssertGreaterThan(TestImages.pixel(of: try replace(light, keep), x: 1, y: 1).green, 60)
    }

    func testResultsStayInGamutWithTheTargetHue() throws {
        // A low-chroma source scales a saturated pixel's chroma far out of gamut; the hue must still be the target's.
        let saturated = TestImages.make(width: 2, height: 2, color: CGColor(srgbRed: 0, green: 0.19, blue: 1, alpha: 1))
        let options = RecolorOptions(kind: .replace, source: HexColor(hex: "#6878A0")!,
                                     target: HexColor(hex: "#FF0000")!, tolerance: 30, softness: 0)
        let pixel = TestImages.pixel(of: try replace(saturated, options), x: 0, y: 0)
        let result = OKLab(HexColor(unitRed: pixel.red / 255, green: pixel.green / 255, blue: pixel.blue / 255))
        let wanted = OKLab(HexColor(hex: "#FF0000")!)
        // The source and pixel hues differ a little, which carries over; clipping per channel would shift far more.
        var difference = abs(result.hue - (wanted.hue + OKLab(HexColor(hex: "#0030FF")!).hue
                                           - OKLab(HexColor(hex: "#6878A0")!).hue))
        if difference > .pi { difference = 2 * .pi - difference }
        XCTAssertLessThan(difference, 0.12, "\(pixel)")
    }

    func testExactIsSavedLeniently() throws {
        var options = ColorOptions.sRGB
        options.recolor = RecolorOptions(kind: .replace, exact: true)
        let data = try JSONEncoder().encode(ImageOperation.colorProfile(options))
        XCTAssertEqual(try JSONDecoder().decode(ImageOperation.self, from: data), .colorProfile(options))
        let old = Data(#"{"kind":"replace","tolerance":40}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(RecolorOptions.self, from: old).exact)
        XCTAssertFalse(RecolorOptions(kind: .replace, source: .white, target: .white, exact: true).isNeutral)
    }
}
