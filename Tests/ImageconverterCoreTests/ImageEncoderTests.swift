import ImageIO
import XCTest
@testable import ImageconverterCore

final class ImageEncoderTests: XCTestCase {
    func testRoundTripsEveryAvailableFormat() throws {
        let img = TestImages.make(width: 32, height: 16)
        for format in OutputFormat.available() {
            let data = try ImageEncoder.encode(img, properties: [:], settings: .init(format: format))
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(src) as String?, format.utType.identifier, "\(format)")
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 32, "\(format)")
        }
    }

    func testJPEGQualityAffectsSize() throws {
        let img = TestImages.noise(width: 128, height: 128)
        let low = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: 0.3))
        let high = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: 0.95))
        XCTAssertLessThan(low.count, high.count)
    }

    func testOutOfRangeQualityIsClamped() throws {
        let img = TestImages.noise(width: 64, height: 64)
        XCTAssertNoThrow(try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: 7)))
        XCTAssertNoThrow(try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: -3)))
    }

    func testTransparentToJPEGIsWhite() throws {
        let clear = TestImages.make(width: 8, height: 8, color: CGColor(gray: 0, alpha: 0), alpha: 0)
        let data = try ImageEncoder.encode(clear, properties: [:], settings: .init(format: .jpeg))
        XCTAssertEqual(try TestImages.pixel(of: data, x: 4, y: 4).red, 255, accuracy: 3)
    }

    func testTransparentPNGStaysTransparent() throws {
        let clear = TestImages.make(width: 8, height: 8, color: CGColor(gray: 0, alpha: 0), alpha: 0)
        let data = try ImageEncoder.encode(clear, properties: [:], settings: .init(format: .png))
        XCTAssertEqual(try TestImages.pixel(of: data, x: 4, y: 4).alpha, 0, accuracy: 3)
    }

    func testWritesOrientationOneAndTIFFCompression() throws {
        let data = try ImageEncoder.encode(TestImages.make(width: 8, height: 8),
            properties: [kCGImagePropertyOrientation as String: 6],
            settings: .init(format: .tiff, tiffCompression: .lzw))
        let props = try TestImages.properties(of: data)
        XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 1)
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFCompression as String] as? Int, 5)
    }

    func testStalePixelSizePropertiesAreIgnored() throws {
        let stale: [String: Any] = [
            kCGImagePropertyPixelWidth as String: 16,
            kCGImagePropertyPixelHeight as String: 32,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifPixelXDimension as String: 16,
                kCGImagePropertyExifPixelYDimension as String: 32,
            ],
        ]
        for format in [OutputFormat.jpeg, .png, .tiff] {
            let data = try ImageEncoder.encode(TestImages.make(width: 32, height: 16),
                                               properties: stale, settings: .init(format: format))
            let props = try TestImages.properties(of: data)
            XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 32, "\(format)")
            XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 16, "\(format)")
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            if let width = exif?[kCGImagePropertyExifPixelXDimension as String] as? Int {
                XCTAssertEqual(width, 32, "\(format)")
            }
        }
    }

    func testProgressiveJPEGFlag() throws {
        let img = TestImages.noise(width: 64, height: 64)
        let data = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, progressive: true))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        let jfif = try XCTUnwrap(props[kCGImagePropertyJFIFDictionary as String] as? [String: Any])
        XCTAssertEqual(jfif[kCGImagePropertyJFIFIsProgressive as String] as? Bool, true)
    }

    func testOptimizedPNGNotLargerAndIdenticalPixels() throws {
        let img = TestImages.noise(width: 64, height: 64)
        let plain = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .png, optimizePNG: false))
        let opt = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .png, optimizePNG: true))
        XCTAssertLessThanOrEqual(opt.count, plain.count)
        for (col, row) in [(0, 0), (10, 20), (63, 63)] {
            let before = try TestImages.pixel(of: plain, x: col, y: row)
            let after = try TestImages.pixel(of: opt, x: col, y: row)
            XCTAssertEqual(before.red, after.red)
            XCTAssertEqual(before.green, after.green)
            XCTAssertEqual(before.blue, after.blue)
        }
    }

    func testAVIFRoundTripWhenAvailable() throws {
        try XCTSkipUnless(OutputFormat.available().contains(.avif), "AVIF not writable here")
        let img = TestImages.make(width: 32, height: 16)
        let data = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .avif, quality: 0.6))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 32)
    }

    func testQualityZeroEncodes() throws {
        let img = TestImages.noise(width: 64, height: 64)
        let data = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .jpeg, quality: 0))
        XCTAssertFalse(data.isEmpty)
    }
}

extension ImageEncoderTests {
    func testOptimizedPNGOnStructuredImage() throws {
        let img = CompressionImages.gradient(width: 160, height: 96)
        let plain = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .png, optimizePNG: false))
        let opt = try ImageEncoder.encode(img, properties: [:], settings: .init(format: .png, optimizePNG: true))
        XCTAssertLessThanOrEqual(opt.count, plain.count)
        XCTAssertEqual(try CompressionImages.rgbaBytes(of: opt), try CompressionImages.rgbaBytes(of: plain))
    }

    func testProgressiveIgnoredForNonJPEG() throws {
        let img = TestImages.noise(width: 48, height: 32)
        for format in [OutputFormat.png, .tiff] {
            let plain = try ImageEncoder.encode(img, properties: [:],
                                                settings: .init(format: format, progressive: false, optimizePNG: false))
            let prog = try ImageEncoder.encode(img, properties: [:],
                                               settings: .init(format: format, progressive: true, optimizePNG: false))
            XCTAssertEqual(plain, prog, "\(format)")
            XCTAssertNil(try TestImages.properties(of: prog)[kCGImagePropertyJFIFDictionary as String], "\(format)")
        }
    }
}
