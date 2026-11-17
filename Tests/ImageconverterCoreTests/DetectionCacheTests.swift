import CoreGraphics
import XCTest
@testable import ImageconverterCore

private struct DetectionFailed: Error {}

/// Bug F2: the preview, the size estimate and the quality ladder asking for the same Redact or focus detection at
/// once share one run, which no single caller's cancellation stops; a failure reaches every waiter and isn't kept.
final class DetectionCacheTests: XCTestCase {
    /// Counts calls. A held detector runs until `release()` (noticing cancellation every 5 ms), so the tests order
    /// events by state instead of by sleeps; an unheld one returns at once.
    final class HeldDetector: VisionDetector, @unchecked Sendable {
        let fails: Bool
        private let held: Bool
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var text = 0
        private var faces = 0
        private var cancelled = 0

        init(held: Bool = true, fails: Bool = false) {
            self.held = held
            self.fails = fails
        }

        var textCalls: Int { lock.withLock { text } }
        var faceCalls: Int { lock.withLock { faces } }
        var sawCancellation: Int { lock.withLock { cancelled } }

        /// Lets every call in progress (and any later one) finish.
        func release() {
            for _ in 0..<16 { gate.signal() }
        }

        private func work() throws {
            while held, gate.wait(timeout: .now() + 0.005) == .timedOut {
                if Task.isCancelled {
                    lock.withLock { cancelled += 1 }
                    throw CancellationError()
                }
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

    private typealias Run = Task<Result<[String], Error>, Never>

    private let image = TestImages.make(width: 120, height: 80)
    private let redact = Pipeline(steps: [PipelineStep(operation: .redact(RedactOptions(target: .text)))])
    private let crop = Pipeline(steps: [PipelineStep(operation: .crop(CropOptions(mode: .aspect(width: 1, height: 1),
                                                                                  focus: .faces)))])

    private func context(_ detector: HeldDetector, _ caches: PreviewCaches) -> FocusContext {
        FocusContext(detector: detector, cache: caches.focus, redactCache: caches.redact, sourceKey: "a.jpg|1|2")
    }

    /// Runs `pipeline` in a detached task (like the estimate and the ladder), giving its notes or its error.
    private func start(_ pipeline: Pipeline, _ context: FocusContext) -> Run {
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

    /// Waits (at most 5 s) until `condition` holds.
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertCancelled(_ run: Run, file: StaticString = #filePath, line: UInt = #line) async {
        guard case .failure(let error) = await run.value else { return XCTFail("finished", file: file, line: line) }
        XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
    }

    private let found = Redaction.note(faces: 0, text: 1)

    func testConcurrentLookupsShareOneDetection() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches()
        // Preview, estimate and ladder, all waiting before the detection ends.
        var runs: [Run] = []
        for count in 1...3 {
            runs.append(start(redact, context(detector, caches)))
            try await until { caches.redact.waiterCount == count }
        }
        detector.release()
        for run in runs {
            let notes = try await run.value.get()
            XCTAssertTrue(notes.contains(found), "\(notes)")
        }
        XCTAssertEqual(detector.textCalls, 1)
        XCTAssertEqual(caches.redact.detectionCount, 1)
        // Kept now: another lookup doesn't detect.
        _ = try await start(redact, context(detector, caches)).value.get()
        XCTAssertEqual(detector.textCalls, 1)
    }

    func testConcurrentFocusLookupsShareOneDetection() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches()
        var runs: [Run] = []
        for count in 1...3 {
            runs.append(start(crop, context(detector, caches)))
            try await until { caches.focus.waiterCount == count }
        }
        detector.release()
        for run in runs { _ = try await run.value.get() }
        XCTAssertEqual(detector.faceCalls, 1)
        XCTAssertEqual(caches.focus.detectionCount, 1)
    }

    func testCancelledFirstCallerDoesNotCancelWaiters() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches()
        let first = start(redact, context(detector, caches))
        try await until { caches.redact.waiterCount == 1 }
        let second = start(redact, context(detector, caches))
        try await until { caches.redact.waiterCount == 2 }
        first.cancel()
        // The cancelled caller stops waiting while the detection still runs, and is cancelled, not unchecked.
        await assertCancelled(first)
        XCTAssertEqual(caches.redact.waiterCount, 1)
        detector.release()
        let notes = try await second.value.get()
        XCTAssertTrue(notes.contains(found), "\(notes)")
        XCTAssertEqual(detector.textCalls, 1, "the waiter got the first detection, not a new one")
        XCTAssertEqual(detector.sawCancellation, 0)
    }

