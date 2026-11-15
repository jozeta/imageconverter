import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageconverterCore

/// An analyzer with fixed results that answers only what it was asked and records each call.
final class FakeImageAnalyzer: ImageAnalyzer, @unchecked Sendable {
    let result: ImageAnalysis
    let error: Error?
    private let lock = NSLock()
    struct Call: Equatable {
        let needs: FactNeeds
        let width: Int
        let height: Int
    }

    private var calls: [Call] = []

    init(_ result: ImageAnalysis = ImageAnalysis(), error: Error? = nil) {
        self.result = result
        self.error = error
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func analyze(_ image: CGImage, needs: FactNeeds) throws -> ImageAnalysis {
        lock.lock()
        calls.append(Call(needs: needs, width: image.width, height: image.height))
        lock.unlock()
        if let error { throw error }
        var answer = ImageAnalysis()
        if needs.contains(.labels) { answer.labels = result.labels ?? [] }
        if needs.contains(.faces) { answer.faceCount = result.faceCount ?? 0 }
        if needs.contains(.text) { answer.hasText = result.hasText ?? false }
        if needs.contains(.aesthetics) {
            if result.needsNewerSystem {
                answer.needsNewerSystem = true
            } else {
                answer.aestheticsScore = result.aestheticsScore ?? 0
                answer.isUtility = result.isUtility ?? false
            }
        }
        return answer
    }
}

struct AnalysisError: LocalizedError {
    var errorDescription: String? { "the Neural Engine is busy" }
}

final class ContentConditionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestImages.tempDir().resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    private func source(_ name: String, width: Int = 40, height: Int = 20) throws -> URL {
        let url = root.appendingPathComponent(name)
        try TestImages.write(TestImages.make(width: width, height: height), to: url, type: .jpeg)
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

    // MARK: Checks

    func testShowsAnyAllAndConfidence() {
        let found = dogAndGrass
        XCTAssertTrue(Condition(.shows(LabelMatch(["cat", "dog"]))).matches(facts(found)))
        XCTAssertFalse(Condition(.shows(LabelMatch(["cat", "dog"], requiresAll: true))).matches(facts(found)))
        XCTAssertTrue(Condition(.shows(LabelMatch(["grass", "dog"], requiresAll: true))).matches(facts(found)))
        XCTAssertFalse(Condition(.shows(LabelMatch(["cat"]))).matches(facts(found)), "0.1 is below the default 0.3")
        XCTAssertTrue(Condition(.shows(LabelMatch(["cat"], minimumConfidence: 0.05))).matches(facts(found)))
        XCTAssertFalse(Condition(.shows(LabelMatch(["grass"], minimumConfidence: 0.5))).matches(facts(found)))
        XCTAssertTrue(Condition(.shows(LabelMatch(["cat"])), negated: true).matches(facts(found)))
    }

    func testFaceTextAestheticsAndUtility() {
        let found = ImageAnalysis(faceCount: 2, hasText: true, aestheticsScore: 0.25, isUtility: false)
        XCTAssertTrue(Condition(.faceCount(.atLeast, 2)).matches(facts(found)))
        XCTAssertFalse(Condition(.faceCount(.greaterThan, 2)).matches(facts(found)))
        XCTAssertTrue(Condition(.faceCount(.lessThan, 3)).matches(facts(found)))
        XCTAssertTrue(Condition(.containsText(true)).matches(facts(found)))
        XCTAssertFalse(Condition(.containsText(false)).matches(facts(found)))
        XCTAssertTrue(Condition(.aesthetics(.atLeast, 0.2)).matches(facts(found)))
        XCTAssertFalse(Condition(.aesthetics(.greaterThan, 0.25)).matches(facts(found)))
        XCTAssertFalse(Condition(.isUtility).matches(facts(found)))
        XCTAssertTrue(Condition(.isUtility, negated: true).matches(facts(found)))
        XCTAssertTrue(Condition(.faceCount(.atMost, 0)).matches(facts(ImageAnalysis(faceCount: 0))), "nothing found: 0")
    }

