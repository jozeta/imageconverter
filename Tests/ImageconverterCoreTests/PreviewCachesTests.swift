import CoreGraphics
import Foundation
import XCTest
@testable import ImageconverterCore

/// The preview, the size estimate and the quality ladder share one set of caches (`PreviewCaches`): an edit after
/// Smart crop, Redact or ML enlarge doesn't run Vision or the model again, and ML enlarge runs one at a time.
/// Fake detector and fake model only.
final class PreviewCachesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestImages.tempDir().resolvingSymlinksInPath() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func source() throws -> InputItem {
        let url = root.appendingPathComponent("a.jpg")
        try TestImages.write(TestImages.noise(width: 120, height: 80), to: url, type: .jpeg)
        return InputItem(source: url, relativeDirectory: "")
    }

    /// Crop (subject) → Redact (faces) → ML enlarge 2× → JPEG at `quality`.
    private func pipeline(quality: Double) -> Pipeline {
        var output = OutputSettings(format: .jpeg)
        output.quality = quality
        return Pipeline(steps: [
            PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1), focus: .subject))),
            PipelineStep(operation: .redact(RedactOptions(target: .faces))),
            PipelineStep(operation: .resize(ResizeOptions(mode: .mlEnlarge(factor: 2)))),
        ], output: output)
    }

    private func detector() -> FakeVisionDetector {
        FakeVisionDetector(faces: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)],
                           subject: [CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2)])
    }

    func testEstimateEditsAfterTheStepsReuseDetectionsAndTheEnlargedImage() throws {
        let item = try source()
        let caches = PreviewCaches()
        let vision = detector()
        let model = FakeScaler()
        let first = try SizeEstimator.render(item: item, pipeline: pipeline(quality: 0.9), enlarger: model,
                                             caches: caches, detector: vision)
        let (detections, sessions) = (vision.recorded.count, model.sessions)
        XCTAssertGreaterThan(detections, 0)
        XCTAssertGreaterThan(sessions, 0)
        let second = try SizeEstimator.render(item: item, pipeline: pipeline(quality: 0.5), enlarger: model,
                                              caches: caches, detector: vision)
        XCTAssertEqual(vision.recorded.count, detections, "no new Vision run for an output-quality edit")
        XCTAssertEqual(model.sessions, sessions, "no new ML enlarge for an output-quality edit")
        XCTAssertEqual(caches.enlarge.runCount, 1)
        XCTAssertNotEqual(first.bytes, second.bytes)
    }

    func testLadderAndEstimateShareThePreviewsCaches() async throws {
        let item = try source()
        let vision = detector()
        let model = FakeScaler()
        let renderer = PreviewRenderer(detector: vision, enlarger: model)
        guard case .ready = await renderer.render(item: item, index: 0, pipeline: pipeline(quality: 0.9)) else {
            return XCTFail("preview")
        }
        let (detections, sessions) = (vision.recorded.count, model.sessions)
        _ = try SizeEstimator.render(item: item, pipeline: pipeline(quality: 0.7), enlarger: model,
                                     caches: renderer.caches, detector: vision)
        _ = try QualityLadder.render(item: item, pipeline: pipeline(quality: 0.7), enlarger: model,
                                     caches: renderer.caches, detector: vision)
        XCTAssertEqual(vision.recorded.count, detections)
        XCTAssertEqual(model.sessions, sessions)
        XCTAssertEqual(renderer.caches.enlarge.runCount, 1)
        // Purged when a batch starts: the next render enlarges again.
        await renderer.purge()
        _ = await renderer.render(item: item, index: 0, pipeline: pipeline(quality: 0.9))
        XCTAssertEqual(renderer.caches.enlarge.runCount, 2)
    }

    /// The batch has no caches: it always runs the model itself (counted by its memory scheduler).
    func testBatchDoesNotUseTheCache() throws {
        let image = TestImages.make(width: 40, height: 30)
        let model = FakeScaler()
        let resize = Pipeline(steps: [PipelineStep(operation: .resize(ResizeOptions(mode: .mlEnlarge(factor: 2))))])
        for _ in 0..<2 { _ = try resize.apply(to: image, focus: FocusContext(enlarger: model)) }
        XCTAssertEqual(model.sessions, 2)
    }

    /// The estimate and the ladder asking for the same input at once: one enlarge, never two at a time.
    func testConcurrentMissesShareOneEnlargeOneAtATime() async throws {
        let item = try source()
        let caches = PreviewCaches()
        let model = SlowScaler()
        let other = PreviewCaches()
        let pipe = pipeline(quality: 0.8)
        async let estimate = Task.detached {
            try SizeEstimator.render(item: item, pipeline: pipe, enlarger: model, caches: caches, detector: FakeVisionDetector())
        }.value
        async let ladder = Task.detached {
            try QualityLadder.render(item: item, pipeline: pipe, enlarger: model, caches: caches, detector: FakeVisionDetector())
        }.value
        // A different cache (another consumer) still waits its turn app-wide.
        async let third = Task.detached {
            try SizeEstimator.render(item: item, pipeline: pipe, enlarger: model, caches: other, detector: FakeVisionDetector())
        }.value
        _ = try await (estimate, ladder, third)
        XCTAssertEqual(caches.enlarge.runCount, 1, "the second miss waited and reused the first result")
        XCTAssertEqual(other.enlarge.runCount, 1)
        XCTAssertEqual(model.active.peak, 1, "one ML enlarge at a time app-wide")
    }

    func testOnlyTwoResultsAndNothingHugeIsKept() throws {
        let cache = EnlargeCache()
        func key(_ step: Int) -> EnlargeCache.Key {
            EnlargeCache.Key(source: "s", step: step, before: Data(), width: 1, height: 1, factor: 2)
        }
        let small = EnlargeCache.Entry(image: TestImages.make(width: 4, height: 4), notes: [])
        for step in 0..<3 { _ = try cache.result(for: key(step)) { small } }
        XCTAssertEqual(cache.runCount, 3)
        _ = try cache.result(for: key(2)) { small }
        _ = try cache.result(for: key(1)) { small }
        XCTAssertEqual(cache.runCount, 3, "the last two are kept")
        _ = try cache.result(for: key(0)) { small }
        XCTAssertEqual(cache.runCount, 4, "the oldest went")
        XCTAssertEqual(EnlargeCache.maxEntries, 2)
        XCTAssertEqual(EnlargeCache.maxPixels, 200_000_000)
    }
}

/// `FakeScaler`, but each session takes 0.2 s to make and counts how many are being made at once.
private final class SlowScaler: SuperResolutionScaler, @unchecked Sendable {
    let inner = FakeScaler()
    let active = ActiveCounter()
    var factor: Int { inner.factor }
    func availability() -> MLEnlargeAvailability { inner.availability() }
    func makeSession(width: Int, height: Int, colorSpace: CGColorSpace) throws -> any SuperResolutionSession {
        active.enter()
        defer { active.leave() }
        Thread.sleep(forTimeInterval: 0.2)
        return try inner.makeSession(width: width, height: height, colorSpace: colorSpace)
    }
}
