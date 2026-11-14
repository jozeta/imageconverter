import XCTest
@testable import ImageconverterCore

final class RenameExampleTests: XCTestCase {
    private func pipeline(_ pattern: String, steps: [PipelineStep] = []) -> Pipeline {
        var pipeline = Pipeline(steps: steps, output: .init(format: .jpeg))
        pipeline.rename = RenameOptions(isEnabled: true, pattern: pattern)
        return pipeline
    }

    func testSampleWithoutSource() {
        XCTAssertEqual(
            RenameExample.render(source: nil, header: nil, created: nil, pipeline: pipeline("{name}")),
            "IMG_0001.jpg")
        XCTAssertEqual(
            RenameExample.render(
                source: nil, header: nil, created: nil, pipeline: pipeline("{date}_{camera}_{counter:000}")),
            "2026-11-13_iPhone 15 Pro_001.jpg")
    }

    func testPipelineSizeFeedsWidthToken() {
        let steps = [PipelineStep(operation: .resize(ResizeOptions(mode: .maxWidth(1000))))]
        XCTAssertEqual(
            RenameExample.render(source: nil, header: nil, created: nil, pipeline: pipeline("{width}", steps: steps)),
            "1000.jpg")
    }

    func testUnreadableHeaderUsesSampleSize() {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        XCTAssertEqual(
            RenameExample.render(source: url, header: nil, created: nil, pipeline: pipeline("{width}x{height}")),
            "4032x3024.jpg")
    }

    /// Final review minor 3: the example names a copy like the batch and the preview (`RenameRendering`).
    func testCopyKeepsTheSourceExtensionLikeTheBatch() {
        let url = URL(fileURLWithPath: "/tmp/Photo.PNG")
        let copy = pipeline("{name}_{format}")
        let example = RenameExample.render(source: url, header: nil, created: nil, pipeline: copy, isCopy: true)
        let base = RenameRendering.baseName(for: InputItem(source: url, relativeDirectory: ""), index: 0,
                                            pipeline: copy, isCopy: true)
        XCTAssertEqual(example, "Photo_PNG.png")
        XCTAssertEqual(example, "\(base ?? "").png")
    }

    func testCounterFollowsTheItemIndex() {
        XCTAssertEqual(
            RenameExample.render(
                source: nil, header: nil, created: nil, pipeline: pipeline("{counter:000}"), index: 4),
            "005.jpg")
    }
}
