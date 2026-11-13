import XCTest
@testable import ImageconverterCore

final class PeakPixelsTests: XCTestCase {
    private func pipeline(_ operation: ImageOperation) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: operation)])
    }

    func testDownscaleKeepsSourceAsPeak() {
        let pipe = pipeline(.resize(ResizeOptions(mode: .maxWidth(100), resampling: .bilinear)))
        XCTAssertEqual(pipe.peakPixels(sourceWidth: 4000, sourceHeight: 3000), 12_000_000)
    }

    func testEnlargementCounts() {
        let options = ResizeOptions(mode: .exactSize(width: 8000, height: 8000, fill: .stretch), allowEnlarge: true,
                                    resampling: .bicubic)
        XCTAssertEqual(pipeline(.resize(options)).peakPixels(sourceWidth: 100, sourceHeight: 100), 64_000_000)
    }

    func testLanczosCountsItsCopies() {
        // Source + vImage copy of it + target buffer + its image copy.
        let down = pipeline(.resize(ResizeOptions(mode: .maxWidth(100))))
        XCTAssertEqual(down.peakPixels(sourceWidth: 4000, sourceHeight: 3000), 24_015_000)
        // Fill and crop scales only the kept region: 30 000 x 200 into 1080 x 1080 keeps 200 x 200 of the source.
        let crop = pipeline(.resize(ResizeOptions(mode: .exactSize(width: 1080, height: 1080, fill: .fillAndCrop),
                                                  allowEnlarge: true)))
        XCTAssertEqual(crop.peakPixels(sourceWidth: 30_000, sourceHeight: 200), 6_000_000 + 40_000 + 2 * 1_166_400)
    }

    func testCanvasPaddingCounts() {
        let options = CanvasOptions(mode: .padding(pixels: 100))
        XCTAssertEqual(pipeline(.canvas(options)).peakPixels(sourceWidth: 100, sourceHeight: 100), 90_000)
    }

    func testRotateKeepsPixelCount() {
        let options = RotateFlipOptions(rotation: .cw90)
        XCTAssertEqual(pipeline(.rotateFlip(options)).peakPixels(sourceWidth: 300, sourceHeight: 100), 30_000)
    }

    func testDisabledStepsIgnoredAndHugeSizesSaturate() {
        var pipe = pipeline(.canvas(CanvasOptions(mode: .padding(pixels: 10))))
        pipe.steps[0].isEnabled = false
        XCTAssertEqual(pipe.peakPixels(sourceWidth: 10, sourceHeight: 10), 100)
        XCTAssertGreaterThan(Pipeline().peakPixels(sourceWidth: Int.max, sourceHeight: Int.max), 0)
    }

    func testOutputSizeNeverTraps() {
        for mode in [CanvasMode.padding(pixels: Int.max), .paddingPercent(1e300), .paddingPercent(.infinity)] {
            let size = pipeline(.canvas(CanvasOptions(mode: mode))).outputSize(sourceWidth: 100, sourceHeight: 100)
            XCTAssertGreaterThanOrEqual(size.width, 1)
            XCTAssertGreaterThanOrEqual(size.height, 1)
        }
        let resize = ResizeOptions(mode: .exactWidth(Int.max), allowEnlarge: true)
        let size = pipeline(.resize(resize)).outputSize(sourceWidth: 100, sourceHeight: 100)
        XCTAssertGreaterThanOrEqual(size.width, 1)
    }
}
