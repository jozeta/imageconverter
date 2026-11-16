import CoreGraphics
import ImageIO
import XCTest
@testable import ImageconverterCore

/// Reduce colours: palette size, determinism, alpha, dithering, indexed PNG output.
final class ColorReduceTests: XCTestCase {
    private func reduce(_ image: CGImage, _ count: Int, dither: Bool = false) throws -> CGImage {
        try ImageOps.color(image, ColorOptions(profile: .keep, reduce: ColorReduction(isEnabled: true, count: count,
                                                                                       dither: dither)))
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        // swiftlint:disable:next force_try
        try! PixelBuffer(image, step: "test").bytes
    }

    private func colors(_ image: CGImage) -> Set<UInt32> {
        var result = Set<UInt32>()
        let pixels = bytes(image)
        for start in stride(from: 0, to: pixels.count, by: 4) where pixels[start + 3] > 0 {
            result.insert(UInt32(pixels[start]) << 16 | UInt32(pixels[start + 1]) << 8 | UInt32(pixels[start + 2]))
        }
        return result
    }

    func testAtMostNColours() throws {
        let noise = TestImages.noise(width: 64, height: 48)
        XCTAssertGreaterThan(colors(noise).count, 256)
        for count in [2, 16, 256] {
            let out = try reduce(noise, count)
            XCTAssertLessThanOrEqual(colors(out).count, count)
            XCTAssertGreaterThanOrEqual(colors(out).count, min(count, 2))
            XCTAssertEqual(out.bitsPerComponent, 8)
            XCTAssertEqual(out.width, 64)
        }
        XCTAssertLessThanOrEqual(colors(try reduce(noise, 16, dither: true)).count, 16)
    }

    func testDeterministic() throws {
        let noise = TestImages.noise(width: 80, height: 60)
        XCTAssertEqual(bytes(try reduce(noise, 12, dither: true)), bytes(try reduce(noise, 12, dither: true)))
        XCTAssertEqual(bytes(try reduce(noise, 12)), bytes(try reduce(noise, 12)))
        XCTAssertNotEqual(bytes(try reduce(noise, 12, dither: true)), bytes(try reduce(noise, 12)))
    }

