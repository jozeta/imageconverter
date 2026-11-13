import XCTest
@testable import ImageconverterCore

final class SizeEstimatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ name: String = "a.jpg") throws -> InputItem {
        let url = dir.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: 200, height: 150), to: url, type: .jpeg)
        return InputItem(source: url, relativeDirectory: "")
    }

    func testEstimateMatchesWrittenFile() async throws {
        let item = try item()
        let pipeline = Pipeline(output: .init(format: .jpeg, quality: 0.6))
        let estimate = try SizeEstimator.render(item: item, pipeline: pipeline)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let report = await BatchRunner.run([item], pipeline: pipeline, mode: .newFolder(out))
        let written = try XCTUnwrap(report.written.first)
        let size = try XCTUnwrap(try written.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(estimate.bytes, size)
        XCTAssertEqual(estimate.original.width, 200)
        XCTAssertEqual(estimate.encoded.width, 200)
    }

    func testEstimateChangesWithQuality() throws {
        let item = try item()
        let low = try SizeEstimator.render(item: item, pipeline: Pipeline(output: .init(format: .jpeg, quality: 0.3)))
        let high = try SizeEstimator.render(item: item, pipeline: Pipeline(output: .init(format: .jpeg, quality: 0.95)))
        XCTAssertLessThan(low.bytes, high.bytes)
    }

    func testEstimateThrowsForUnreadable() throws {
        let url = dir.appendingPathComponent("bad.jpg")
        try Data("nope".utf8).write(to: url)
        XCTAssertThrowsError(try SizeEstimator.render(item: InputItem(source: url, relativeDirectory: ""),
                                                      pipeline: Pipeline()))
    }
}
