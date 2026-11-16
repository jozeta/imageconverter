import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Pixelate's block size and Blur's radius: Auto (scaled to each box) or a fixed number of pixels.
final class RedactSizeTests: XCTestCase {
    func testAutoScalesWithTheBoxAndFixedIsTheSameForEveryBox() {
        let small = CGRect(x: 0, y: 0, width: 30, height: 21)
        let large = CGRect(x: 0, y: 0, width: 600, height: 300)
        let auto = RedactOptions(style: .pixelate)
        XCTAssertEqual(auto.blockSize(for: small), 7)
        XCTAssertEqual(auto.blockSize(for: large), 100)
        XCTAssertEqual(auto.blurRadius(for: large), 100)
        var fixed = auto
        fixed.fixedBlockSize = 12
        fixed.fixedBlurRadius = 9
        XCTAssertEqual(fixed.blockSize(for: small), 12)
        XCTAssertEqual(fixed.blockSize(for: large), 12)
        XCTAssertEqual(fixed.blurRadius(for: large), 9)
    }

    func testFixedValuesAreClamped() {
        var options = RedactOptions()
        options.fixedBlockSize = 1
        options.fixedBlurRadius = 5000
        XCTAssertEqual(options.clampedBlockSize, 4)
        XCTAssertEqual(options.clampedBlurRadius, 200)
        options.fixedBlockSize = .nan
        options.fixedBlurRadius = .infinity
        XCTAssertNil(options.clampedBlockSize, "not a number: Auto")
        XCTAssertNil(options.clampedBlurRadius)
        XCTAssertEqual(RedactOptions.blockSizeRange, 4...256)
    }

    func testSavedLenientlyAndOldStepsStayAuto() throws {
        let old = try JSONDecoder().decode(RedactOptions.self,
                                           from: Data(#"{"target":"text","style":"pixelate","padding":15}"#.utf8))
        XCTAssertNil(old.fixedBlockSize)
        XCTAssertNil(old.fixedBlurRadius)
        let encodedOld = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertFalse(encodedOld.contains("blockSize"), "Auto isn't written, so older versions read it as before")
        var options = RedactOptions(target: .faces, style: .pixelate)
        options.fixedBlockSize = 24
        options.fixedBlurRadius = 10
        let data = try JSONEncoder().encode(options)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""blockSize":24"#), json)
        XCTAssertTrue(json.contains(#""blurRadius":10"#), json)
        XCTAssertEqual(try JSONDecoder().decode(RedactOptions.self, from: data), options)
        let odd = try JSONDecoder().decode(RedactOptions.self,
                                           from: Data(#"{"style":"pixelate","blockSize":"big","blurRadius":null}"#.utf8))
        XCTAssertNil(odd.fixedBlockSize)
        XCTAssertNil(odd.fixedBlurRadius)
    }

    func testSummaryNamesAFixedSizeForTheChosenStyle() {
        var options = RedactOptions(style: .pixelate)
        options.fixedBlockSize = 16
        options.fixedBlurRadius = 8
        XCTAssertEqual(options.summary, "faces · pixelate · blocks 16 px")
        options.style = .blur
        XCTAssertEqual(options.summary, "faces · blur · radius 8 px")
        options.style = .fill
        XCTAssertEqual(options.summary, "faces · solid colour")
    }

    func testFixedBlockSizeDrawsBlocksOfThatSize() throws {
        let image = TestImages.noise(width: 80, height: 80)
        let rect = CGRect(x: 0, y: 0, width: 80, height: 80)
        var options = RedactOptions(style: .pixelate)
        options.fixedBlockSize = 4
        let out = try ImageOps.redact(image, options, rects: [rect])
        // Blocks start at the box's corner: (0…3, 0…3) is one colour, (4, 0) the next block.
        let first = TestImages.pixel(of: out, x: 0, y: 0)
        let same = TestImages.pixel(of: out, x: 3, y: 3)
        XCTAssertEqual(first.red, same.red, accuracy: 1)
        XCTAssertEqual(first.green, same.green, accuracy: 1)
        var differs = 0
        for block in 1..<10 where abs(TestImages.pixel(of: out, x: block * 4, y: 0).red
                                     - TestImages.pixel(of: out, x: block * 4 - 1, y: 0).red) > 2 {
            differs += 1
        }
        XCTAssertGreaterThan(differs, 5, "4 px blocks, not Auto's 27 px")
    }

    func testFixedBlurRadiusKeepsMoreDetailWhenSmall() throws {
        let image = TestImages.noise(width: 120, height: 120)
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        var light = RedactOptions(style: .blur)
        light.fixedBlurRadius = 2
        let soft = try ImageOps.redact(image, light, rects: [rect])
        let strong = try ImageOps.redact(image, RedactOptions(style: .blur), rects: [rect])
        XCTAssertGreaterThan(Self.roughness(soft), Self.roughness(strong) * 3)
    }

    /// Mean difference between horizontal neighbours on the middle row (red).
    private static func roughness(_ image: CGImage) -> Double {
        var sum = 0.0
        for col in 30..<90 {
            sum += abs(TestImages.pixel(of: image, x: col, y: 60).red - TestImages.pixel(of: image, x: col + 1, y: 60).red)
        }
        return sum / 60
    }
}
