import XCTest
@testable import ImageconverterCore

/// The batch, the size estimate and the quality ladder make the same decode decision, so their bytes agree
/// also when the decode hint applies.
final class DownsampleParityTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func bigItem() throws -> InputItem {
        let url = dir.appendingPathComponent("big.jpg")
        try TestImages.write(TestImages.noise(width: 1600, height: 1200), to: url, type: .jpeg)
        return InputItem(source: url, relativeDirectory: "")
    }

    private func shrinking(quality: Double) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(300))))],
                 output: .init(format: .jpeg, quality: quality))
    }

    private func writtenSize(_ item: InputItem, _ pipeline: Pipeline, folder: String) async throws -> Int {
        let report = await BatchRunner.run([item], pipeline: pipeline,
                                           mode: .newFolder(dir.appendingPathComponent(folder, isDirectory: true)))
        let written = try XCTUnwrap(report.written.first)
        return try XCTUnwrap(try written.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    func testEstimateMatchesWrittenFileWhenDownsampling() async throws {
        let item = try bigItem()
        let pipeline = shrinking(quality: 0.6)
        XCTAssertNotNil(pipeline.decodeHint(sourceWidth: 1600, sourceHeight: 1200), "The hint must apply here")
        let estimate = try SizeEstimator.render(item: item, pipeline: pipeline)
        let size = try await writtenSize(item, pipeline, folder: "out")
        XCTAssertEqual(estimate.bytes, size)
        // The comparison views still get the full-size original.
        XCTAssertEqual(estimate.original?.width, 1600)
        XCTAssertEqual(estimate.encoded?.width, 300)
    }

    func testLadderRungMatchesBatchAtThatQualityWhenDownsampling() async throws {
        let item = try bigItem()
        let rungs = try QualityLadder.render(item: item, pipeline: shrinking(quality: 0.9), qualities: [0.6])
        let rung = try XCTUnwrap(rungs.first)
        let size = try await writtenSize(item, shrinking(quality: 0.6), folder: "ladder")
        XCTAssertEqual(rung.bytes, size)
    }
}
