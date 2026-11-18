import AppKit
import ImageconverterCore

/// Decides whether the app may quit now (`applicationShouldTerminate`), with Core `QuitPolicy`. While the update
/// installer service is replacing the app it only offers to wait. With a manual batch, a job run or a Shortcuts
/// action going (or waiting for its turn) it asks "Stop and quit?" first; on yes it cancels everything, waits (at
/// most `maxWait`) until runs have committed their files and saved their ledgers and history, removes the app's
/// leftover temp files, forgets the manual run's journal (only when a manual batch was running; the user chose to
/// stop, a crash still leaves it for the next launch), and then lets the app quit.
@MainActor
final class QuitCoordinator {
    static let shared = QuitCoordinator()
    static let maxWait: TimeInterval = 10

    private var isStopping = false

    private var model: AppModel? { ExternalActions.shared.model }
    private var jobs: JobsController { JobsController.shared }

    private var manualRunning: Bool { model?.isRunning ?? false }
    private var actions: AutomationRuns { AutomationRuns.shared }
    private var work: RunningWork {
        RunningWork(manualBatch: manualRunning, jobs: jobs.hasActiveRuns ? max(jobs.runningCount, 1) : 0,
                    actions: actions.count, installingUpdate: UpdateController.shared.installActivity.isInstalling)
    }
    private var anythingRunning: Bool { work.anything }

    func shouldTerminate() -> NSApplication.TerminateReply {
        if isStopping { return .terminateLater }
        guard let question = QuitPolicy.question(for: work) else { return .terminateNow }
        guard confirm(question) else { return .terminateCancel }
        isStopping = true
        // Only a manual batch's journal is forgotten; a job-only quit keeps any pending resume offer.
        let manual = manualRunning
        stopEverything()
        Task { await finishQuitting(clearJournal: manual) }
        return .terminateLater
    }

    /// "Stop and quit?" Cancel is the default (Return) and also answers Escape. While an update installs there is
    /// only Wait: the answer is always no.
    private func confirm(_ question: QuitQuestion) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.alertStyle = .warning
        let stop = question.stopButton.map { alert.addButton(withTitle: $0) }
        stop?.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: question.cancelButton)
        cancel.keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        let answer = alert.runModal()
        return stop != nil && answer == .alertFirstButtonReturn
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
