import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class ImageDifferenceTests: XCTestCase {
    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 8, height: Int = 6) -> CGImage {
        TestImages.make(width: width, height: height, color: CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    }

    func testIdenticalIsBlackAndInfinitePSNR() throws {
        let image = TestImages.noise(width: 16, height: 16)
        let diff = try XCTUnwrap(ImageDifference.render(before: image, after: image))
        for (column, row) in [(0, 0), (5, 7), (15, 15)] {
            let pixel = TestImages.pixel(of: diff, x: column, y: row)
            XCTAssertEqual([pixel.red, pixel.green, pixel.blue], [0, 0, 0])
        }
        let stats = try XCTUnwrap(ImageDifference.stats(before: image, after: image))
        XCTAssertEqual(stats.meanAbsError, 0)
        XCTAssertEqual(stats.maxError, 0)
        XCTAssertEqual(stats.psnr, .infinity)
    }

    func testDifferentSizesNil() {
        XCTAssertNil(ImageDifference.render(before: solid(0, 0, 0), after: solid(0, 0, 0, width: 9)))
        XCTAssertNil(ImageDifference.stats(before: solid(0, 0, 0), after: solid(0, 0, 0, width: 9)))
    }

    func testAmplifiedDifference() throws {
        let before = solid(100.0 / 255, 100.0 / 255, 100.0 / 255)
        let after = solid(110.0 / 255, 100.0 / 255, 90.0 / 255)
        let diff = try XCTUnwrap(ImageDifference.render(before: before, after: after, amplify: 4))
        let pixel = TestImages.pixel(of: diff, x: 3, y: 3)
        XCTAssertEqual(pixel.red, 40, accuracy: 1)
        XCTAssertEqual(pixel.green, 0)
        XCTAssertEqual(pixel.blue, 40, accuracy: 1)
        // Clamped at 255.
        let strong = try XCTUnwrap(ImageDifference.render(before: solid(0, 0, 0), after: solid(1, 1, 1), amplify: 4))
        XCTAssertEqual(TestImages.pixel(of: strong, x: 0, y: 0).red, 255)

        let stats = try XCTUnwrap(ImageDifference.stats(before: before, after: after))
        XCTAssertEqual(stats.maxError, 10)
        XCTAssertEqual(stats.meanAbsError, 20.0 / 3, accuracy: 0.1)
        XCTAssertEqual(stats.psnr, 10 * log10(255.0 * 255 / (200.0 / 3)), accuracy: 0.1)
    }

    func testAlphaInputIsOpaqueOnBlack() throws {
        let clear = TestImages.make(width: 4, height: 4, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), alpha: 0)
        let diff = try XCTUnwrap(ImageDifference.render(before: clear, after: solid(0, 0, 0, width: 4, height: 4)))
        let pixel = TestImages.pixel(of: diff, x: 1, y: 1)
        XCTAssertEqual(pixel.alpha, 255)
        XCTAssertEqual(pixel.red, 0)
    }

    func testLargeImageStripsMatchSmall() throws {
        // Wider than one strip (1 MiB) so the strip loop runs more than once.
        let before = solid(0.2, 0.2, 0.2, width: 600, height: 500)
        let after = solid(0.3, 0.2, 0.2, width: 600, height: 500)
        let diff = try XCTUnwrap(ImageDifference.render(before: before, after: after, amplify: 1))
        XCTAssertEqual(TestImages.pixel(of: diff, x: 599, y: 499).red, 25.5, accuracy: 1.5)
        let stats = try XCTUnwrap(ImageDifference.stats(before: before, after: after))
        XCTAssertEqual(stats.maxError, 26, accuracy: 1)
    }
}
