import Foundation

/// How far a batch has got. `completed` counts successes and failures.
public struct BatchProgress: Equatable, Sendable {
    public let completed: Int
    public let failed: Int
    public let total: Int

    public init(completed: Int, failed: Int, total: Int) {
        self.completed = completed
        self.failed = failed
        self.total = total
    }
}

/// A file that was skipped, and why.
public struct BatchFailure: Equatable, Sendable {
    public let source: URL
    public let reason: String

    public init(source: URL, reason: String) {
        self.source = source
        self.reason = reason
    }
}

/// The outcome of a batch: both lists are in input order.
public struct BatchReport: Equatable, Sendable {
    public var written: [URL]
    public var failures: [BatchFailure]
    public var cancelled: Bool

    public init(written: [URL] = [], failures: [BatchFailure] = [], cancelled: Bool = false) {
        self.written = written
        self.failures = failures
        self.cancelled = cancelled
    }
}

public enum BatchRunner {
    /// Converts `items` in parallel (at most `concurrency` at a time). A file that fails is
    /// recorded and skipped; the rest carry on. `progress` is called once per finished item, in
    /// completion order (not input order), from the collecting side of the batch; `completed`
    /// (successes plus failures) increases monotonically. `BatchReport.cancelled` is false if
    /// cancellation arrives after the last item was scheduled. Cancelling the calling task stops new files
    /// from starting; files already in flight finish their atomic commit, so no temp files remain.
    public static func run(
        _ items: [InputItem],
        output: OutputSettings,
        mode: OutputMode,
        maxPixels: Int = 250_000_000,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        trash: @escaping Trasher = systemTrash,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async -> BatchReport {
        let plans = OutputPlanner.plan(items, format: output.format, mode: mode)
        let total = plans.count
        let limit = max(1, concurrency)
        var outcomes = [Result<URL, ConversionError>?](repeating: nil, count: total)
        var cancelled = false

        await withTaskGroup(of: (Int, Result<URL, ConversionError>).self) { group in
            var next = 0
            var inFlight = 0
            var completed = 0
            var failed = 0

            while true {
                while inFlight < limit, next < total {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    let index = next
                    let plan = plans[index]
                    next += 1
                    inFlight += 1
                    group.addTask {
                        (index, convert(plan, output: output, maxPixels: maxPixels, trash: trash))
                    }
                }
                if cancelled { next = total }
                guard let (index, result) = await group.next() else { break }
                inFlight -= 1
                outcomes[index] = result
                completed += 1
                if case .failure = result { failed += 1 }
                progress(BatchProgress(completed: completed, failed: failed, total: total))
            }
        }

        var report = BatchReport(cancelled: cancelled)
        for (plan, outcome) in zip(plans, outcomes) {
            switch outcome {
            case .success(let url): report.written.append(url)
            case .failure(let error):
                report.failures.append(BatchFailure(source: plan.item.source, reason: error.reason))
            case nil: break
            }
        }
        return report
    }

    private static func convert(
        _ plan: PlannedOutput, output: OutputSettings, maxPixels: Int, trash: Trasher
    ) -> Result<URL, ConversionError> {
        autoreleasepool {
            do {
                let loaded = try ImageLoader.load(plan.item.source, maxPixels: maxPixels)
                let data = try ImageEncoder.encode(loaded.image, properties: loaded.properties, settings: output)
                try FileCommitter.commit(data, for: plan, trash: trash)
                return .success(plan.destination)
            } catch let error as ConversionError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }
    }
}
