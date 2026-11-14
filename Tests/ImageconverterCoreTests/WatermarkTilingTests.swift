import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class WatermarkTilingTests: XCTestCase {
    func testCraftedTinySizeDoesNotTrap() {
        for layout in [WatermarkLayout.single, .tiled(spacing: 0, stagger: true), .tiled(spacing: 400, stagger: false)] {
            let options = WatermarkOptions(content: .image(ImageWatermark(path: "a")), sizePercent: 1e-300,
                                           layout: layout)
            XCTAssertNil(Geometry.watermarkPlacement(imageSize: CGSize(width: 8000, height: 6000),
                                                     contentSize: CGSize(width: 10, height: 10), options: options))
        }
        let tiny = WatermarkOptions(content: .image(ImageWatermark(path: "a")), sizePercent: 1e-300,
                                    layout: .tiled(spacing: 0, stagger: true))
        let base = TestImages.make(width: 40, height: 30)
        XCTAssertTrue(try ImageOps.watermark(base, tiny, asset: TestImages.make(width: 4, height: 4)) === base)
    }

    func testCappedTilesStayEvenlySpread() throws {
        // A panorama with a 1 px mark: far more than `maxTiles` fit, so the step widens until the whole
        // grid fits, and both ends of the image are still covered.
        let image = CGSize(width: 200_000, height: 50)
        let options = WatermarkOptions(content: .image(ImageWatermark(path: "a")), sizePercent: 2,
                                       layout: .tiled(spacing: 0, stagger: false))
        let placement = try XCTUnwrap(Geometry.watermarkPlacement(
            imageSize: image, contentSize: CGSize(width: 10, height: 10), options: options))
        XCTAssertLessThanOrEqual(placement.centers.count, Geometry.maxTiles)
        let columns = placement.centers.map(\.x)
        XCTAssertLessThan(try XCTUnwrap(columns.min()), image.width * 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(columns.max()), image.width * 0.99)
    }
}