    func testFewColoursStayExact() throws {
        let image = TestImages.twoColor(width: 8, height: 4, left: CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1),
                                        right: CGColor(srgbRed: 0.9, green: 0.1, blue: 0.6, alpha: 1))
        XCTAssertEqual(bytes(try reduce(image, 2)), bytes(image))
    }

    func testDitheringKeepsTheAverage() throws {
        // A mid grey with only black and white available: dithering mixes them about half and half.
        let grey = TestImages.make(width: 64, height: 64, color: CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        var gradient = grey
        if let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 64))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 60, y: 0, width: 4, height: 64))
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 4, y: 0, width: 56, height: 64))
            gradient = try XCTUnwrap(ctx.makeImage())
        }
        let out = bytes(try reduce(gradient, 2, dither: true))
        var sum = 0
        for row in 0..<64 { for column in 8..<56 { sum += Int(out[(row * 64 + column) * 4]) } }
        let mean = Double(sum) / Double(64 * 48)
        XCTAssertEqual(mean, 128, accuracy: 12)
    }

    func testTransparencyKept() throws {
        let noise = TestImages.noise(width: 32, height: 32)
        guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return XCTFail("ctx") }
        ctx.draw(noise, in: CGRect(x: 0, y: 0, width: 32, height: 16))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = try reduce(image, 8, dither: true)
        XCTAssertTrue(ImageOps.hasAlpha(out))
        XCTAssertEqual(TestImages.pixel(of: out, x: 3, y: 3).alpha, 0)
        XCTAssertEqual(TestImages.pixel(of: out, x: 3, y: 28).alpha, 255)
        XCTAssertLessThanOrEqual(colors(out).count, 8)
    }

    func testGrayStaysGray() throws {
        let options = ColorOptions(profile: .gray, reduce: ColorReduction(isEnabled: true, count: 4, dither: false))
        let out = try ImageOps.color(TestImages.noise(width: 32, height: 32), options)
        XCTAssertEqual(out.colorSpace?.model, .monochrome)
        XCTAssertLessThanOrEqual(colors(out).count, 4)
    }

    // MARK: Indexed PNG

    private func png() -> OutputSettings {
        var settings = OutputSettings()
        settings.format = .png
        return settings
    }

    private func colourType(_ data: Data) -> UInt8 { [UInt8](data)[25] }

    private func hasChunk(_ data: Data, _ name: String) -> Bool { data.range(of: Data(name.utf8)) != nil }

    func testOpaqueReducedImageWritesPalettePNG() throws {
        let srgbNoise = try ImageOps.convertColor(TestImages.noise(width: 40, height: 30), to: .sRGB)
        let out = try reduce(srgbNoise, 16, dither: true)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertEqual(colourType(result.data), 3)
        XCTAssertNil(result.note)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil)), 0, nil))
        XCTAssertEqual(bytes(decoded), bytes(out), "palette PNG decodes to the same pixels")
        // Without the flag nothing changes.
        let plain = try CompressionSearch.encode(out, properties: [:], settings: png())
        XCTAssertNotEqual(colourType(plain.data), 3)
    }

    func testTransparentReducedImageGetsTRNS() throws {
        guard let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return XCTFail("ctx") }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let out = try reduce(try XCTUnwrap(ctx.makeImage()), 4)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertEqual(colourType(result.data), 3)
        XCTAssertTrue(hasChunk(result.data, "tRNS"))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil)), 0, nil))
        XCTAssertEqual(TestImages.pixel(of: decoded, x: 5, y: 2).alpha, 0)
        let red = TestImages.pixel(of: decoded, x: 5, y: 15)
        XCTAssertEqual(red.alpha, 255)
        XCTAssertEqual(red.red, 255)
    }

    func testSemiTransparentIsWrittenNormallyWithANote() throws {
        let half = TestImages.make(width: 4, height: 4, alpha: 0.5)
        let out = try reduce(half, 4)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertEqual(colourType(result.data), 6)
        XCTAssertEqual(result.note, IndexedPNG.note("it has semi-transparent pixels"))
    }

    func testWideGamutIsNotIndexed() throws {
        let wide = TestImages.displayP3(width: 4, height: 4)
        let out = try reduce(wide, 4)
        let result = try CompressionSearch.encode(out, properties: [:], settings: png(), indexedPNG: true)
        XCTAssertNotEqual(colourType(result.data), 3)
        XCTAssertNotNil(result.note)
    }

    func testBatchWritesPalettePNG() throws {
        let dir = try TestImages.tempDir()
        let source = dir.appendingPathComponent("noise.png")
        try TestImages.write(TestImages.noise(width: 48, height: 32), to: source, type: .png)
        var pipeline = Pipeline(steps: [PipelineStep(operation: .colorProfile(
            ColorOptions(profile: .sRGB, reduce: ColorReduction(isEnabled: true, count: 32, dither: true))))])
        pipeline.output.format = .png
        let encoded = try BatchRunner.encodeItem(source, pipeline: pipeline, assets: .empty, maxPixels: 10_000_000)
        XCTAssertEqual(colourType(encoded.data), 3)
    }

    func testCRC() {
        XCTAssertEqual(IndexedPNG.crc32(Array("IEND".utf8)), 0xAE42_6082)
    }

    /// Run with IC_PERF=1 to time a 24 MP reduction.
    func testLargeReductionTime() throws {
        guard ProcessInfo.processInfo.environment["IC_PERF"] == "1" else { throw XCTSkip("set IC_PERF=1") }
        let big = try XCTUnwrap(scaled(TestImages.noise(width: 600, height: 400), width: 6000, height: 4000))
        for count in [16, 256] {
            for dither in [false, true] {
                let start = Date()
                _ = try reduce(big, count, dither: dither)
                print("24 MP reduce to \(count) colours, dither \(dither): \(Date().timeIntervalSince(start)) s")
            }
        }
        let start = Date()
        _ = try ImageOps.color(big, ColorOptions(profile: .keep, recolor: RecolorOptions(kind: .replace)))
        print("24 MP replace colour: \(Date().timeIntervalSince(start)) s")
    }

    private func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }
}
