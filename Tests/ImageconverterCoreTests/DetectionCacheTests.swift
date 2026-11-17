import CoreGraphics
import XCTest
@testable import ImageconverterCore

private struct DetectionFailed: Error {}

/// Bug F2: the preview, the size estimate and the quality ladder asking for the same Redact or focus detection at
/// once share one run, which no single caller's cancellation stops; a failure reaches every waiter and isn't kept.
final class DetectionCacheTests: XCTestCase {
    /// Counts calls; each takes `delay`, noticing cancellation in 5 ms slices.
    final class SlowDetector: VisionDetector, @unchecked Sendable {
        let delay: TimeInterval
        let fails: Bool
        private let lock = NSLock()
        private var text = 0
        private var faces = 0
        private var cancelled = 0

        init(delay: TimeInterval = 0.2, fails: Bool = false) {
            self.delay = delay
            self.fails = fails
        }

        var textCalls: Int { lock.withLock { text } }
        var faceCalls: Int { lock.withLock { faces } }
        var sawCancellation: Int { lock.withLock { cancelled } }

        private func work() throws {
            let end = Date().addingTimeInterval(delay)
            while Date() < end {
                if Task.isCancelled {
                    lock.withLock { cancelled += 1 }
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if fails { throw DetectionFailed() }
        }

        func faceRects(in image: CGImage) throws -> [CGRect] {
            lock.withLock { faces += 1 }
            try work()
            return [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)]
        }

        func subjectRects(in image: CGImage) throws -> [CGRect] { [] }

        func textRects(in image: CGImage) throws -> [CGRect] {
            lock.withLock { text += 1 }
            try work()
            return [CGRect(x: 0.2, y: 0.4, width: 0.5, height: 0.1)]
        }
    }

    private let image = TestImages.make(width: 120, height: 80)
    private let redact = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .text)))])
    private let crop = Pipeline(steps: [PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1),
                                                                                  focus: .faces)))])

    private func context(_ detector: SlowDetector, _ caches: PreviewCaches) -> FocusContext {
        FocusContext(detector: detector, cache: caches.focus, redactCache: caches.redact, sourceKey: "a.jpg|1|2")
    }

    /// Runs `pipeline` in a detached task (like the estimate and the ladder), giving its notes or its error.
    private func start(_ pipeline: Pipeline, _ context: FocusContext) -> Task<Result<[String], Error>, Never> {
        let image = image
        return Task.detached {
            var notes: [String] = []
            do {
                _ = try pipeline.apply(to: image, focus: context, notes: &notes)
                return .success(notes)
            } catch {
                return .failure(error)
            }
        }
    }

    func testConcurrentLookupsShareOneDetection() async throws {
        let detector = SlowDetector()
        let caches = PreviewCaches()
        // Preview, estimate and ladder, a moment apart, as in the app.
        var tasks: [Task<Result<[String], Error>, Never>] = []
        for _ in 0..<3 {
            tasks.append(start(redact, context(detector, caches)))
            try await Task.sleep(for: .milliseconds(30))
        }
        for task in tasks {
            let notes = try await task.value.get()
            XCTAssertTrue(notes.contains(Redaction.note(faces: 0, text: 1)), "\(notes)")
        }
        XCTAssertEqual(detector.textCalls, 1)
        XCTAssertEqual(caches.redact.detectionCount, 1)
        // Cached now: another lookup doesn't detect.
        _ = try await start(redact, context(detector, caches)).value.get()
        XCTAssertEqual(detector.textCalls, 1)
    }

    func testConcurrentFocusLookupsShareOneDetection() async throws {
        let detector = SlowDetector()
        let caches = PreviewCaches()
        var tasks: [Task<Result<[String], Error>, Never>] = []
        for _ in 0..<3 {
            tasks.append(start(crop, context(detector, caches)))
            try await Task.sleep(for: .milliseconds(30))
        }
        for task in tasks { _ = try await task.value.get() }
        XCTAssertEqual(detector.faceCalls, 1)
        XCTAssertEqual(caches.focus.detectionCount, 1)
    }

    func testCancelledFirstCallerDoesNotCancelWaiters() async throws {
        let detector = SlowDetector()
        let caches = PreviewCaches()
        let first = start(redact, context(detector, caches))
        try await Task.sleep(for: .milliseconds(40))
        let second = start(redact, context(detector, caches))
        try await Task.sleep(for: .milliseconds(40))
        first.cancel()
        // The cancelled caller stops waiting at once and is cancelled, not unchecked.
        guard case .failure(let error) = await first.value else { return XCTFail("the first caller finished") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        let notes = try await second.value.get()
        XCTAssertTrue(notes.contains(Redaction.note(faces: 0, text: 1)), "\(notes)")
        XCTAssertEqual(detector.textCalls, 1, "the waiter got the first detection, not a new one")
        XCTAssertEqual(detector.sawCancellation, 0)
    }

    func testDetectionIsCancelledWhenEveryWaiterCancelled() async throws {
        let detector = SlowDetector(delay: 1)
        let caches = PreviewCaches()
        let tasks = [start(redact, context(detector, caches)), start(redact, context(detector, caches))]
        try await Task.sleep(for: .milliseconds(60))
        tasks.forEach { $0.cancel() }
        for task in tasks {
            guard case .failure(let error) = await task.value else { return XCTFail("finished") }
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The detection itself stops soon after; nothing is kept, so the next lookup detects again.
        let deadline = Date().addingTimeInterval(2)
        while detector.sawCancellation == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(detector.sawCancellation, 1)
        let fast = SlowDetector(delay: 0)
        _ = try await start(redact, context(fast, caches)).value.get()
        XCTAssertEqual(fast.textCalls, 1)
    }

    func testPreviewIsToldWhileItWaitsForADetection() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [RedactTarget?] = []
            func record(_ target: RedactTarget?) { lock.withLock { seen.append(target) } }
            var events: [RedactTarget?] { lock.withLock { seen } }
        }
        let recorder = Recorder()
        let caches = PreviewCaches()
        var context = context(SlowDetector(delay: 0.05), caches)
        context.redactActivity = { recorder.record($0) }
        _ = try await start(redact, context).value.get()
        XCTAssertEqual(recorder.events, [.text, nil])
        // A kept detection needs no wait, so nothing is shown.
        _ = try await start(redact, context).value.get()
        XCTAssertEqual(recorder.events, [.text, nil])
        XCTAssertEqual(RedactTarget.both.findingStatus, "Finding faces and text…")
        XCTAssertEqual(RedactTarget.faces.findingStatus, "Finding faces…")
        XCTAssertEqual(RedactTarget.text.findingStatus, "Finding text…")
    }

    func testFailureIsNotCachedAndWaitersGetIt() async throws {
        let detector = SlowDetector(fails: true)
        let caches = PreviewCaches()
        var tasks: [Task<Result<[String], Error>, Never>] = []
        for _ in 0..<3 {
            tasks.append(start(redact, context(detector, caches)))
            try await Task.sleep(for: .milliseconds(30))
        }
        for task in tasks {
            // Every waiter fails closed with the detection's error.
            guard case .failure(let error) = await task.value else { return XCTFail("written unchecked") }
            guard case ConversionError.redactUnchecked = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(detector.textCalls, 1)
        // Not kept: the next lookup asks again.
        _ = await start(redact, context(detector, caches)).value
        XCTAssertEqual(detector.textCalls, 2)
    }
}
