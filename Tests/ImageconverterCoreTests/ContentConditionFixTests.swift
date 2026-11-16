import CoreGraphics
import XCTest
@testable import ImageconverterCore

/// Content conditions, final fixes: the macOS 15 note only when needed, a Shows check without labels, `{labels}`
/// keywords with no labels, and the analysis cache under concurrent reads. Fake analyzers only.
final class ContentConditionFixTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func pipeline(_ conditional: ConditionalStep, enabled: Bool = true) -> Pipeline {
        var step = PipelineStep(operation: .condition(conditional))
        step.isEnabled = enabled
        return Pipeline(steps: [step], output: OutputSettings(format: .jpeg))
    }

    private func facts(_ analysis: ImageAnalysis) -> ItemFacts {
        var facts = ItemFacts(width: 100, height: 100)
        facts.analysis = analysis
        return facts
    }

    /// A cached analysis from an earlier aesthetics check says "needs macOS 15"; a pipeline that now only asks
    /// "Shows dog" mustn't repeat that note.
    func testNewerSystemNoteOnlyWhenTheChecksNeedIt() {
        let older = facts(ImageAnalysis(labels: [ImageLabel("dog", confidence: 0.9)], needsNewerSystem: true))
        let shows = pipeline(ConditionalStep(conditions: [Condition(.shows(LabelMatch(["dog"])))], then: [.skip]))
        XCTAssertFalse(shows.resolved(for: older).notes.contains(ImageAnalysis.needsNewerSystemNote))
        let utility = pipeline(ConditionalStep(conditions: [Condition(.isUtility)], then: [.skip]))
        XCTAssertEqual(utility.resolved(for: older).notes, [ImageAnalysis.needsNewerSystemNote])
    }

    /// A Shows check with no labels is kept when loading (not silently dropped), never matches in either form,
    /// and blocks Run until labels are chosen.
    func testShowsWithoutLabelsIsKeptNeverMatchesAndBlocksRun() throws {
        let json = Data(#"{"conditions": [{"shows": {"_0": {"labels": []}}}], "then": [{"skip": {}}]}"#.utf8)
        let step = try JSONDecoder().decode(ConditionalStep.self, from: json)
        XCTAssertEqual(step.conditions, [Condition(.shows(LabelMatch([])))])
        let seen = facts(ImageAnalysis(labels: [ImageLabel("dog", confidence: 0.9)]))
        XCTAssertFalse(Condition(.shows(LabelMatch([]))).matches(seen))
        XCTAssertFalse(Condition(.shows(LabelMatch([])), negated: true).matches(seen), "not “does not show nothing”")
        XCTAssertEqual(pipeline(step).conditionRunBlocker, Pipeline.emptyLabelsBlocker)
        XCTAssertNil(pipeline(step, enabled: false).conditionRunBlocker, "a disabled step doesn't block")
        XCTAssertNil(pipeline(ConditionalStep(conditions: [Condition(.shows(LabelMatch(["dog"])))], then: [.skip]))
            .conditionRunBlocker)
        XCTAssertFalse(ConditionCheck.shows(LabelMatch(Array(repeating: "dog", count: 21))).isValid)
        XCTAssertFalse(ConditionCheck.shows(LabelMatch(["Bad Label!"])).isValid)
    }

    /// "Add keywords {labels}" on an image with no labels adds nothing, so it doesn't switch the Metadata step on.
    func testLabelsKeywordsWithNoLabelsLeaveTheMetadataStepOff() {
        let step = ConditionalStep(conditions: [.longestEdge(.greaterThan, 1)], then: [.addKeywords(["{labels}"])])
        let none = pipeline(step).resolved(for: facts(ImageAnalysis(labels: [])))
        XCTAssertFalse(none.pipeline.metadata.isActive)
        XCTAssertNil(none.pipeline.metadata.keywords)
        let some = pipeline(step).resolved(for: facts(ImageAnalysis(labels: [ImageLabel("dog", confidence: 0.9)])))
        XCTAssertTrue(some.pipeline.metadata.isActive)
        XCTAssertEqual(some.pipeline.metadata.keywords, ["dog"])
    }

    /// Four reads of one file at once run one analysis; six files at once never have more than two analyses
    /// running (app-wide, across caches).
    func testConcurrentMissesShareOneAnalysisAndAtMostTwoRunAtOnce() throws {
        let urls = try (0..<6).map { index -> URL in
            let url = root.appendingPathComponent("f\(index).jpg")
            try TestImages.write(TestImages.make(width: 40, height: 20), to: url, type: .jpeg)
            return url
        }
        let slow = SlowAnalyzer()
        let cache = ImageAnalysisCache(analyzer: slow)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in _ = cache.analysis(of: urls[0], needs: .labels) }
        XCTAssertEqual(cache.analysisCount, 1)
        XCTAssertEqual(slow.calls, 1)

        let other = ImageAnalysisCache(analyzer: slow)
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            _ = (index.isMultiple(of: 2) ? cache : other).analysis(of: urls[index], needs: .faces)
        }
        XCTAssertLessThanOrEqual(slow.active.peak, ImageAnalysisCache.maxConcurrentAnalyses)
        XCTAssertEqual(ImageAnalysisCache.maxConcurrentAnalyses, 2)
        // The first file's labels and faces were merged into one entry.
        XCTAssertNotNil(cache.analysis(of: urls[0], needs: [.labels, .faces]).labels)
        XCTAssertEqual(slow.calls, 7)
    }
}

/// Takes 0.15 s per analysis and counts how many run at once.
private final class SlowAnalyzer: ImageAnalyzer, @unchecked Sendable {
    let active = ActiveCounter()
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func analyze(_ image: CGImage, needs: FactNeeds) throws -> ImageAnalysis {
        lock.withLock { count += 1 }
        active.enter()
        defer { active.leave() }
        Thread.sleep(forTimeInterval: 0.15)
        var answer = ImageAnalysis()
        if needs.contains(.labels) { answer.labels = [ImageLabel("dog", confidence: 0.9)] }
        if needs.contains(.faces) { answer.faceCount = 0 }
        return answer
    }
}
