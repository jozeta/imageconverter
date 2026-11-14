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

    /// True when the (top-left origin) region has a pixel matching `test`.
    private func contains(_ image: CGImage, x xRange: Range<Int>, y yRange: Range<Int>,
                          _ test: (TestImages.Pixel) -> Bool) -> Bool {
        for row in yRange {
            for col in xRange where test(TestImages.pixel(of: image, x: col, y: row)) { return true }
        }
        return false
    }

    private func isRed(_ pixel: TestImages.Pixel) -> Bool { pixel.red > 200 && pixel.green < 60 && pixel.blue < 60 }

    func testTiledCoversCorners() throws {
        let base = TestImages.make(width: 400, height: 300, color: white)
        let asset = solid(20, 20, [1, 0, 0])
        let options = WatermarkOptions(content: .image(ImageWatermark(path: "x")), anchor: .center, sizePercent: 10,
                                       opacity: 1, marginPercent: 3, rotation: 30,
                                       layout: .tiled(spacing: 50, stagger: true))
        let out = try ImageOps.watermark(base, options, asset: asset)
        for (columns, rows) in [(0..<40, 0..<40), (360..<400, 0..<40), (0..<40, 260..<300), (360..<400, 260..<300)] {
            XCTAssertTrue(contains(out, x: columns, y: rows, isRed), "no mark near \(columns) \(rows)")
        }
        // Spacing leaves white between the marks.
        XCTAssertTrue(contains(out, x: 0..<400, y: 0..<300) { $0.green > 240 })
    }

    func testRotatedImageWatermarkUsesRotatedBox() throws {
        let base = TestImages.make(width: 400, height: 300, color: white)
        let asset = solid(100, 50, [1, 0, 0])
        var options = imageOptions()
        options.rotation = 90
        let out = try ImageOps.watermark(base, options, asset: asset)
        // 60 x 30 turned upright is 30 wide and 60 tall, flush with the 9 px margin at the bottom right.
        XCTAssertTrue(isRed(TestImages.pixel(of: out, x: 376, y: 261)))
        XCTAssertFalse(isRed(TestImages.pixel(of: out, x: 350, y: 276)))
        XCTAssertFalse(contains(out, x: 392..<400, y: 0..<300, isRed))
        XCTAssertFalse(contains(out, x: 0..<400, y: 292..<300, isRed))
    }

    func testShadowAndOutlineDrawn() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        let plain = textOptions("IIII")
        var styled = plain
        styled.content = .text(TextWatermark(
            text: "IIII", fontName: "Helvetica-Bold", color: .white,
            shadow: WatermarkShadow(color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1), blur: 0, offset: 15),
            outline: WatermarkOutline(color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), width: 8)))
        let plainOut = try ImageOps.watermark(base, plain, asset: nil)
        let out = try ImageOps.watermark(base, styled, asset: nil)
        // Pixels the plain fill leaves black are now coloured by the outline (red) and the shadow (blue).
        var outlined = false
        var shadowed = false
        for row in 240..<300 {
            for col in 0..<200 {
                let before = TestImages.pixel(of: plainOut, x: col, y: row)
                guard before.red < 10, before.green < 10, before.blue < 10 else { continue }
                let after = TestImages.pixel(of: out, x: col, y: row)
                if after.red > 150, after.green < 80 { outlined = true }
                if after.blue > 150, after.red < 80 { shadowed = true }
            }
        }
        XCTAssertTrue(outlined, "no outline outside the glyph fill")
        XCTAssertTrue(shadowed, "no shadow outside the glyph fill")
    }

    func testImageShadowDrawn() throws {
        let base = TestImages.make(width: 400, height: 300, color: white)
        var options = imageOptions()
        options.content = .image(ImageWatermark(path: "x", shadow: WatermarkShadow(
            color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1), blur: 0, offset: 20)))
        let out = try ImageOps.watermark(base, options, asset: solid(100, 50, [1, 0, 0]))
        // The shadow (6 px down-right) counts in placement: the mark is x 325...385, y 255...285 and its shadow
        // x 331...391, y 261...291, flush with the 9 px margin.
        let below = TestImages.pixel(of: out, x: 388, y: 288)
        XCTAssertGreaterThan(below.blue, 200)
        XCTAssertLessThan(below.red, 60)
    }

    func testTokensRenderWithContext() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        let context = WatermarkTextContext(fileName: "AB", fileNameWithExtension: "AB.jpg")
        let viaToken = try ImageOps.watermark(base, textOptions("{filename}"), asset: nil, context: context)
        let literal = try ImageOps.watermark(base, textOptions("AB"), asset: nil)
        for row in stride(from: 250, to: 300, by: 3) {
            for col in stride(from: 0, to: 200, by: 2) {
                XCTAssertEqual(TestImages.pixel(of: viaToken, x: col, y: row).red,
                               TestImages.pixel(of: literal, x: col, y: row).red, accuracy: 1)
            }
        }
        // A token that renders to nothing draws nothing.
        XCTAssertTrue(try ImageOps.watermark(base, textOptions("{artist}"), asset: nil, context: context) === base)
    }

    func testStyledMarkKeepsTheMargin() throws {
        let base = TestImages.make(width: 400, height: 300, color: black)
        var options = textOptions("IIII", anchor: .bottomRight)
        options.content = .text(TextWatermark(
            text: "IIII", fontName: "Helvetica-Bold", color: .white,
            shadow: WatermarkShadow(color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1), blur: 10, offset: 20),
            outline: WatermarkOutline(color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), width: 20)))
        let out = try ImageOps.watermark(base, options, asset: nil)
        // 9 px margin on the right and bottom: nothing at all is drawn there.
        XCTAssertTrue(hasInk(out, x: 0..<400, y: 200..<291, base: 0))
        XCTAssertFalse(contains(out, x: 392..<400, y: 0..<300) { $0.red > 20 || $0.blue > 20 })
        XCTAssertFalse(contains(out, x: 0..<400, y: 292..<300) { $0.red > 20 || $0.blue > 20 })
    }

    func testLargeTiledShadowCompletes() throws {
        // 24 MP, the tiled built-in with a shadow: one stamped draw per tile, so this stays quick.
        let base = TestImages.make(width: 6000, height: 4000, color: white)
        var options = WatermarkTemplates.builtIns[1].options
        options.content = .text(TextWatermark(text: "© Someone", shadow: WatermarkShadow()))
        let start = Date()
        let out = try ImageOps.watermark(base, options, asset: nil)
        XCTAssertEqual(out.width, 6000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        // Marks really were drawn, near the corners too.
        XCTAssertTrue(contains(out, x: 0..<400, y: 0..<400) { $0.red < 245 })
        XCTAssertTrue(contains(out, x: 5600..<6000, y: 3600..<4000) { $0.red < 245 })
    }
}
