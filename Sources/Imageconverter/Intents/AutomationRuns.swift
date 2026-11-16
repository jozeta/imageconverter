import Foundation
import ImageconverterCore

/// The Shortcuts actions converting right now, so quitting waits for them like for a batch (`QuitCoordinator`),
/// and their History entries.
@MainActor
final class AutomationRuns {
    static let shared = AutomationRuns()

    private var running: [UUID: Task<AutomationResult, Error>] = [:]
    /// History entries still being written (quitting waits for them).
    private(set) var pendingHistoryWrites = 0

    var count: Int { running.count }
    var isActive: Bool { !running.isEmpty || pendingHistoryWrites > 0 }

    /// Runs `work` as a tracked action; cancelling the calling task (Shortcuts stopping it) cancels the work.
    func run(_ work: @escaping @Sendable () async throws -> AutomationResult) async throws -> AutomationResult {
        let id = UUID()
        let task = Task { try await work() }
        running[id] = task
        defer { running[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Quitting: every action stops between files (nothing half-written stays; `FileCommitter`).
    func cancelAll() { running.values.forEach { $0.cancel() } }

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
