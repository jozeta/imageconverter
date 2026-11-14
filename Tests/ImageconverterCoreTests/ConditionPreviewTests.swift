import XCTest
@testable import ImageconverterCore

final class ConditionPreviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, width: Int, height: Int) throws -> InputItem {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: .jpeg)
        return InputItem(source: url, relativeDirectory: "")
    }

    private func pipeline(_ conditional: ConditionalStep, rename: Bool = false) -> Pipeline {
        var pipeline = Pipeline(steps: [PipelineStep(operation: .condition(conditional))])
        if rename { pipeline.rename = RenameOptions(isEnabled: true, isIncluded: true, pattern: "{counter}") }
        return pipeline
    }

    private let skipPortraits = ConditionalStep(conditions: [.orientation(.portrait)], then: [.skip])

    func testSkippedItemsBeforeTheSelectedOneTakeNoCounterNumber() async throws {
        let items = [try source("a.jpg", width: 20, height: 40), try source("b.jpg", width: 40, height: 20),
                     try source("c.jpg", width: 20, height: 40), try source("d.jpg", width: 40, height: 20)]
        let cache = ItemFactsCache()
        let preview = await cache.preview(of: 3, in: items, pipeline: pipeline(skipPortraits))
        XCTAssertEqual(preview?.counterIndex, 1)
        XCTAssertEqual(preview?.branches, [.otherwise])
        XCTAssertEqual(preview?.resolved.disposition, .process)
        let skipped = await cache.preview(of: 2, in: items, pipeline: pipeline(skipPortraits))
        XCTAssertEqual(skipped?.branches, [.then])
        XCTAssertEqual(skipped?.resolved.disposition, .skip)
    }

    func testCounterMatchesTheBatch() async throws {
        let items = [try source("a.jpg", width: 20, height: 40), try source("b.jpg", width: 40, height: 20),
                     try source("c.jpg", width: 20, height: 40), try source("d.jpg", width: 40, height: 20)]
        let pipeline = pipeline(skipPortraits, rename: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let report = await BatchRunner.run(items, pipeline: pipeline, mode: .newFolder(out))
        let preview = await ItemFactsCache().preview(of: 3, in: items, pipeline: pipeline)
        let index = try XCTUnwrap(preview?.counterIndex)
        let expected = RenameRendering.baseName(for: items[3], index: index, pipeline: pipeline)
        XCTAssertEqual(report.written.map { $0.deletingPathExtension().lastPathComponent }.last, expected)
    }

    func testFactsAreReadOncePerFileVersion() async throws {
        let items = [try source("a.jpg", width: 20, height: 40), try source("b.jpg", width: 40, height: 20)]
        let cache = ItemFactsCache()
        _ = await cache.preview(of: 1, in: items, pipeline: pipeline(skipPortraits))
        _ = await cache.preview(of: 1, in: items, pipeline: pipeline(skipPortraits))
        let reads = await cache.readCount
        XCTAssertEqual(reads, 2)
        // A rewritten file is read again.
        try TestImages.write(TestImages.make(width: 50, height: 20), to: items[0].source, type: .jpeg)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: items[0].source.path)
        _ = await cache.preview(of: 1, in: items, pipeline: pipeline(skipPortraits))
        let again = await cache.readCount
        XCTAssertEqual(again, 3)
    }

    func testWithoutSkipActionsTheCounterIsThePosition() async throws {
        let items = [try source("a.jpg", width: 20, height: 40), try source("b.jpg", width: 40, height: 20)]
        let copy = ConditionalStep(conditions: [.orientation(.portrait)], then: [.copyOriginal])
        let cache = ItemFactsCache()
        let preview = await cache.preview(of: 1, in: items, pipeline: pipeline(copy))
        XCTAssertEqual(preview?.counterIndex, 1)
        let reads = await cache.readCount
        XCTAssertEqual(reads, 1, "only the selected item is read")
    }

    func testBranchesSkipDisabledConditions() {
        var pipeline = pipeline(skipPortraits)
        pipeline.steps.append(PipelineStep(isEnabled: false, operation: .condition(skipPortraits)))
        XCTAssertEqual(pipeline.branches(for: ItemFacts(width: 10, height: 20)), [.then])
        XCTAssertTrue(pipeline.canSkipByCondition)
        pipeline.steps[0].isEnabled = false
        XCTAssertFalse(pipeline.canSkipByCondition)
    }

    func testEvictsLeastRecentlyUsed() async throws {
        let urls = try ["a.jpg", "b.jpg", "c.jpg"].map { try source($0, width: 20, height: 10).source }
        let cache = ItemFactsCache(limit: 2)
        _ = await cache.facts(for: urls[0], scanAlpha: false)
        _ = await cache.facts(for: urls[1], scanAlpha: false)
        _ = await cache.facts(for: urls[0], scanAlpha: false) // a is now the most recent
        _ = await cache.facts(for: urls[2], scanAlpha: false) // full: b goes
        var reads = await cache.readCount
        XCTAssertEqual(reads, 3)
        _ = await cache.facts(for: urls[0], scanAlpha: false)
        reads = await cache.readCount
        XCTAssertEqual(reads, 3, "a stayed")
        _ = await cache.facts(for: urls[1], scanAlpha: false)
        reads = await cache.readCount
        XCTAssertEqual(reads, 4, "b was evicted")
    }

    func testRetainDropsRemovedFiles() async throws {
        let urls = try ["a.jpg", "b.jpg"].map { try source($0, width: 20, height: 10).source }
        let cache = ItemFactsCache()
        for url in urls { _ = await cache.facts(for: url, scanAlpha: false) }
        await cache.retain(only: [urls[1]])
        for url in urls { _ = await cache.facts(for: url, scanAlpha: false) }
        let reads = await cache.readCount
        XCTAssertEqual(reads, 3, "only the dropped file is read again")
    }

    func testCancelledPreviewReturnsNil() async throws {
        let items = [try source("a.jpg", width: 20, height: 40), try source("b.jpg", width: 40, height: 20)]
        let cache = ItemFactsCache()
        let pipeline = pipeline(skipPortraits)
        let task = Task { () -> ConditionPreview? in
            // Sleeping throws at once once cancelled, so the preview below runs in a cancelled task.
            try? await Task.sleep(for: .seconds(30))
            return await cache.preview(of: 1, in: items, pipeline: pipeline)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        let reads = await cache.readCount
        XCTAssertEqual(reads, 0, "nothing is read once cancelled")
    }

    func testRunCountsWording() {
        XCTAssertEqual(RunCountsText.make(written: 1, skipped: 0, failed: 0), "Converted 1 image")
        XCTAssertEqual(RunCountsText.make(written: 20, skipped: 0, failed: 0), "Converted 20 images")
        XCTAssertEqual(RunCountsText.make(written: 20, skipped: 3, failed: 1), "Converted 20 · 3 skipped by conditions · 1 failed")
        XCTAssertEqual(RunCountsText.make(written: 5, skipped: 1, failed: 0), "Converted 5 · 1 skipped by a condition")
        XCTAssertEqual(RunCountsText.make(written: 0, skipped: 0, failed: 2), "Converted 0 · 2 failed")
    }

    func testBranchChipWording() {
        XCTAssertEqual(ConditionBranch.chipText([.then]), "Then branch")
        XCTAssertEqual(ConditionBranch.chipText([.otherwise]), "Else branch")
        XCTAssertEqual(ConditionBranch.chipText([.then, .otherwise]), "1 then · 2 else")
    }
}
