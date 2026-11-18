import Foundation
import ImageconverterCore

/// The Shortcuts actions converting right now or waiting for their turn, so quitting waits for them like for a
/// batch (`QuitCoordinator`), and their History entries. Their batches run one at a time, first come first served
/// (Core `AutomationQueue`); once quitting, new actions are refused with "imageconverter is quitting."
@MainActor
final class AutomationRuns {
    static let shared = AutomationRuns()

    private var running: [UUID: Task<AutomationResult, Error>] = [:]
    private let queue = AutomationQueue()
    /// History entries still being written (quitting waits for them).
    private(set) var pendingHistoryWrites = 0
    /// Set by `cancelAll` (quit confirmed): nothing new starts.
    private(set) var isStopping = false

    var count: Int { running.count }
    var isActive: Bool { !running.isEmpty || pendingHistoryWrites > 0 }

    /// Runs `work` as a tracked action, after the actions before it; cancelling the calling task (Shortcuts
    /// stopping it) cancels the work, or takes it out of the queue.
    func run(_ work: @escaping @Sendable () async throws -> AutomationResult) async throws -> AutomationResult {
        if isStopping { throw AutomationError.quitting }
        let id = UUID()
        let queue = self.queue
        let task = Task { try await queue.run(work) }
        running[id] = task
        defer { running[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError where isStopping {
            // Taken out of the queue by the quit: say so instead of "cancelled".
            throw AutomationError.quitting
        }
    }

    /// Quitting: every action stops between files (nothing half-written stays; `FileCommitter`), waiting ones and
    /// later ones are refused.
    func cancelAll() {
        isStopping = true
        running.values.forEach { $0.cancel() }
        let queue = self.queue
        Task { await queue.stop() }
    }

    /// Stores a finished action in History and its failures in the error log, like a manual run.
    func record(_ report: ProcessingReport) {
        let history = RunHistory.shared(directory: AppDefaults.historyDirectory)
        let log = ErrorLog.shared(directory: AppDefaults.logsDirectory)
        let failures = report.entries.filter { $0.status == .failed }.map { ($0.source, $0.note ?? "Failed") }
        pendingHistoryWrites += 1
        Task {
            await Task.detached(priority: .utility) {
                try? history.save(report)
                log.record(failures)
            }.value
            self.pendingHistoryWrites -= 1
            NotificationCenter.default.post(name: .runHistoryChanged, object: nil)
        }
    }
}