    func testCancelledFocusWaiterLeavesTheDetectionToTheOthers() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches()
        let first = start(crop, context(detector, caches))
        try await until { caches.focus.waiterCount == 1 }
        let second = start(crop, context(detector, caches))
        try await until { caches.focus.waiterCount == 2 }
        first.cancel()
        // The cancelled render returns while the detection is still held (its result is thrown away).
        _ = await first.value
        XCTAssertEqual(caches.focus.waiterCount, 1)
        detector.release()
        let notes = try await second.value.get()
        XCTAssertFalse(notes.contains(where: FocusResolution.notes.contains), "faces found: \(notes)")
        XCTAssertEqual(detector.faceCalls, 1)
        XCTAssertEqual(detector.sawCancellation, 0)
    }

    func testANewLookupWithinTheGraceJoinsAnAbandonedDetection() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches()
        let runs = [start(redact, context(detector, caches)), start(redact, context(detector, caches))]
        try await until { caches.redact.waiterCount == 2 }
        runs.forEach { $0.cancel() }
        for run in runs { await assertCancelled(run) }
        // The next edit's render, 300 ms later, joins the same detection.
        try await Task.sleep(for: .milliseconds(300))
        let next = start(redact, context(detector, caches))
        try await until { caches.redact.waiterCount == 1 }
        detector.release()
        let notes = try await next.value.get()
        XCTAssertTrue(notes.contains(found), "\(notes)")
        XCTAssertEqual(detector.textCalls, 1)
        XCTAssertEqual(detector.sawCancellation, 0)
    }

    func testAnAbandonedDetectionIsCancelledAfterTheGrace() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches(redact: RedactCache(grace: 0.3))
        let runs = [start(redact, context(detector, caches)), start(redact, context(detector, caches))]
        try await until { caches.redact.waiterCount == 2 }
        runs.forEach { $0.cancel() }
        for run in runs { await assertCancelled(run) }
        XCTAssertEqual(detector.sawCancellation, 0, "still running in its grace period")
        try await until { detector.sawCancellation == 1 }
        // Nothing kept: the next lookup detects again.
        let fresh = HeldDetector(held: false)
        _ = try await start(redact, context(fresh, caches)).value.get()
        XCTAssertEqual(fresh.textCalls, 1)
    }

    func testPurgeCancelsDetectionsNobodyWaitsFor() async throws {
        let detector = HeldDetector()
        let caches = PreviewCaches()
        let run = start(redact, context(detector, caches))
        try await until { caches.redact.waiterCount == 1 }
        run.cancel()
        await assertCancelled(run)
        caches.redact.cancelIdleDetections()
        try await until { detector.sawCancellation == 1 }
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
        var context = context(HeldDetector(held: false), caches)
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
        let detector = HeldDetector(fails: true)
        let caches = PreviewCaches()
        var runs: [Run] = []
        for count in 1...3 {
            runs.append(start(redact, context(detector, caches)))
            try await until { caches.redact.waiterCount == count }
        }
        detector.release()
        for run in runs {
            // Every waiter fails closed with the detection's error.
            guard case .failure(let error) = await run.value else { return XCTFail("written unchecked") }
            guard case ConversionError.redactUnchecked = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(detector.textCalls, 1)
        // Not kept: the next lookup asks again.
        _ = await start(redact, context(detector, caches)).value
        XCTAssertEqual(detector.textCalls, 2)
    }
}
