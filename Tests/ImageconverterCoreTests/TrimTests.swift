import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class TrimTests: XCTestCase {
    /// A `size` x `size` image of `background` with `content` filling rows/columns `inner` (top-left origin).
    private func framed(size: Int = 100, inner: ClosedRange<Int>, background: CGColor, content: CGColor) -> CGImage {
        // sRGB, so a colour picked for the `.color` mode matches the pixels exactly.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Couldn't create a bitmap context")
        }
        let srgb: (CGColor) -> CGColor = { $0.converted(to: space, intent: .defaultIntent, options: nil) ?? $0 }
        ctx.setFillColor(srgb(background))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(srgb(content))
        let side = inner.count
        ctx.fill(CGRect(x: inner.lowerBound, y: size - inner.upperBound - 1, width: side, height: side))
        guard let image = ctx.makeImage() else { fatalError("Couldn't make an image") }
        return image
    }

    private let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    func testTrimTransparentBorders() throws {
        let image = framed(inner: 20...79, background: clear, content: red)
        let out = try Trim.apply(TrimOptions(), to: image)
        XCTAssertEqual(out.width, 60)
        XCTAssertEqual(out.height, 60)
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 0, y: 0).red, 240)
    }

    func testTrimEdgeColorWithTolerance() throws {
        // A near-white border (250 vs 255) around a white frame still counts as the edge colour at 10 %.
        let image = framed(inner: 10...89, background: CGColor(red: 1, green: 1, blue: 1, alpha: 1), content: red)
        let noisy = try ImageOps.canvas(image, CanvasOptions(
            mode: .padding(pixels: 5), background: RGBAColor(red: 250 / 255, green: 1, blue: 1, alpha: 1)))
        XCTAssertEqual(noisy.width, 110)
        let out = try Trim.apply(TrimOptions(mode: .edgeColor, tolerance: 10), to: noisy)
        XCTAssertEqual(out.width, 80)
        XCTAssertEqual(out.height, 80)
        // With no tolerance only the 5 px border of the exact top-left colour goes.
        let strict = try Trim.apply(TrimOptions(mode: .edgeColor, tolerance: 0), to: noisy)
        XCTAssertEqual(strict.width, 100)
        XCTAssertEqual(strict.height, 100)
    }

    func testTrimColorMode() throws {
        let image = framed(inner: 30...69, background: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), content: red)
        let out = try Trim.apply(TrimOptions(mode: .color(RGBAColor(red: 0, green: 0, blue: 1, alpha: 1))), to: image)
        XCTAssertEqual(out.width, 40)
        XCTAssertEqual(out.height, 40)
    }

    func testTrimAsymmetricKeepsTheRightRegion() throws {
        // Content near the top left: columns 5...34, rows 10...29 (top-left origin), in a 100 x 80 image.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("context")
        }
        ctx.setFillColor(red)
        ctx.fill(CGRect(x: 5, y: 80 - 30, width: 30, height: 20))
        // One blue pixel marks the content's top-left corner.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 5, y: 80 - 11, width: 1, height: 1))
        guard let image = ctx.makeImage() else { return XCTFail("image") }
        let out = try Trim.apply(TrimOptions(), to: image)
        XCTAssertEqual(out.width, 30)
        XCTAssertEqual(out.height, 20)
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 0, y: 0).blue, 240)
        XCTAssertGreaterThan(TestImages.pixel(of: out, x: 29, y: 19).red, 240)
    }

    func testTrimStripsMatchAFullScan() throws {
        // Strips smaller than the image exercise the strip boundaries.
        let image = framed(size: 3000, inner: 1234...2001, background: clear, content: red)
        let out = try Trim.apply(TrimOptions(), to: image)
        XCTAssertEqual(out.width, 768)
        XCTAssertEqual(out.height, 768)
    }

    func testTrimPadding() throws {
        let image = framed(inner: 20...79, background: clear, content: red)
        let out = try Trim.apply(TrimOptions(padding: 5), to: image)
        XCTAssertEqual(out.width, 70)
        XCTAssertEqual(out.height, 70)
        // Padding never goes past the image.
        let wide = try Trim.apply(TrimOptions(padding: 50), to: image)
        XCTAssertEqual(wide.width, 100)
    }

    func testTrimBlankUnchanged() throws {
        let blank = TestImages.make(width: 50, height: 40, color: clear, alpha: 0)
        XCTAssertTrue(try Trim.apply(TrimOptions(), to: blank) === blank)
        let solid = TestImages.make(width: 50, height: 40)
        XCTAssertTrue(try Trim.apply(TrimOptions(mode: .edgeColor), to: solid) === solid)
    }

    func testTrimOptionsDecodeLeniently() throws {
        let options = try JSONDecoder().decode(TrimOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, TrimOptions())
        XCTAssertEqual(options.tolerance, 10)
        XCTAssertEqual(ImageOperation.trim(TrimOptions(padding: 4)).summary, "transparent · 10 % · +4 px")
    }
}
