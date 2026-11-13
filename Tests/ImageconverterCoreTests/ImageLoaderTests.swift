import ImageIO
import XCTest
@testable import ImageconverterCore

final class ImageLoaderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLoadsPNG() throws {
        let url = dir.appendingPathComponent("a.png")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .png)
        let loaded = try ImageLoader.load(url)
        XCTAssertEqual(loaded.image.width, 40)
        XCTAssertEqual(loaded.image.height, 20)
    }

    func testAppliesExifOrientation() throws {
        let url = dir.appendingPathComponent("rot.jpg")
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg,
                             properties: [kCGImagePropertyOrientation as String: 6])
        let loaded = try ImageLoader.load(url)
        XCTAssertEqual(loaded.image.width, 20)
        XCTAssertEqual(loaded.image.height, 40)
        XCTAssertEqual(loaded.properties[kCGImagePropertyOrientation as String] as? Int, 1)
    }

    func testRejectsOverPixelLimit() throws {
        let url = dir.appendingPathComponent("big.png")
        try TestImages.write(TestImages.make(width: 100, height: 100), to: url, type: .png)
        XCTAssertThrowsError(try ImageLoader.load(url, maxPixels: 9_999)) {
            XCTAssertEqual($0 as? ConversionError, .tooLarge(pixels: 10_000))
        }
    }

    func testCorruptAndEmptyFilesAreUnreadable() throws {
        let empty = dir.appendingPathComponent("empty.jpg")
        try Data().write(to: empty)
        let junk = dir.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        for url in [empty, junk] {
            XCTAssertThrowsError(try ImageLoader.load(url)) { XCTAssertEqual($0 as? ConversionError, .unreadable) }
        }
    }

    func testTooLargeReasonFormatsMegapixels() {
        XCTAssertEqual(ConversionError.tooLarge(pixels: 412_000_000).reason,
                       "Image is too large (412 MP, limit 250 MP)")
    }
}
