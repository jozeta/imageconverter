import CoreGraphics
import Foundation

extension AltText {
    /// Generates alt text for `image` (any size; a ≤ 1024 px sRGB copy is what the model sees), waiting at most
    /// `timeout`. Never throws: unavailable, an error, no answer in time, cancellation or an empty answer give
    /// `.failed`. The timeout holds even when the model ignores cancellation (it is a timer, not a child task).
    public static func generate(for image: CGImage, with generator: any AltTextGenerator,
                                timeout: TimeInterval = AltText.timeout) async -> AltTextOutcome {
        if let reason = generator.availability.reason { return .failed(reason) }
        guard let small = modelImage(image) else { return .failed(unreadable) }
        let run = AltTextRun()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.start(small, generator: generator, timeout: timeout) { continuation.resume(returning: $0) }
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

    /// The most workers a batch that generates alt text runs at once: half the cores (see `BatchRunner.run`).
    /// Workers waiting for the model hold their threads; with every thread of the cooperative pool held, anything
    /// the model call needs from the global queues (a sleep, a continuation resumed there) never runs (measured with
    /// fakes: a `Task.sleep` or a continuation resumed on a global queue then hangs, an actor hop doesn't).
    static var batchWorkers: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }

    /// One generation at a time from the batch: the model answers one request after another anyway, and the
    /// timeout should time the model, not the queue.
    private static let batchGate = NSLock()

    /// `generate(for:with:timeout:)` for the batch's synchronous worker: waits for its turn, then at most
    /// `timeout` for the answer (the timer has a queue of its own, so it fires however busy the pool is). The model
    /// call's own code runs on `AltTextExecutor`, not on the cooperative pool the waiting workers hold; the batch
    /// also runs at most `batchWorkers` at once. Throws `CancellationError` when the batch is cancelled (before or
    /// while waiting).
    static func generateBlocking(for image: CGImage, with generator: any AltTextGenerator,
                                 timeout: TimeInterval = AltText.timeout) throws -> AltTextOutcome {
        if let reason = generator.availability.reason { return .failed(reason) }
        batchGate.lock()
        defer { batchGate.unlock() }
        if Task.isCancelled { throw CancellationError() }
        guard let small = modelImage(image) else { return .failed(unreadable) }
        let box = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        let run = AltTextRun()
        run.start(small, generator: generator, timeout: timeout) { outcome in
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

/// One generation: the model call on `AltTextExecutor`, a timer for the timeout, and `finish` called exactly once
/// with whichever comes first (the answer, the timeout or a cancel), after which the model call is cancelled.
final class AltTextRun: @unchecked Sendable {
    private static let timerQueue = DispatchQueue(label: "imageconverter.alt-text.timeout")
    private let lock = NSLock()
    private var finish: ((AltTextOutcome) -> Void)?
    private var task: Task<Void, Never>?
    private var cancelled = false

    func start(_ image: CGImage, generator: any AltTextGenerator, timeout: TimeInterval,
               finish: @escaping @Sendable (AltTextOutcome) -> Void) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            finish(.failed("cancelled"))
            return
        }
        self.finish = finish
        let work: @Sendable () async -> Void = { [self] in
            let answer: AltText.Answer
            do { answer = .text(try await generator.generate(for: image)) } catch { answer = .error(error) }
            complete(AltText.outcome(answer))
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

/// Runs the batch's alt text tasks on one dedicated serial queue instead of the cooperative pool, whose threads
/// the batch's synchronous workers may all be holding while they wait.
@available(macOS 15, *)
final class AltTextExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = AltTextExecutor()
    private let queue = DispatchQueue(label: "imageconverter.alt-text", qos: .userInitiated)

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
        if metadata.removeXMP && !metadata.altTextAsDescription {
            made = .failed(AltText.removeXMPReason)
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
