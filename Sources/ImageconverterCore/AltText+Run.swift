import CoreGraphics
import Foundation

extension AltText {
    /// Generates alt text for `image` (any size; a ≤ 1024 px sRGB copy is what the model sees) through the app-wide
    /// `gate`, as the preview does: its request goes ahead of the batches' waiting items but never runs beside another
    /// call. Waiting for the turn has no time limit; `timeout` counts from the turn. Never throws: unavailable, an
    /// error, no answer in time, a model that stopped responding, cancellation or an empty answer give `.failed`. The
    /// timeout holds even when the model ignores cancellation (it is a timer, not a child task).
    public static func generate(for image: CGImage, with generator: any AltTextGenerator,
                                timeout: TimeInterval = AltText.timeout) async -> AltTextOutcome {
        await generate(for: image, with: generator, timeout: timeout, gate: .shared)
    }

    static func generate(for image: CGImage, with generator: any AltTextGenerator, timeout: TimeInterval,
                         gate: AltTextModelGate) async -> AltTextOutcome {
        if let reason = generator.availability.reason { return .failed(reason) }
        guard let small = modelImage(image) else { return .failed(unreadable) }
        switch await gate.turn(priority: true) {
        case .notResponding: return .failed(notResponding)
        case .cancelled: return .failed("cancelled")
        case .yourTurn: break
        }
        let run = AltTextRun()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.call(run, image: small, generator: generator, timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            run.cancel()
        }
    }

    enum Answer: Sendable {
        case text(String)
        case error(Error)
    }

    static func outcome(_ answer: Answer) -> AltTextOutcome {
        switch answer {
        case .text(let raw): return sanitized(raw).map(AltTextOutcome.text) ?? .failed(emptyAnswer)
        case .error(let error): return .failed(describe(error))
        }
    }

    /// A short reason for a model error (the generator's own wording when it gives one).
    static func describe(_ error: Error) -> String {
        if let error = error as? AltTextError { return error.reason }
        if error is CancellationError { return "cancelled" }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let clean = MetadataFields.sanitized(text, limit: 160).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "the model failed" : "the model failed (\(clean))"
    }

    // MARK: From the batch's synchronous workers

    /// The most batch workers, across every batch in the process (manual runs, jobs, services, scripts), that may
    /// work on an item that generates alt text at once: half the cores (`AltTextWorkerLimiter`). Workers waiting for
    /// the model hold their threads; with every thread of the cooperative pool held, anything the model call needs
    /// from the global queues (a sleep, a continuation resumed there) never runs (measured with fakes: a
    /// `Task.sleep` or a continuation resumed on a global queue then hangs, an actor hop doesn't).
    static var batchWorkers: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }

    /// Whether the batch's worker for `job` will ask the model (and so takes an `AltTextWorkerLimiter` slot): it is
    /// processed, generates alt text that something can store, the model is available and hasn't stopped responding.
    static func asksModel(_ job: ResolvedPipeline, generator: any AltTextGenerator,
                          gate: AltTextModelGate = .shared) -> Bool {
        job.disposition == .process && job.pipeline.metadata.generatesAltText
            && job.pipeline.metadata.altTextSkipReason == nil && generator.availability.isAvailable && !gate.isStopped
    }

    /// Workers inside `generateBlocking` right now and the most there were at once (for tests).
    static let waiting = WaitingCounter()

    /// `generate(for:with:timeout:)` for the batch's synchronous worker, through the same app-wide `gate`: it waits
    /// for its turn in order, with no time limit (a cancelled batch stops waiting), and its `timeout` starts when it
    /// gets the turn. A model that stopped responding (`AltTextModelGate`) gives `.failed(notResponding)` at once. The
    /// timer has a queue of its own, so it fires however busy the pool is; the model call's own code runs on
    /// `AltTextExecutor`, not on the cooperative pool the waiting workers hold. Throws `CancellationError` when the
    /// batch is cancelled (before or while waiting).
    static func generateBlocking(for image: CGImage, with generator: any AltTextGenerator,
                                 timeout: TimeInterval = AltText.timeout,
                                 gate: AltTextModelGate = .shared) throws -> AltTextOutcome {
        if let reason = generator.availability.reason { return .failed(reason) }
        waiting.enter()
        defer { waiting.leave() }
        if Task.isCancelled { throw CancellationError() }
        guard let small = modelImage(image) else { return .failed(unreadable) }
        switch gate.waitForTurn() {
        case .notResponding: return .failed(notResponding)
        case .cancelled: throw CancellationError()
        case .yourTurn: break
        }
        if Task.isCancelled {
            gate.pass()
            throw CancellationError()
        }
        let box = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        let run = AltTextRun()
        gate.call(run, image: small, generator: generator, timeout: timeout) { outcome in
            box.set(outcome)
            done.signal()
        }
        // The run's own timer ends the wait; the slices only notice a cancelled batch sooner.
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if Task.isCancelled { run.cancel() }
        }
        if Task.isCancelled { throw CancellationError() }
        return box.value ?? .failed(timedOut)
    }
}

