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
