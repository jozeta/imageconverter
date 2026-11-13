import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

final class PipelineApplyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resize(_ width: Int) -> ImageOperation {
        .resize(ResizeOptions(mode: .maxWidth(width)))
    }

    private var square: ImageOperation { .crop(CropOptions(mode: .aspect(width: 1, height: 1))) }

    func testDisabledStepsAreSkipped() throws {
        let pipeline = Pipeline(steps: [PipelineStep(isEnabled: false, operation: resize(100))])
        let result = try pipeline.apply(to: TestImages.make(width: 400, height: 200))
        XCTAssertEqual(result.width, 400)
        XCTAssertEqual(result.height, 200)
    }

    func testOrderMatters() throws {
        let image = TestImages.make(width: 400, height: 200)
        let cropFirst = Pipeline(steps: [PipelineStep(operation: square), PipelineStep(operation: resize(100))])
        let cropped = try cropFirst.apply(to: image)
        XCTAssertEqual([cropped.width, cropped.height], [100, 100])
        let resizeFirst = Pipeline(steps: [PipelineStep(operation: resize(100)), PipelineStep(operation: square)])
        let resized = try resizeFirst.apply(to: image)
        XCTAssertEqual([resized.width, resized.height], [50, 50])
    }

    private func outputSize(of url: URL) throws -> (Int, Int) {
        let data = try Data(contentsOf: url)
        let props = try TestImages.properties(of: data)
        return (props[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                props[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
    }

    func testBatchAppliesPipeline() async throws {
        var files: [URL] = []
        for index in 1...3 {
            let url = root.appendingPathComponent("in\(index).png")
            try TestImages.write(TestImages.make(width: 800, height: 600), to: url, type: .png)
            files.append(url)
        }
        let out = root.appendingPathComponent("out", isDirectory: true)
        let pipeline = Pipeline(steps: [PipelineStep(operation: resize(400))], output: .init(format: .jpeg))
        let report = await BatchRunner.run(InputCollector.collect(files), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.count, 3)
        for url in report.written {
            let size = try outputSize(of: url)
            XCTAssertEqual([size.0, size.1], [400, 300])
        }
    }

    func testPortraitOrientationResizesUprightImage() async throws {
        let url = root.appendingPathComponent("portrait.jpg")
        try TestImages.write(TestImages.make(width: 400, height: 200), to: url, type: .jpeg,
                             properties: [kCGImagePropertyOrientation as String: 6])
        let out = root.appendingPathComponent("out", isDirectory: true)
        let pipeline = Pipeline(steps: [PipelineStep(operation: resize(100))], output: .init(format: .jpeg))
        let report = await BatchRunner.run(InputCollector.collect([url]), pipeline: pipeline, mode: .newFolder(out))
        let written = try XCTUnwrap(report.written.first)
        let size = try outputSize(of: written)
        XCTAssertEqual([size.0, size.1], [100, 200])
    }
}
