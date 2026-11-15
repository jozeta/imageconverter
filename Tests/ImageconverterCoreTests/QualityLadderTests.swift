import XCTest
@testable import ImageconverterCore

final class QualityLadderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ name: String) throws -> InputItem {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: 120, height: 90), to: url, type: .jpeg)
        return InputItem(source: url, relativeDirectory: "")
    }

    func testLadderSizesIncreaseWithQuality() throws {
        // The configured compression mode is ignored.
        let pipeline = Pipeline(output: .init(format: .jpeg, quality: 0.1, compression: .targetSize(bytes: 500)))
        let rungs = try QualityLadder.render(item: item("a.jpg"), pipeline: pipeline)
        XCTAssertEqual(rungs.map(\.quality), [0.4, 0.6, 0.8, 0.95])
        XCTAssertEqual(rungs.map(\.bytes), rungs.map(\.bytes).sorted())
        XCTAssertLessThan(try XCTUnwrap(rungs.first).bytes, try XCTUnwrap(rungs.last).bytes)
        XCTAssertEqual(rungs[0].image.width, 120)
    }

    func testLadderUnsupportedFormatThrowsOrEmpty() throws {
        let pipeline = Pipeline(output: .init(format: .png))
        let rungs = try QualityLadder.render(item: item("b.jpg"), pipeline: pipeline)
        XCTAssertTrue(rungs.isEmpty)
    }

    func testLadderBytesMatchBatchWithMetadataActive() async throws {
        var pipeline = Pipeline(output: .init(format: .jpeg, quality: 0.8))
        pipeline.metadata.isIncluded = true
        pipeline.metadata.isEnabled = true
        pipeline.metadata.title = "Ladder title"
        XCTAssertTrue(pipeline.metadata.isActive)
        let item = try item("c.jpg")
        // Metadata alone is written losslessly, at no quality: no ladder.
        XCTAssertEqual(try QualityLadder.render(item: item, pipeline: pipeline, qualities: [0.8]).count, 0)
        pipeline.steps = [PipelineStep(operation: .rotateFlip(RotateFlipOptions()))]
        let rungs = try QualityLadder.render(item: item, pipeline: pipeline, qualities: [0.8])
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let report = await BatchRunner.run([item], pipeline: pipeline, mode: .newFolder(out))
        let written = try XCTUnwrap(report.written.first)
        let size = try XCTUnwrap(try written.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(rungs.first?.bytes, size)
    }
}
