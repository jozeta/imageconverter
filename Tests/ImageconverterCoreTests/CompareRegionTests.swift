import CoreGraphics
import XCTest
@testable import ImageconverterCore

final class CompareRegionTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Visible region

    func testVisibleRegionAtFitIsTheWholeImage() {
        let region = ZoomMath.visibleRegion(.fit, imagePixels: CGSize(width: 400, height: 300),
                                            view: CGSize(width: 200, height: 150))
        XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testVisibleRegionWhenZoomed() {
        let state = ZoomState(scale: 2, center: CGPoint(x: 0.5, y: 0.5))
        let region = ZoomMath.visibleRegion(state, imagePixels: CGSize(width: 400, height: 300),
                                            view: CGSize(width: 200, height: 150))
        XCTAssertEqual(region.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(region.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(region.height, 0.5, accuracy: 1e-9)
    }

    func testVisibleRegionKeepsAnAxisThatFits() {
        // A tall image in a wide view at 1.5×: the whole height is no longer visible, the width still is.
        let state = ZoomState(scale: 1.5, center: CGPoint(x: 0.5, y: 0.9))
        let region = ZoomMath.visibleRegion(state, imagePixels: CGSize(width: 100, height: 400),
                                            view: CGSize(width: 400, height: 200))
        XCTAssertEqual(region.minX, 0)
        XCTAssertEqual(region.width, 1)
        XCTAssertEqual(region.height, 1 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(region.maxY, 1, accuracy: 1e-9)
    }

    // MARK: Region crops

    func testCropKeepsTheRegionAndBoundsTheSize() throws {
        let image = TestImages.noise(width: 400, height: 200)
        let half = try XCTUnwrap(RegionCrop.draw(image, region: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), maxSide: 1000))
        XCTAssertEqual([half.width, half.height], [200, 200])
        let small = try XCTUnwrap(RegionCrop.draw(image, region: CGRect(x: 0, y: 0, width: 1, height: 1), maxSide: 100))
        XCTAssertEqual([small.width, small.height], [100, 50])
        // A pixel of the crop is the source pixel at the region's offset (1:1, no scaling).
        let source = TestImages.pixel(of: image, x: 210, y: 37)
        let cropped = TestImages.pixel(of: half, x: 10, y: 37)
        XCTAssertEqual([source.red, source.green, source.blue], [cropped.red, cropped.green, cropped.blue])
    }

    // MARK: Difference on a region

    func testCompareSizeMismatchThrows() {
        let before = TestImages.noise(width: 20, height: 10)
        let after = TestImages.noise(width: 21, height: 10)
        XCTAssertThrowsError(try ImageDifference.compare(before: before, after: after)) { error in
            XCTAssertEqual(error as? ImageDifference.CompareError, .sizeMismatch)
        }
    }

    func testCompareOnARegionIsBounded() throws {
        let image = TestImages.noise(width: 300, height: 200)
        let result = try ImageDifference.compare(before: image, after: image,
                                                 region: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), maxSide: 100)
        XCTAssertEqual([result.image.width, result.image.height], [100, 67])
        XCTAssertEqual(result.stats.psnr, .infinity)
    }

    func testCompareStopsWhenCancelled() async {
        let image = TestImages.noise(width: 64, height: 64)
        let task = Task.detached { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ImageDifference.compare(before: image, after: image)
                return nil
            } catch { return error }
        }
        let error = await task.value
        XCTAssertTrue(error is CancellationError)
    }

    // MARK: Quality ladder crops

    private func item(width: Int, height: Int) throws -> InputItem {
        let url = dir.appendingPathComponent("l.jpg")
        try TestImages.write(TestImages.noise(width: width, height: height), to: url, type: .jpeg)
        return InputItem(source: url, relativeDirectory: "")
    }

    func testLadderKeepsOnlyTheRegionCrop() throws {
        let pipeline = Pipeline(output: .init(format: .jpeg))
        let rungs = try QualityLadder.render(item: item(width: 400, height: 300), pipeline: pipeline, qualities: [0.5],
                                             region: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), maxSide: 100)
        let rung = try XCTUnwrap(rungs.first)
        XCTAssertEqual([rung.image.width, rung.image.height], [100, 75])
        XCTAssertEqual(rung.bytes, rung.data.count)
        // The kept bytes can be cropped again for another region without a new encode.
        let again = try XCTUnwrap(QualityLadder.crop(rung.data, region: CGRect(x: 0, y: 0, width: 1, height: 1), maxSide: 40))
        XCTAssertEqual([again.width, again.height], [40, 30])
    }

    func testLadderRefusesVeryLargeImages() throws {
        let pipeline = Pipeline(output: .init(format: .jpeg))
        XCTAssertThrowsError(try QualityLadder.render(item: item(width: 100, height: 100), pipeline: pipeline,
                                                      maxComparePixels: 5000)) { error in
            XCTAssertEqual(error as? QualityLadder.LadderError, .tooLarge)
        }
    }
}
