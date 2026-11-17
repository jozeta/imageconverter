import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

final class ColorProfileTests: XCTestCase {
    private func settings(_ format: OutputFormat) -> OutputSettings {
        var result = OutputSettings()
        result.format = format
        return result
    }

    func testP3ToSRGB() throws {
        let out = try ImageOps.convertColor(TestImages.displayP3(width: 8, height: 8), to: .sRGB)
        XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        XCTAssertEqual(out.bitsPerComponent, 16)
        let data = try ImageEncoder.encode(out, properties: [:], settings: settings(.jpeg))
        let name = try TestImages.properties(of: data)[kCGImagePropertyProfileName as String] as? String
        XCTAssertTrue(name?.contains("sRGB") == true, "profile name was \(name ?? "nil")")
    }

    func testGrayHasGrayModel() throws {
        let out = try ImageOps.convertColor(TestImages.make(width: 4, height: 4, alpha: 0), to: .gray)
        let data = try ImageEncoder.encode(out, properties: [:], settings: settings(.png))
        let model = try TestImages.properties(of: data)[kCGImagePropertyColorModel as String] as? String
        XCTAssertEqual(model, kCGImagePropertyColorModelGray as String)
        let pixel = TestImages.pixel(of: out, x: 1, y: 1)
        XCTAssertGreaterThan(pixel.red, 250)
        XCTAssertGreaterThan(pixel.alpha, 250)
    }

    func testKeepReturnsSameImage() throws {
        let image = TestImages.make(width: 4, height: 4)
        XCTAssertTrue(try ImageOps.convertColor(image, to: .keep) === image)
    }

    func testColorProfileSkipsRedrawWhenAlreadyTarget() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func image(bits: Int, alpha: CGImageAlphaInfo, in space: CGColorSpace) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: bits, bytesPerRow: 0,
                                              space: space, bitmapInfo: alpha.rawValue))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try XCTUnwrap(ctx.makeImage())
        }
        // Already what the step makes: sRGB, 8 or 16 bpc, opaque (XRGB like a JPEG decode, or RGBX) or premultiplied:
        // the same image back.
        for (bits, alpha) in [(8, CGImageAlphaInfo.noneSkipLast), (8, .noneSkipFirst), (8, .premultipliedLast),
                              (16, .noneSkipLast)] {
            let input = try image(bits: bits, alpha: alpha, in: space)
            XCTAssertTrue(try ImageOps.color(input, ColorOptions(profile: .sRGB)) === input, "\(bits) \(alpha)")
        }
        // Anything else is still redrawn: another space, or a re-color.
        let device = try image(bits: 8, alpha: .noneSkipLast, in: CGColorSpaceCreateDeviceRGB())
        let converted = try ImageOps.color(device, ColorOptions(profile: .sRGB))
        XCTAssertFalse(converted === device)
        XCTAssertEqual(converted.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        let srgb = try image(bits: 8, alpha: .noneSkipLast, in: space)
        XCTAssertFalse(try ImageOps.color(srgb, ColorOptions(profile: .displayP3)) === srgb)
        XCTAssertFalse(try ImageOps.color(srgb, ColorOptions(profile: .sRGB, recolor: RecolorOptions(kind: .sepia))) === srgb)
    }

    func testStaleProfilePropertiesDropped() throws {
        let props: [String: Any] = [
            kCGImagePropertyProfileName as String: "Display P3",
            kCGImagePropertyColorModel as String: kCGImagePropertyColorModelGray as String,
            kCGImagePropertyDepth as String: 16,
        ]
        let srgb = try ImageOps.convertColor(TestImages.make(width: 4, height: 4), to: .sRGB)
        let data = try ImageEncoder.encode(srgb, properties: props, settings: settings(.jpeg))
        let out = try TestImages.properties(of: data)
        let name = out[kCGImagePropertyProfileName as String] as? String
        XCTAssertNotEqual(name, "Display P3")
        XCTAssertEqual(out[kCGImagePropertyColorModel as String] as? String, kCGImagePropertyColorModelRGB as String)
    }
}

final class WideGamutThroughStepsTests: XCTestCase {
    private func jpeg() -> OutputSettings {
        var result = OutputSettings()
        result.format = .jpeg
        return result
    }

    private func profile(_ data: Data) throws -> String? {
        try TestImages.properties(of: data)[kCGImagePropertyProfileName as String] as? String
    }

    func testP3ResizeToJPEGKeepsP3() throws {
        let out = try ImageOps.resize(TestImages.displayP3(width: 40, height: 40), ResizeOptions(mode: .maxWidth(20)))
        let name = try profile(ImageEncoder.encode(out, properties: [:], settings: jpeg()))
        XCTAssertTrue(name?.contains("P3") == true, "profile name was \(name ?? "nil")")
    }

    func testP3ConvertToP3JPEGKeepsP3() throws {
        let out = try ImageOps.convertColor(TestImages.displayP3(width: 8, height: 8), to: .displayP3)
        let name = try profile(ImageEncoder.encode(out, properties: [:], settings: jpeg()))
        XCTAssertTrue(name?.contains("P3") == true, "profile name was \(name ?? "nil")")
    }

    private func opaqueImage() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return try XCTUnwrap(ctx.makeImage())
    }

    func testOpaquePNGStaysOpaqueThroughResize() throws {
        let out = try ImageOps.resize(opaqueImage(), ResizeOptions(mode: .maxWidth(20)))
        var settings = OutputSettings()
        settings.format = .png
        let data = try ImageEncoder.encode(out, properties: [:], settings: settings)
        let hasAlpha = try TestImages.properties(of: data)[kCGImagePropertyHasAlpha as String] as? Bool
        XCTAssertNotEqual(hasAlpha, true)
    }

    func testClearCanvasBackgroundKeepsAlpha() throws {
        let out = try ImageOps.canvas(opaqueImage(), CanvasOptions(mode: .padding(pixels: 4), background: .clear))
        var settings = OutputSettings()
        settings.format = .png
        let data = try ImageEncoder.encode(out, properties: [:], settings: settings)
        let hasAlpha = try TestImages.properties(of: data)[kCGImagePropertyHasAlpha as String] as? Bool
        XCTAssertEqual(hasAlpha, true)
    }

    func testExtendedRangeImageWithAlphaEncodesToJPEG() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 16, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder16Little.rawValue
                                          | CGBitmapInfo.floatComponents.rawValue))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.5, 0.2, 0.1, 0.5]) ?? CGColor(gray: 0.5, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(ctx.makeImage())
        XCTAssertTrue(ImageOps.hasAlpha(image))
        XCTAssertNoThrow(try ImageEncoder.encode(image, properties: [:], settings: jpeg()))
    }
}