/// How many callers are inside a section, and the most there were at once.
final class WaitingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var most = 0

    func enter() { lock.withLock { now += 1; most = max(most, now) } }
    func leave() { lock.withLock { now -= 1 } }
    var peak: Int { lock.withLock { most } }
    func resetPeak() { lock.withLock { most = now } }
}

/// The process-wide limit on batch workers working on an item that generates alt text (`AltText.batchWorkers`),
/// shared by every batch. The scheduler's worker waits here asynchronously (suspended, holding no thread) before it
/// starts such an item, and releases it when the item is done; items that don't generate never wait here.
public final class AltTextWorkerLimiter: @unchecked Sendable {
    public static let shared = AltTextWorkerLimiter(limit: AltText.batchWorkers)

    private let lock = NSLock()
    private let limit: Int
    private var inUse = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Waits for a slot; false when the task was cancelled while waiting (no slot is then held).
    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else if inUse < limit {
                    inUse += 1
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(returning: false)
        }
    }

    /// Without waiting: true when a slot was free (tests).
    func tryAcquire() -> Bool {
        lock.withLock {
            guard inUse < limit else { return false }
            inUse += 1
            return true
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
            lock.unlock()
        } else {
            // The slot passes straight to the next waiter.
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume(returning: true)
        }
    }
}

/// One generation: the model call on `AltTextExecutor`, a timer for the timeout, and `finish` called exactly once
/// with whichever comes first (the answer, the timeout or a cancel), after which the model call is cancelled.
/// `ended` is called once when the call's task really ends (it may run on after a timeout), or at once when the run
/// was cancelled before it started.
final class AltTextRun: @unchecked Sendable {
    private static let timerQueue = DispatchQueue(label: "imageconverter.alt-text.timeout")
    private let lock = NSLock()
    private var finish: ((AltTextOutcome) -> Void)?
    private var task: Task<Void, Never>?
    private var cancelled = false

    func start(_ image: CGImage, generator: any AltTextGenerator, timeout: TimeInterval,
               finish: @escaping @Sendable (AltTextOutcome) -> Void, ended: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            finish(.failed("cancelled"))
            ended()
            return
        }
        self.finish = finish
        let work: @Sendable () async -> Void = { [self] in
            let answer: AltText.Answer
            do { answer = .text(try await generator.generate(for: image)) } catch { answer = .error(error) }
            complete(AltText.outcome(answer))
            ended()
        }
        if #available(macOS 15, *) {
            task = Task(executorPreference: AltTextExecutor.shared, operation: work)
        } else {
            task = Task.detached(operation: work)
        }
        lock.unlock()
        // A queue of its own: the global queues share the thread budget the blocked workers hold, so a timer there
        // may never fire.
        Self.timerQueue.asyncAfter(deadline: .now() + max(0, timeout)) { [self] in
            complete(.failed(AltText.timedOut))
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        complete(.failed("cancelled"))
    }

    private func complete(_ outcome: AltTextOutcome) {
        lock.lock()
        let finish = self.finish
        self.finish = nil
        let task = self.task
        lock.unlock()
        guard let finish else { return }
        finish(outcome)
        task?.cancel()
    }
}

/// A generator's own failure with a reason in plain English.
public struct AltTextError: Error, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The answer, handed from the generation task to the waiting worker.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: AltTextOutcome?

    func set(_ outcome: AltTextOutcome) { lock.withLock { self.outcome = outcome } }
    var value: AltTextOutcome? { lock.withLock { outcome } }
}

/// Runs the alt text tasks on a dedicated queue instead of the cooperative pool, whose threads the batch's
/// synchronous workers may all be holding while they wait. Concurrent so the call's jobs never wait behind another
/// queue user; `AltTextModelGate` keeps it to one call at a time (each task still runs its own jobs one at a time).
@available(macOS 15, *)
final class AltTextExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = AltTextExecutor()
    private let queue = DispatchQueue(label: "imageconverter.alt-text", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// One item's alt text, generated at most once however many outputs ask (the lossless copy, the re-encode
/// after it, the extra outputs). Used on the item's own worker only.
final class AltTextSlot {
    /// Nil: this run doesn't generate alt text (the size estimate and the quality ladder).
    let generator: (any AltTextGenerator)?
    private var outcome: AltTextOutcome?

    init(generator: (any AltTextGenerator)?) {
        self.generator = generator
    }

    /// The alt text for `metadata`'s item, generating it from `image()` the first time; nil when the options
    /// don't ask for it or this run generates none. `image` is the item as it is after the pipeline's pixel steps.
    func resolve(_ metadata: MetadataOptions, image: () -> CGImage?) throws -> AltTextOutcome? {
        guard metadata.generatesAltText, let generator else { return nil }
        if let outcome { return outcome }
        let made: AltTextOutcome
        if let reason = metadata.altTextSkipReason {
            made = .failed(reason)
        } else if let reason = generator.availability.reason {
            made = .failed(reason)
        } else if let image = image() {
            made = try AltText.generateBlocking(for: image, with: generator)
        } else {
            made = .failed(AltText.unreadable)
        }
        outcome = made
        return made
    }
}
