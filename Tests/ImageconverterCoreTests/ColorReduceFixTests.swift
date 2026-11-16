import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

/// Fix round 1 of the Color step: sparse or empty samples, transparency with 256 colours, exact nearest colours,
/// gray output, palette PNG structure, memory count.
final class ColorReduceFixTests: XCTestCase {
    private func reduce(_ image: CGImage, _ count: Int, dither: Bool = false,
                        profile: ColorProfile = .keep) throws -> CGImage {
        try ImageOps.color(image, ColorOptions(profile: profile, reduce: ColorReduction(isEnabled: true, count: count,
                                                                                         dither: dither)))
    }

    private func srgbContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func visibleColors(_ image: CGImage) throws -> (colors: Set<UInt32>, visible: Int) {
        let pixels = try PixelBuffer(image, step: "test").bytes
        var colors = Set<UInt32>()
        var visible = 0
        for start in stride(from: 0, to: pixels.count, by: 4) where pixels[start + 3] > 0 {
            visible += 1
            colors.insert(UInt32(pixels[start]) << 16 | UInt32(pixels[start + 1]) << 8 | UInt32(pixels[start + 2]))
        }
        return (colors, visible)
    }

    private func png() -> OutputSettings {
        var settings = OutputSettings()
        settings.format = .png
        return settings
    }

    /// The reviewer's crash: the 512 px sample of a wide transparent canvas has no visible pixels.
    func testSparsePixelsOnAWideTransparentCanvas() throws {
        let ctx = try srgbContext(width: 30_000, height: 600)
        for dot in 0..<40 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(dot) / 40, green: CGFloat(39 - dot) / 40, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 100 + dot * 731, y: 17 + dot * 13, width: 1, height: 1))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        for dither in [false, true] {
            let out = try reduce(image, 16, dither: dither)
            let (colors, visible) = try visibleColors(out)
            XCTAssertEqual(visible, 40)
            XCTAssertLessThanOrEqual(colors.count, 16)
            XCTAssertGreaterThan(colors.count, 1)
        }
    }

    func testAllTransparentIsUnchanged() throws {
        let clear = TestImages.make(width: 600, height: 600, alpha: 0)
        let out = try reduce(clear, 8, dither: true)
        XCTAssertEqual(try visibleColors(out).visible, 0)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertNil(result.note)
    }

    func testSingleColourIsUnchanged() throws {
        let solid = TestImages.make(width: 700, height: 20)
        XCTAssertEqual(try PixelBuffer(reduce(solid, 2), step: "t").bytes, try PixelBuffer(solid, step: "t").bytes)
    }

    func testTransparencyLeavesRoomForItsPaletteEntry() throws {
        let ctx = try srgbContext(width: 64, height: 64)
        ctx.draw(TestImages.noise(width: 64, height: 32), in: CGRect(x: 0, y: 32, width: 64, height: 32))
        let out = try reduce(try XCTUnwrap(ctx.makeImage()), 256, profile: .sRGB)
        XCTAssertLessThanOrEqual(try visibleColors(out).colors.count, 255)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertNil(result.note)
        XCTAssertEqual([UInt8](result.data)[25], 3)
    }

    func testGrayOutputHasNoNote() throws {
        let out = try reduce(TestImages.noise(width: 40, height: 40), 4, profile: .gray)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertNil(result.note)
        let model = try TestImages.properties(of: result.data)[kCGImagePropertyColorModel as String] as? String
        XCTAssertEqual(model, kCGImagePropertyColorModelGray as String)
    }

    func testLaterStepChangesAreNamed() throws {
        let reduced = try reduce(TestImages.noise(width: 40, height: 40), 8, profile: .sRGB)
        let adjusted = try Adjustments.apply(AdjustOptions(exposure: 30), to: reduced)
        let result = try CompressionSearch.encode(adjusted, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertEqual(result.note, IndexedPNG.note(IndexedPNG.changedAfterReduce))
    }

    func testNearestColourIsExactForClosePaletteEntries() {
        let palette = [RGB(red: 10, green: 10, blue: 10), RGB(red: 12, green: 12, blue: 12),
                       RGB(red: 200, green: 30, blue: 30)]
        let table = NearestTable(palette: palette)
        XCTAssertEqual(table.index(10, 10, 10), 0)
        XCTAssertEqual(table.index(12, 12, 12), 1)
        XCTAssertEqual(table.index(13, 13, 13), 1)
        XCTAssertEqual(table.index(201, 30, 29), 2)
        // Every palette colour maps to itself.
        let many = (0..<256).map { RGB(red: UInt8($0), green: UInt8(255 - $0), blue: UInt8(($0 * 7) % 256)) }
        let big = NearestTable(palette: many)
        for (index, color) in many.enumerated() {
            XCTAssertEqual(big.index(Int(color.red), Int(color.green), Int(color.blue)), index)
        }
    }

    func testPalettePNGChunksAndCRCs() throws {
        let ctx = try srgbContext(width: 30, height: 30)
        ctx.draw(TestImages.noise(width: 30, height: 15), in: CGRect(x: 0, y: 0, width: 30, height: 15))
        let out = try reduce(try XCTUnwrap(ctx.makeImage()), 12, dither: true, profile: .sRGB)
        let data = [UInt8](try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true).data)
        XCTAssertEqual(Array(data[0..<8]), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var offset = 8
        var types: [String] = []
        while offset + 12 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8
                | Int(data[offset + 3])
            let body = Array(data[offset + 4..<offset + 8 + length])
            let stored = data[offset + 8 + length..<offset + 12 + length].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            XCTAssertEqual(IndexedPNG.crc32(body), stored)
            types.append(String(bytes: body.prefix(4), encoding: .ascii) ?? "")
            offset += 12 + length
        }
        XCTAssertEqual(offset, data.count)
        XCTAssertEqual(data[25], 3)
        let plte = try XCTUnwrap(types.firstIndex(of: "PLTE"))
        let trns = try XCTUnwrap(types.firstIndex(of: "tRNS"))
        let idat = try XCTUnwrap(types.firstIndex(of: "IDAT"))
        XCTAssertEqual(types.first, "IHDR")
        XCTAssertEqual(types.last, "IEND")
        XCTAssertTrue(plte < trns && trns < idat, "\(types)")
    }

    func testWorkingCopiesCount() {
        XCTAssertEqual(ColorOptions.sRGB.workingCopies, 1)
        XCTAssertEqual(ColorOptions(reduce: ColorReduction(isEnabled: true)).workingCopies, 2)
        XCTAssertEqual(ColorOptions(recolor: RecolorOptions(kind: .sepia)).workingCopies, 5)
        XCTAssertEqual(ColorOptions(recolor: RecolorOptions(kind: .sepia), reduce: ColorReduction(isEnabled: true))
            .workingCopies, 5)
    }
}
