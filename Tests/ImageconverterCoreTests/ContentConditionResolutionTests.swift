import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Content conditions in resolution, the batch and the preview, with an injected analyzer.
final class ContentConditionResolutionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func source(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg)
        return url
    }

    private func items(_ urls: [URL]) -> [InputItem] { urls.map { InputItem(source: $0, relativeDirectory: "") } }

    private func pipeline(_ conditional: ConditionalStep) -> Pipeline {
        Pipeline(steps: [PipelineStep(operation: .condition(conditional))], output: OutputSettings(format: .jpeg))
    }

    private func facts(_ analysis: ImageAnalysis) -> ItemFacts {
        var facts = ItemFacts(width: 100, height: 100)
        facts.analysis = analysis
        return facts
    }

    private let dogAndGrass = ImageAnalysis(labels: [ImageLabel("dog", confidence: 0.9),
                                                     ImageLabel("grass", confidence: 0.4),
                                                     ImageLabel("cat", confidence: 0.1)])

    func testFailureNoteAndElseBranch() throws {
        let url = try source("a.jpg")
        let cache = ImageAnalysisCache(analyzer: FakeImageAnalyzer(error: AnalysisError()))
        let step = ConditionalStep(conditions: [Condition(.shows(LabelMatch(["dog"])))], then: [.skip],
                                   otherwise: [.subfolder("Other")])
        let resolved = pipeline(step).resolved(forSource: url, analysis: cache)
        XCTAssertEqual(resolved.disposition, .process)
        XCTAssertEqual(resolved.subfolder, "Other", "a failed analysis never matches")
        XCTAssertEqual(resolved.notes, ["Image analysis unavailable: the Neural Engine is busy"])
    }

    func testLabelsInKeywordsAndTagsAreSeparateEntries() {
        let step = ConditionalStep(conditions: [Condition(.shows(LabelMatch(["dog"])))],
                                   then: [.addKeywords(["{labels}", "ai-{labels}", "Pets"]),
                                          .finderTags(["{labels}", "Red"])])
        let resolved = pipeline(step).resolved(for: facts(dogAndGrass))
        XCTAssertEqual(resolved.pipeline.metadata.keywords, ["dog", "grass", "ai-dog", "ai-grass", "Pets"],
                       "labels at 0.3 or more, each its own keyword; cat (0.1) is left out")
        XCTAssertEqual(resolved.finderTags, ["dog", "grass", "Red"])

        let none = pipeline(ConditionalStep(conditions: [.longestEdge(.greaterThan, 1)],
                                            then: [.addKeywords(["{labels}", "Pets"])]))
            .resolved(for: facts(ImageAnalysis(labels: [])))
        XCTAssertEqual(none.pipeline.metadata.keywords, ["Pets"], "no labels: the entry is dropped")
    }

    func testTokenLabelsLimitAndWords() {
        let many = (0..<15).map { ImageLabel("label_\($0)", confidence: 0.9 - Double($0) * 0.01) }
        let labels = ImageAnalysis(labels: many).tokenLabels
        XCTAssertEqual(labels.count, 10)
        XCTAssertEqual(labels.first, "label 0", "words, not identifiers")
    }

    func testLabelsTokenIsSanitisedInFoldersAndNotes() {
        var context = RenameContext(name: "IMG", ext: "jpg", format: "JPEG", folder: "f", date: nil, make: nil,
                                    model: nil, lens: nil, iso: nil, width: 1, height: 1, counter: 1)
        XCTAssertEqual(RenameTemplate("x_{labels}").render(context), "x_{labels}", "not a file-name token")
        context.labels = ["a/b", "c\u{0}d", "../e"]
        XCTAssertEqual(SubfolderTemplate.folders("{labels}", context: context), ["a-b, cd, ..-e"])
        XCTAssertEqual(SubfolderTemplate.folders("Pets/{labels}/x", context: context).count, 3, "never adds a level")
        XCTAssertEqual(RenameTemplate("Saw {labels}").renderText(context), "Saw a/b, cd, ../e")
        context.labels = []
        XCTAssertEqual(SubfolderTemplate.folders("Pets/{labels}", context: context), ["Pets"])
    }

    func testBatchSubfolderFromLabels() async throws {
        let url = try source("a.jpg")
        let cache = ImageAnalysisCache(analyzer: FakeImageAnalyzer(dogAndGrass))
        let step = ConditionalStep(conditions: [Condition(.shows(LabelMatch(["dog"])))], then: [.subfolder("{labels}")])
        let plan = await BatchRunner.plan(items([url]), pipeline: pipeline(step), mode: .newFolder(out), analysis: cache)
        XCTAssertEqual(plan?.first?.destination?.deletingLastPathComponent().lastPathComponent, "dog, grass")
    }

    func testBatchNotesNewerSystemOnceAndKeepsRunning() async throws {
        let urls = try (0..<3).map { try source("img\($0).jpg") }
        var hooks = BatchHooks()
        hooks.analysis = ImageAnalysisCache(analyzer: FakeImageAnalyzer(ImageAnalysis(needsNewerSystem: true)))
        let step = ConditionalStep(conditions: [Condition(.aesthetics(.atLeast, 0.2))], then: [.skip])
        let report = await BatchRunner.run(items(urls), pipeline: pipeline(step), mode: .newFolder(out), hooks: hooks)
        XCTAssertEqual(report.written.count, 3, "an unsupported check doesn't match: nothing is skipped")
        let noted = report.notes.filter { $0.text.contains(ImageAnalysis.needsNewerSystemNote) }
        XCTAssertEqual(noted.count, 1, "one note per run")
    }

    func testPreviewCacheUsesInjectedAnalysis() async throws {
        let url = try source("a.jpg")
        let analyzer = FakeImageAnalyzer(ImageAnalysis(faceCount: 2))
        let facts = ItemFactsCache(analysis: ImageAnalysisCache(analyzer: analyzer))
        let step = ConditionalStep(conditions: [Condition(.faceCount(.atLeast, 2))], then: [.copyOriginal])
        let preview = await facts.preview(of: 0, in: items([url]), pipeline: pipeline(step))
        XCTAssertEqual(preview?.branches, [.then])
        _ = await facts.preview(of: 0, in: items([url]), pipeline: pipeline(step))
        XCTAssertEqual(analyzer.recorded.count, 1)
    }

    func testPreviewRetriesAFailedAnalysis() async throws {
        let url = try source("a.jpg")
        let analyzer = FakeImageAnalyzer(error: AnalysisError())
        let facts = ItemFactsCache(analysis: ImageAnalysisCache(analyzer: analyzer))
        let step = ConditionalStep(conditions: [Condition(.containsText(true))], then: [.skip])
        let preview = await facts.preview(of: 0, in: items([url]), pipeline: pipeline(step))
        XCTAssertEqual(preview?.branches, [.otherwise])
        XCTAssertEqual(preview?.resolved.notes, ["Image analysis unavailable: the Neural Engine is busy"])
        _ = await facts.preview(of: 0, in: items([url]), pipeline: pipeline(step))
        XCTAssertEqual(analyzer.recorded.count, 2, "a failure isn't kept")
    }
}
