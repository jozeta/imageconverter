import XCTest
import UniformTypeIdentifiers
@testable import ImageconverterCore

final class OutputFormatTests: XCTestCase {
    func testExtensionsAndTypes() {
        XCTAssertEqual(OutputFormat.jpeg.fileExtensions.first, "jpg")
        XCTAssertEqual(OutputFormat.tiff.fileExtensions, ["tif", "tiff"])
        XCTAssertEqual(OutputFormat.heic.utType, .heic)
    }

    func testAvailableFiltersAndKeepsOrder() {
        let fmts = OutputFormat.available(writableTypeIdentifiers: ["public.png", "public.jpeg", "com.example.nope"])
        XCTAssertEqual(fmts, [.jpeg, .png])
    }

    func testSystemWritesTheCoreFour() {
        let fmts = OutputFormat.available()
        for fmt in [OutputFormat.jpeg, .png, .heic, .tiff] { XCTAssertTrue(fmts.contains(fmt), "\(fmt)") }
    }

    func testSettingsDefaultsAndCodable() throws {
        let settings = OutputSettings()
        XCTAssertEqual(settings.quality, 0.82)
        XCTAssertEqual(settings.format, .jpeg)
        let back = try JSONDecoder().decode(OutputSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back, settings)
    }

    func testDecodesOldOutputSettings() throws {
        let json = Data(#"{"format":"png","quality":0.5}"#.utf8)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: json)
        XCTAssertEqual(decoded.format, .png)
        XCTAssertFalse(decoded.progressive)
        XCTAssertTrue(decoded.optimizePNG)
    }
}
