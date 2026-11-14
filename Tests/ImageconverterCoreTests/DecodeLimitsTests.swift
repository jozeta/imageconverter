import CoreGraphics
import ImageIO
@testable import ImageconverterCore
import XCTest

final class DecodeLimitsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A header-only TIFF (ImageIO's PNG reader already refuses implausible PNG headers by itself).
    private func writeTIFF(width: Int, height: Int, alpha: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent("header-\(width)x\(height).tiff")
        try HeaderFixtures.tiff(width: width, height: height, alpha: alpha).write(to: url)
        return url
    }

    func testDefaults() {
        let limits = DecodeLimits.standard
        XCTAssertEqual(limits.maxPixels, 250_000_000)
        XCTAssertEqual(limits.maxSide, 65_535)
        XCTAssertEqual(limits.maxFileBytes, 2 << 30)
        let memory = Int(clamping: ProcessInfo.processInfo.physicalMemory / 4)
        XCTAssertEqual(limits.maxDecodedBytes, min(4 << 30, memory))
        XCTAssertEqual(DecodeLimits.maxFramesInspected, 1)
    }

    func testRejectsTooWideImage() throws {
        let url = try writeTIFF(width: 70_000, height: 10)
        XCTAssertThrowsError(try DecodeLimits.standard.check(url)) { error in
            XCTAssertEqual(error as? ConversionError, .sideTooLong(side: 70_000, limit: 65_535))
            XCTAssertEqual((error as? ConversionError)?.reason,
                           "Image is too large (70,000 px on one side, limit 65,535 px)")
        }
        // The loader, the thumbnail path and the alpha scan all refuse it before decoding.
        XCTAssertThrowsError(try ImageLoader.load(url)) { error in
            XCTAssertEqual(error as? ConversionError, .sideTooLong(side: 70_000, limit: 65_535))
        }
        XCTAssertNil(ImageLoader.thumbnail(of: url, maxPixelSize: 64))
        XCTAssertFalse(DecodeLimits.standard.allows(url))
    }

    func testRejectsMemoryOverLimit() throws {
        let url = dir.appendingPathComponent("small.png")
        try TestImages.write(TestImages.make(width: 100, height: 100), to: url, type: .png)
        // 100 × 100 RGBA8 × 1.5 for working copies = 60 000 bytes.
        let tight = DecodeLimits(maxDecodedBytes: 59_999)
        XCTAssertThrowsError(try ImageLoader.load(url, limits: tight)) { error in
            XCTAssertEqual(error as? ConversionError, .needsTooMuchMemory(limit: 59_999))
            XCTAssertTrue((error as? ConversionError)?.reason.hasPrefix("Would need more than ") ?? false)
            XCTAssertTrue((error as? ConversionError)?.reason.hasSuffix(" of memory to open") ?? false)
        }
        XCTAssertNoThrow(try ImageLoader.load(url, limits: DecodeLimits(maxDecodedBytes: 60_000)))
        XCTAssertNil(ImageLoader.thumbnail(of: url, maxPixelSize: 32, limits: tight))
    }

    func testBytesPerPixelFromHeader() {
        func header(_ depth: Int, _ model: String, alpha: Bool) -> [String: Any] {
            [kCGImagePropertyDepth as String: depth, kCGImagePropertyColorModel as String: model,
             kCGImagePropertyHasAlpha as String: alpha]
        }
        XCTAssertEqual(DecodeLimits.bytesPerPixel(header(8, "RGB", alpha: false)), 4)
        XCTAssertEqual(DecodeLimits.bytesPerPixel(header(16, "RGB", alpha: true)), 8)
        XCTAssertEqual(DecodeLimits.bytesPerPixel(header(32, "RGB", alpha: true)), 16)
        // Working copies are RGBA, so grey never counts fewer than four channels.
        XCTAssertEqual(DecodeLimits.bytesPerPixel(header(8, "Gray", alpha: false)), 4)
        XCTAssertEqual(DecodeLimits.bytesPerPixel(header(8, "CMYK", alpha: true)), 5)
        XCTAssertEqual(DecodeLimits.bytesPerPixel([:]), 4)
    }

    func testMemoryLimitUsesReducedDecodeSize() throws {
        let jpeg = dir.appendingPathComponent("photo.jpg")
        let png = dir.appendingPathComponent("photo.png")
        let image = TestImages.noise(width: 400, height: 300)
        try TestImages.write(image, to: jpeg, type: .jpeg)
        try TestImages.write(image, to: png, type: .png)
        // Full size: 400 × 300 × 4 × 1.5 = 720 000 bytes; at a 100 px long side: 100 × 75 × 4 × 1.5 = 45 000.
        let limits = DecodeLimits(maxDecodedBytes: 100_000)
        XCTAssertThrowsError(try ImageLoader.load(jpeg, limits: limits)) { error in
            XCTAssertEqual(error as? ConversionError, .needsTooMuchMemory(limit: 100_000))
        }
        let loaded = try ImageLoader.load(jpeg, limits: limits, maxLongSide: 100)
        XCTAssertEqual(loaded.image.width, 100)
        XCTAssertNotNil(ImageLoader.thumbnail(of: jpeg, maxPixelSize: 100, limits: limits))
        XCTAssertNil(ImageLoader.thumbnail(of: jpeg, maxPixelSize: 300, limits: limits))
        // PNG may hold the full image while decoding: still counted at full size.
        XCTAssertThrowsError(try ImageLoader.load(png, limits: limits, maxLongSide: 100))
        XCTAssertNil(ImageLoader.thumbnail(of: png, maxPixelSize: 100, limits: limits))
        // Side and pixel limits stay on the declared size.
        XCTAssertThrowsError(try ImageLoader.load(jpeg, limits: DecodeLimits(maxPixels: 100_000), maxLongSide: 100)) {
            XCTAssertEqual($0 as? ConversionError, .tooLarge(pixels: 120_000))
        }
        XCTAssertThrowsError(try ImageLoader.load(jpeg, limits: DecodeLimits(maxSide: 399), maxLongSide: 100))
    }

    func testFileSizeLimit() throws {
        let url = dir.appendingPathComponent("small.png")
        try TestImages.write(TestImages.make(width: 10, height: 10), to: url, type: .png)
        XCTAssertThrowsError(try DecodeLimits(maxFileBytes: 10).check(url)) { error in
            XCTAssertEqual(error as? ConversionError, .fileTooLarge(limit: 10))
        }
    }

    func testBombHeuristic() throws {
        // A 70-byte PNG that declares 30 000 × 30 000 (900 MP, 3.6 GB decoded): ImageIO itself won't read its
        // header, so it never gets near a decode.
        let png = dir.appendingPathComponent("bomb.png")
        try HeaderFixtures.png(width: 30_000, height: 30_000).write(to: png)
        let started = Date()
        XCTAssertThrowsError(try ImageLoader.load(png)) { error in
            XCTAssertEqual(error as? ConversionError, .unreadable)
        }
        // The same declaration in a TIFF header that ImageIO does read: refused by the heuristic.
        let url = try writeTIFF(width: 30_000, height: 30_000)
        XCTAssertThrowsError(try ImageLoader.load(url)) { error in
            XCTAssertEqual(error as? ConversionError, .suspectedDecompressionBomb)
        }
        XCTAssertNil(ImageLoader.thumbnail(of: url, maxPixelSize: 64))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "must not decode")
        // 60 MP in 150 bytes, within every hard limit: flat colour may compress that well, so it passes the gate.
        let flat = try writeTIFF(width: 10_000, height: 6_000)
        XCTAssertNoThrow(try DecodeLimits.standard.check(flat))
        // The same file over a (small, injected) memory limit gets the bomb reason.
        XCTAssertThrowsError(try DecodeLimits(maxDecodedBytes: 100_000_000).check(flat)) { error in
            XCTAssertEqual(error as? ConversionError, .suspectedDecompressionBomb)
        }

        let limits = DecodeLimits(maxPixels: 1_000_000_000, maxDecodedBytes: 1 << 40)
        let pixels60MP = (width: 10_000, height: 6_000)
        // Within the hard limits a tiny file passes, in every format (a flat 60 MP JPEG at 200 KB).
        XCTAssertNoThrow(try limits.check(width: pixels60MP.width, height: pixels60MP.height, bytesPerPixel: 4,
                                          fileBytes: 200_000, type: "public.jpeg"))
        XCTAssertNoThrow(try limits.check(width: pixels60MP.width, height: pixels60MP.height, bytesPerPixel: 4,
                                          fileBytes: 200_000, type: "public.tiff"))
        // Over a hard limit, tiny gives the bomb reason, large the limit's own reason.
        let tight = DecodeLimits(maxPixels: 1_000_000_000, maxDecodedBytes: 100_000_000)
        XCTAssertThrowsError(try tight.check(width: pixels60MP.width, height: pixels60MP.height, bytesPerPixel: 4,
                                             fileBytes: 200_000, type: "public.jpeg")) { error in
            XCTAssertEqual(error as? ConversionError, .suspectedDecompressionBomb)
        }
        XCTAssertThrowsError(try tight.check(width: pixels60MP.width, height: pixels60MP.height, bytesPerPixel: 4,
                                             fileBytes: 300_000, type: "public.jpeg")) { error in
            XCTAssertEqual(error as? ConversionError, .needsTooMuchMemory(limit: 100_000_000))
        }
        // Under 50 MP the ratio doesn't matter.
        XCTAssertNoThrow(try limits.check(width: 7_000, height: 7_000, bytesPerPixel: 4, fileBytes: 100,
                                          type: "public.jpeg"))
        // Flat-colour PNG/GIF too; only refused when it also breaks a hard limit.
        XCTAssertNoThrow(try limits.check(width: pixels60MP.width, height: pixels60MP.height, bytesPerPixel: 4,
                                          fileBytes: 1_000, type: "public.png"))
        XCTAssertThrowsError(try DecodeLimits.standard.check(width: 20_000, height: 20_000, bytesPerPixel: 4,
                                                             fileBytes: 1_000, type: "com.compuserve.gif")) { error in
            XCTAssertEqual(error as? ConversionError, .suspectedDecompressionBomb)
        }
        // Unknown file size (data the app encoded itself): no heuristic, the hard limits still apply.
        XCTAssertNoThrow(try limits.check(width: pixels60MP.width, height: pixels60MP.height, bytesPerPixel: 4,
                                          fileBytes: nil, type: "public.jpeg"))
    }

    func testHardLimitsWithoutBomb() throws {
        XCTAssertThrowsError(try DecodeLimits.standard.check(width: 20_000, height: 20_000, bytesPerPixel: 4,
                                                             fileBytes: 1 << 30, type: "public.tiff")) { error in
            XCTAssertEqual(error as? ConversionError, .tooLarge(pixels: 400_000_000))
        }
        XCTAssertThrowsError(try DecodeLimits.standard.check(width: Int.max, height: 2, bytesPerPixel: 4,
                                                             fileBytes: nil, type: "public.tiff"))
        XCTAssertThrowsError(try DecodeLimits.standard.check(width: 0, height: 2, bytesPerPixel: 4,
                                                             fileBytes: nil, type: "public.tiff")) { error in
            XCTAssertEqual(error as? ConversionError, .unreadable)
        }
    }

    func testCappedKeepsTheSmallerPixelLimit() {
        XCTAssertEqual(DecodeLimits.standard.capped(maxPixels: 1_000).maxPixels, 1_000)
        XCTAssertEqual(DecodeLimits.standard.capped(maxPixels: .max).maxPixels, 250_000_000)
    }

    func testThumbnailOfNormalImage() throws {
        let url = dir.appendingPathComponent("normal.png")
        try TestImages.write(TestImages.make(width: 200, height: 100), to: url, type: .png)
        let thumbnail = try XCTUnwrap(ImageLoader.thumbnail(of: url, maxPixelSize: 50))
        XCTAssertEqual(thumbnail.width, 50)
        XCTAssertEqual(thumbnail.height, 25)
    }

    func testAlphaScanSkippedForRefusedImage() throws {
        let url = try writeTIFF(width: 30_000, height: 30_000, alpha: true)
        // The header says alpha; a refused image is never scanned, so the header decides.
        let facts = try XCTUnwrap(ItemFacts.read(url))
        XCTAssertTrue(facts.hasAlpha)
        XCTAssertEqual(facts.width, 30_000)
    }
}