    func testMissingAnalysisMatchesNeitherForm() {
        // Failed, not asked for, or needing macOS 15: no value, so neither "is" nor "is not" matches.
        let failed = facts(ImageAnalysis(failure: "Vision failed"))
        let older = facts(ImageAnalysis(labels: [], faceCount: 0, hasText: false, needsNewerSystem: true))
        let checks: [ConditionCheck] = [.shows(LabelMatch(["dog"])), .faceCount(.atLeast, 0), .containsText(false),
                                        .aesthetics(.atLeast, -1), .isUtility]
        for check in checks {
            XCTAssertFalse(Condition(check).matches(failed), "\(check)")
            XCTAssertFalse(Condition(check, negated: true).matches(failed), "\(check)")
        }
        for check in [ConditionCheck.aesthetics(.atLeast, -1), .isUtility] {
            XCTAssertFalse(Condition(check).matches(older))
            XCTAssertFalse(Condition(check, negated: true).matches(older))
        }
        XCTAssertTrue(Condition(.containsText(false)).matches(older), "the macOS 14 checks still work there")
    }

    func testValidityAndNeeds() {
        XCTAssertTrue(ConditionCheck.shows(LabelMatch(["dog", "musical_instrument"])).isValid)
        XCTAssertFalse(ConditionCheck.shows(LabelMatch([])).isValid)
        XCTAssertFalse(ConditionCheck.shows(LabelMatch(["Dog/../x"])).isValid, "only identifier characters")
        XCTAssertFalse(ConditionCheck.shows(LabelMatch(["dog"], minimumConfidence: 0)).isValid)
        XCTAssertFalse(ConditionCheck.shows(LabelMatch(["dog"], minimumConfidence: .nan)).isValid)
        XCTAssertFalse(ConditionCheck.shows(LabelMatch(Array(repeating: "dog", count: 21))).isValid)
        XCTAssertFalse(ConditionCheck.faceCount(.atLeast, -1).isValid)
        XCTAssertFalse(ConditionCheck.aesthetics(.atLeast, 1.5).isValid)
        XCTAssertFalse(ConditionCheck.aesthetics(.atLeast, .infinity).isValid)
        XCTAssertTrue(ConditionCheck.aesthetics(.atMost, -1).isValid)

        XCTAssertEqual(ConditionCheck.shows(LabelMatch(["dog"])).needs, .labels)
        XCTAssertEqual(ConditionCheck.faceCount(.atLeast, 1).needs, .faces)
        XCTAssertEqual(ConditionCheck.containsText(true).needs, .text)
        XCTAssertEqual(ConditionCheck.aesthetics(.atLeast, 0).needs, .aesthetics)
        XCTAssertEqual(ConditionCheck.isUtility.needs, .aesthetics)
        XCTAssertTrue(ConditionCheck.isUtility.needsMacOS15)
        XCTAssertFalse(ConditionCheck.containsText(true).needsMacOS15)
        XCTAssertTrue(FactNeeds.all.isDisjoint(with: .analysis), "the default read never runs Vision")
    }

    func testPipelineNeedsFromChecksAndLabelTemplates() {
        XCTAssertTrue(pipeline(ConditionalStep(conditions: [.longestEdge(.greaterThan, 1)], then: [.skip]))
            .conditionFactNeeds.isDisjoint(with: .analysis), "header conditions never analyse")
        XCTAssertEqual(pipeline(ConditionalStep(conditions: [Condition(.containsText(true))], then: [.skip]))
            .conditionFactNeeds, .text)
        for action in [ConditionalAction.subfolder("{labels}"), .note("saw {labels}"), .finderTags(["{labels}"]),
                       .addKeywords(["ai-{labels}"])] {
            let needs = pipeline(ConditionalStep(conditions: [.longestEdge(.greaterThan, 1)], then: [],
                                                 otherwise: [action])).conditionFactNeeds
            XCTAssertEqual(needs, .labels, "\(action)")
        }
    }

