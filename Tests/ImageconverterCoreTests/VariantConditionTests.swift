import XCTest
@testable import ImageconverterCore

/// Extra outputs and conditions: skip extras, output overrides, copies.
final class VariantConditionTests: XCTestCase {
    private var root: URL!
    private var out: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, width: Int = 800, height: Int = 400) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.noise(width: width, height: height), to: url, type: .jpeg)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private let thumb = OutputVariant(name: "Thumbnail", settings: OutputSettings(format: .jpeg, quality: 0.6),
                                      resize: .longestEdge(200), nameSuffix: "_thumb")

    private func pipeline(_ variants: [OutputVariant]) -> Pipeline {
        Pipeline(output: OutputSettings(format: .jpeg), extraOutputs: variants)
    }

    // MARK: Conditions

    func testSkipExtraOutputsActionWritesOnlyThePrimary() async throws {
        let wide = try source("wide.jpg", width: 900, height: 100)
        let small = try source("small.jpg", width: 300, height: 100)
        var pipeline = pipeline([thumb])
        pipeline.steps = [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [.longestEdge(.lessThan, 500)], then: [.skipExtraOutputs])))]
        let report = await BatchRunner.run(items([wide, small]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["wide.jpg", "wide_thumb.jpg", "small.jpg"])
        XCTAssertEqual(report.convertedCount, 2)
    }

    func testOutputOverrideReplacesOnlyThePrimary() async throws {
        let photo = try source("a.jpg")
        var pipeline = pipeline([thumb])
        pipeline.steps = [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [.longestEdge(.greaterThan, 1)], then: [.output(OutputSettings(format: .png))])))]
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.png", "a_thumb.jpg"])
    }

    func testACopiedOriginalHasNoExtras() async throws {
        let photo = try source("a.jpg")
        var pipeline = pipeline([thumb])
        pipeline.steps = [PipelineStep(operation: .condition(ConditionalStep(
            conditions: [.longestEdge(.greaterThan, 1)], then: [.copyOriginal])))]
        let report = await BatchRunner.run(items([photo]), pipeline: pipeline, mode: .newFolder(out))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["a.jpg"])
    }

    func testSkipExtraOutputsSummary() {
        XCTAssertEqual(ConditionalAction.skipExtraOutputs.summary, "skip extra outputs")
        XCTAssertTrue(ConditionalAction.skipExtraOutputs.isValid)
    }
}
