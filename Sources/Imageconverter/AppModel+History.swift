import Foundation
import ImageconverterCore

extension AppModel {
    /// Stores a finished manual run in the history and its failures in the error log. Jobs record through
    /// `JobsController.record`, so each run is written exactly once. File work runs off the main actor.
    func recordRun(_ report: ProcessingReport) {
        let history = RunHistory.shared(directory: AppDefaults.historyDirectory)
        let log = ErrorLog.shared(directory: AppDefaults.logsDirectory)
        let failures = report.entries.filter { $0.status == .failed }.map { ($0.source, $0.note ?? "Failed") }
        // Counted so quitting waits for it (a stopped run's history isn't lost).
        pendingHistoryWrites += 1
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                try? history.save(report)
                log.record(failures)
            }.value
            self?.pendingHistoryWrites -= 1
            NotificationCenter.default.post(name: .runHistoryChanged, object: nil)
        }
    }
}