    func testSavedRoundTripAndLenientDecode() throws {
        let checks: [Condition] = [
            Condition(.shows(LabelMatch(["dog", "cat"], requiresAll: true, minimumConfidence: 0.5))),
            Condition(.faceCount(.atLeast, 2)), Condition(.containsText(false), negated: true),
            Condition(.aesthetics(.greaterThan, -0.25)), Condition(.isUtility),
        ]
        let step = ConditionalStep(conditions: checks, then: [.skip])
        let decoded = try JSONDecoder().decode(ConditionalStep.self, from: JSONEncoder().encode(step))
        XCTAssertEqual(decoded, step)

        let json = Data(#"{"conditions": [{"shows": {"_0": {"labels": ["dog"]}}},"#.utf8)
            + Data(#"{"shows": {"_0": {"labels": ["Bad Label!"]}}}], "then": [{"skip": {}}]}"#.utf8)
        let lenient = try JSONDecoder().decode(ConditionalStep.self, from: json)
        XCTAssertEqual(lenient.conditions, [Condition(.shows(LabelMatch(["dog"])))],
                       "missing mode and confidence default; an invalid label drops the condition")
    }

    func testSummaries() {
        XCTAssertEqual(ConditionCheck.shows(LabelMatch(["dog", "cat"])).summary(), "shows dog or cat")
        XCTAssertEqual(ConditionCheck.shows(LabelMatch(["dog", "cat", "musical_instrument"], requiresAll: true)).summary(),
                       "shows dog, cat and musical instrument")
        XCTAssertEqual(ConditionCheck.shows(LabelMatch(["dog"], minimumConfidence: 0.6)).summary(negated: true),
                       "does not show dog (confidence at least 0.6)")
        XCTAssertEqual(ConditionCheck.faceCount(.atLeast, 2).summary(), "has 2 or more faces")
        XCTAssertEqual(ConditionCheck.faceCount(.greaterThan, 1).summary(), "has more than 1 face")
        XCTAssertEqual(ConditionCheck.faceCount(.lessThan, 3).summary(negated: true), "does not have fewer than 3 faces")
        XCTAssertEqual(ConditionCheck.containsText(true).summary(), "contains text")
        XCTAssertEqual(ConditionCheck.containsText(true).summary(negated: true), "contains no text")
        XCTAssertEqual(ConditionCheck.aesthetics(.atLeast, 0.2).summary(), "aesthetics score is at least 0.2")
        XCTAssertEqual(ConditionCheck.isUtility.summary(), "is a screenshot or document")
        XCTAssertEqual(ConditionCheck.isUtility.summary(negated: true), "is not a screenshot or document")
        let step = ConditionalStep(conditions: [Condition(.shows(LabelMatch(["dog", "cat"]))), Condition(.faceCount(.atLeast, 1))],
                                   then: [.skip])
        XCTAssertEqual(step.summary, "if shows dog or cat and has 1 or more faces → skip")
    }

    // MARK: Reading and caching

    func testAnalysisOnlyWhenNeededOnSmallUprightCopy() throws {
        let url = root.appendingPathComponent("big.jpg")
        // EXIF orientation 6: stored 3000 × 1000, upright 1000 × 3000.
        try TestImages.write(TestImages.make(width: 3000, height: 1000), to: url, type: .jpeg,
                             properties: [kCGImagePropertyOrientation as String: 6])
        let analyzer = FakeImageAnalyzer(dogAndGrass)
        let cache = ImageAnalysisCache(analyzer: analyzer)
        XCTAssertEqual(ItemFacts.read(url, needs: .all, analysis: cache)?.analysis, ImageAnalysis())
        XCTAssertEqual(analyzer.recorded, [], "header-only reads never analyse")

        let facts = try XCTUnwrap(ItemFacts.read(url, needs: [.labels, .faces], analysis: cache))
        XCTAssertEqual(facts.analysis.labels?.map(\.identifier), ["dog", "grass", "cat"])
        XCTAssertEqual(facts.analysis.faceCount, 0)
        XCTAssertNil(facts.analysis.hasText, "not asked for")
        let call = try XCTUnwrap(analyzer.recorded.first)
        XCTAssertEqual(call.needs, [.labels, .faces], "one pass for everything needed")
        XCTAssertLessThanOrEqual(max(call.width, call.height), VisionInput.maxLongSide)
        XCTAssertGreaterThan(call.height, call.width, "analysed upright")
    }

    func testCachedPerFileVersionAndMergesNewNeeds() throws {
        let url = try source("a.jpg")
        let analyzer = FakeImageAnalyzer(ImageAnalysis(faceCount: 3, hasText: true))
        let cache = ImageAnalysisCache(analyzer: analyzer)
        _ = cache.analysis(of: url, needs: .faces)
        _ = cache.analysis(of: url, needs: .faces)
        XCTAssertEqual(analyzer.recorded.count, 1, "the same file version is analysed once")
        let both = cache.analysis(of: url, needs: [.faces, .text])
        XCTAssertEqual(both.faceCount, 3)
        XCTAssertEqual(both.hasText, true)
        XCTAssertEqual(analyzer.recorded.map(\.needs), [.faces, .text], "only the missing part runs")

        try TestImages.write(TestImages.make(width: 50, height: 20), to: url, type: .jpeg)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        _ = cache.analysis(of: url, needs: .faces)
        XCTAssertEqual(analyzer.recorded.count, 3, "a changed file is analysed again")
    }

    func testFailureIsReportedAndNotCached() throws {
        let url = try source("a.jpg")
        let analyzer = FakeImageAnalyzer(error: AnalysisError())
        let cache = ImageAnalysisCache(analyzer: analyzer)
        XCTAssertEqual(cache.analysis(of: url, needs: .labels).failure, "the Neural Engine is busy")
        _ = cache.analysis(of: url, needs: .labels)
        XCTAssertEqual(analyzer.recorded.count, 2, "a failure is tried again next time")

        // Beyond the decode limits nothing is decoded or analysed.
        let big = try source("big.jpg", width: 400, height: 400)
        let limited = cache.analysis(of: big, needs: .labels, maxPixels: 1000)
        XCTAssertNotNil(limited.failure)
        XCTAssertEqual(analyzer.recorded.count, 2)
    }

    func testMacOS14SeamNeedsNoVision() {
        let analysis = try? SystemImageAnalyzer(supportsAesthetics: false)
            .analyze(TestImages.make(width: 8, height: 8), needs: .aesthetics)
        XCTAssertEqual(analysis, ImageAnalysis(needsNewerSystem: true))
    }

    // MARK: Real Vision

    func testSystemAnalyzerOnGeneratedImages() throws {
        let analyzer = SystemImageAnalyzer()
        let blank: ImageAnalysis
        do {
            blank = try analyzer.analyze(TestImages.make(width: 640, height: 480,
                                                         color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
                                         needs: [.labels, .faces, .text])
        } catch {
            throw XCTSkip("Vision can't run here (CI virtual machine?): \(error)")
        }
        XCTAssertNil(blank.failure)
        XCTAssertNotNil(blank.labels)
        XCTAssertEqual(blank.faceCount, 0, "nothing detected: zero faces, no crash")
        XCTAssertEqual(blank.hasText, false)

        let text = try analyzer.analyze(Self.textImage("HELLO 2026"), needs: .text)
        try XCTSkipIf(text.hasText != true, "Vision found no text here (CI virtual machine?)")
        XCTAssertEqual(text.hasText, true)
        let rects = try SystemVisionDetector().textRects(in: Self.textImage("HELLO 2026"))
        XCTAssertFalse(rects.isEmpty)
        XCTAssertTrue(rects.allSatisfy { $0.minX >= 0 && $0.maxX <= 1.0001 && $0.minY >= 0 && $0.maxY <= 1.0001 })
    }

    func testKnownLabels() throws {
        let labels = SystemImageAnalyzer.knownLabels
        try XCTSkipIf(labels.isEmpty, "Vision lists no classifier labels here")
        XCTAssertTrue(labels.allSatisfy(ImageLabel.isValidIdentifier))
        XCTAssertEqual(labels, labels.sorted())
        XCTAssertTrue(labels.contains("dog"))
    }

    /// Black text on white, 800 × 200.
    private static func textImage(_ string: String) -> CGImage {
        let ctx = CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes)!)
        ctx.textPosition = CGPoint(x: 30, y: 60)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }
}
