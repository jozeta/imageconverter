import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class WatermarkRenderTests: XCTestCase {
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// A solid image in `space` (so the pixel reader sees exact colours), opaque or with alpha.
    private func solid(_ width: Int, _ height: Int, _ components: [CGFloat], space name: CFString = CGColorSpace.sRGB,
                       bits: Int = 8, opaque: Bool = false) -> CGImage {
        guard let space = CGColorSpace(name: name),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                  space: space, bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                                                                   : CGImageAlphaInfo.premultipliedLast.rawValue),
              let color = CGColor(colorSpace: space, components: components + [1]),
              let image = { ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                            return ctx.makeImage() }() else { fatalError("Couldn't build a test image") }
        return image
    }

    private func imageOptions(opacity: Double = 1) -> WatermarkOptions {
        WatermarkOptions(content: .image(ImageWatermark(path: "x")), anchor: .bottomRight,
                         sizePercent: 20, opacity: opacity, marginPercent: 3)
    }

    private func textOptions(_ text: String, font: String = "Helvetica-Bold",
                             anchor: Anchor = .bottomLeft) -> WatermarkOptions {
        WatermarkOptions(content: .text(TextWatermark(text: text, fontName: font, color: .white)),
                         anchor: anchor, sizePercent: 10, opacity: 1, marginPercent: 3)
    }

    /// True when any pixel in the (top-left origin) region differs from `base` by more than 20.
    private func hasInk(_ image: CGImage, x xRange: Range<Int>, y yRange: Range<Int>, base: Double) -> Bool {
        for row in yRange {
            for col in xRange where abs(TestImages.pixel(of: image, x: col, y: row).red - base) > 20 {
                return true
            }
        }
        return false
    }

    func testImageWatermarkLandsBottomRight() throws {
        let base = TestImages.make(width: 400, height: 300, color: white)
        let asset = solid(100, 50, [1, 0, 0])
        let out = try ImageOps.watermark(base, imageOptions(), asset: asset)
        // Rect: width 60, height 30, margin 9 -> x 331...391, y 261...291.
        let inside = TestImages.pixel(of: out, x: 360, y: 276)
        XCTAssertGreaterThan(inside.red, 250)
        XCTAssertLessThan(inside.green, 5)
        let corner = TestImages.pixel(of: out, x: 2, y: 2)
        XCTAssertGreaterThan(corner.green, 250)
    }

    func testOpacityBlends() throws {
        let base = TestImages.make(width: 400, height: 300, color: white)
        let asset = solid(100, 50, [1, 0, 0])
        let out = try ImageOps.watermark(base, imageOptions(opacity: 0.5), asset: asset)
        let pixel = TestImages.pixel(of: out, x: 360, y: 276)
        XCTAssertEqual(pixel.red, 255, accuracy: 3)
        XCTAssertEqual(pixel.green, 128, accuracy: 3)
        XCTAssertEqual(pixel.blue, 128, accuracy: 3)
    }

    func testTextDrawsSomething() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        let out = try ImageOps.watermark(base, textOptions("TEST"), asset: nil)
        XCTAssertTrue(hasInk(out, x: 0..<200, y: 150..<300, base: 0))
        XCTAssertFalse(hasInk(out, x: 200..<400, y: 0..<150, base: 0))
    }

    func testTextSitsInsideItsRect() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        let out = try ImageOps.watermark(base, textOptions("TEST"), asset: nil)
        // Bottom-left, 9 px margin, 30 px tall: nothing above y 261 or left of x 9 or below y 291.
        XCTAssertFalse(hasInk(out, x: 0..<400, y: 0..<255, base: 0))
        XCTAssertFalse(hasInk(out, x: 0..<8, y: 0..<300, base: 0))
        XCTAssertFalse(hasInk(out, x: 0..<400, y: 292..<300, base: 0))
    }

    func testEmptyTextIsNoOp() throws {
        let base = TestImages.make(width: 40, height: 30)
        XCTAssertTrue(try ImageOps.watermark(base, textOptions(""), asset: nil) === base)
    }

    func testUnknownFontFallsBack() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        let out = try ImageOps.watermark(base, textOptions("TEST", font: "NoSuchFont-XYZ"), asset: nil)
        XCTAssertTrue(hasInk(out, x: 0..<200, y: 150..<300, base: 0))
    }

    func testOpaqueP3StaysOpaqueP3() throws {
        let base = solid(200, 150, [1, 0.2, 0.1], space: CGColorSpace.displayP3, bits: 16, opaque: true)
        let asset = TestImages.make(width: 40, height: 20, color: white)
        let out = try ImageOps.watermark(base, imageOptions(opacity: 0.5), asset: asset)
        XCTAssertFalse(ImageOps.hasAlpha(out))
        XCTAssertEqual(out.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(out.bitsPerComponent, 16)
        var settings = OutputSettings()
        settings.format = .jpeg
        let data = try ImageEncoder.encode(out, properties: [:], settings: settings)
        let name = try TestImages.properties(of: data)[kCGImagePropertyProfileName as String] as? String
        XCTAssertTrue(name?.contains("P3") == true, "profile name was \(name ?? "nil")")
    }

    func testMissingAssetThrows() {
        let base = TestImages.make(width: 40, height: 30)
        XCTAssertThrowsError(try ImageOps.watermark(base, imageOptions(), asset: nil)) {
            XCTAssertEqual($0 as? ConversionError, .watermarkImageUnreadable)
        }
        XCTAssertEqual(ConversionError.watermarkImageUnreadable.reason, "Couldn't read the watermark image")
    }

    func testZeroSizeIsNoOp() throws {
        let base = TestImages.make(width: 40, height: 30)
        var options = textOptions("A")
        options.sizePercent = 0
        XCTAssertTrue(try ImageOps.watermark(base, options, asset: nil) === base)
    }

    func testTallGlyphsStayInsideTheRect() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        // A with several stacked combining diaeresis rises above the normal ascent.
        let text = "A" + String(repeating: "\u{0308}", count: 6)
        let out = try ImageOps.watermark(base, textOptions(text), asset: nil)
        // Bottom-left, 9 px margin, 30 px tall: the rect is y 261...291, x from 9.
        XCTAssertTrue(hasInk(out, x: 0..<200, y: 255..<300, base: 0))
        XCTAssertFalse(hasInk(out, x: 0..<400, y: 0..<260, base: 0))
        XCTAssertFalse(hasInk(out, x: 0..<400, y: 292..<300, base: 0))
        XCTAssertFalse(hasInk(out, x: 0..<8, y: 0..<300, base: 0))
    }

    func testNewlinesDrawAsSpaces() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        let withNewline = try ImageOps.watermark(base, textOptions("A\nB\rC"), asset: nil)
        let withSpaces = try ImageOps.watermark(base, textOptions("A B C"), asset: nil)
        for row in stride(from: 250, to: 300, by: 3) {
            for col in stride(from: 0, to: 200, by: 2) {
                XCTAssertEqual(TestImages.pixel(of: withNewline, x: col, y: row).red,
                               TestImages.pixel(of: withSpaces, x: col, y: row).red, accuracy: 1)
            }
        }
    }
}
