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
}
