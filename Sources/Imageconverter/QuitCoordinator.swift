import AppKit
import ImageconverterCore

/// Decides whether the app may quit now (`applicationShouldTerminate`). With a manual batch, a job run or a
/// Shortcuts action going it
/// asks "Stop and quit?" first; on yes it cancels everything, waits (at most `maxWait`) until runs have committed
/// their files and saved their ledgers and history, removes the app's leftover temp files, forgets the manual run's
/// journal (only when a manual batch was running; the user chose to stop, a crash still leaves it for the next
/// launch), and then lets the app quit.
@MainActor
final class QuitCoordinator {
    static let shared = QuitCoordinator()
    static let maxWait: TimeInterval = 10

    private var isStopping = false

    private var model: AppModel? { ExternalActions.shared.model }
    private var jobs: JobsController { JobsController.shared }

    private var manualRunning: Bool { model?.isRunning ?? false }
    private var actions: AutomationRuns { AutomationRuns.shared }
    private var anythingRunning: Bool { manualRunning || jobs.hasActiveRuns || actions.count > 0 }

    func shouldTerminate() -> NSApplication.TerminateReply {
        if isStopping { return .terminateLater }
        guard anythingRunning else { return .terminateNow }
        guard confirm() else { return .terminateCancel }
        isStopping = true
        // Only a manual batch's journal is forgotten; a job-only quit keeps any pending resume offer.
        let manual = manualRunning
        stopEverything()
        Task { await finishQuitting(clearJournal: manual) }
        return .terminateLater
    }

    /// "Stop and quit?" Cancel is the default (Return) and also answers Escape.
    private func confirm() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop and quit?"
        alert.informativeText = Self.message(manual: manualRunning, jobs: jobs.runningCount, actions: actions.count)
        alert.alertStyle = .warning
        let stop = alert.addButton(withTitle: "Stop and Quit")
        stop.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func message(manual: Bool, jobs: Int, actions: Int = 0) -> String {
        var running: [String] = []
        if manual { running.append("a batch") }
        if jobs > 0 { running.append(jobs == 1 ? "a job" : "\(jobs) jobs") }
        if actions > 0 { running.append(actions == 1 ? "a Shortcuts action" : "\(actions) Shortcuts actions") }
        let list = running.count > 2 ? running.dropLast().joined(separator: ", ") + " and " + (running.last ?? "")
            : running.joined(separator: " and ")
        return "imageconverter is converting \(list). Files already written are kept; "
            + "the rest is not converted. Nothing half-written is left behind."
    }

    private func stopEverything() {
        jobs.stopForQuit()
        model?.cancel()
        actions.cancelAll()
    }

    private func finishQuitting(clearJournal: Bool) async {
        let deadline = Date().addingTimeInterval(Self.maxWait)
        // Runs end after committing their files and saving their ledgers; then their history is written.
        while anythingRunning || jobs.hasPendingWrites || (model?.pendingHistoryWrites ?? 0) > 0 || actions.isActive,
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let directories = FileCommitter.writtenDirectories
        // A minute's grace like the cancel path: a temp file the command-line tool is writing into the same folder
        // right now isn't this app's to remove.
        await Task.detached(priority: .userInitiated) {
            FileCommitter.cleanUp(in: directories, olderThan: FileCommitter.cancelCleanupAge)
        }.value
        if clearJournal { RunJournal.discard(at: AppDefaults.journalURL) }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
