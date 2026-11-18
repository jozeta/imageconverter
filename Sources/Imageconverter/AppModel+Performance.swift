import AppKit
import Foundation
import ImageconverterCore

extension AppDefaults {
    /// The interrupted-run journal: the real one, or a temporary file per suite in DEBUG screenshot launches
    /// (so those runs never offer or overwrite the user's own).
    static let journalURL: URL? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugDefaultsSuite"), index + 1 < args.count {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("imageconverter-\(args[index + 1])/journal.json")
        }
        #endif
        return RunJournal.defaultURL
    }()
}

extension AppModel {
    /// The preview and the size estimate run during a batch too, unless low-memory mode is on or the batch
    /// overwrites its originals (they would read files that are being replaced or moved to the Trash).
    var previewAllowed: Bool { !isRunning || (!lowMemoryMode && !monitor.overwriting) }

    /// Hands the mode to a running batch and starts or stops the preview to match.
    func lowMemoryModeChanged() {
        monitor.control?.setLowMemory(lowMemoryMode)
        guard isRunning, !monitor.overwriting else { return }
        if lowMemoryMode {
            resetPreview()
            cancelEstimate()
        } else {
            schedulePreview(mode: previewMode)
            scheduleEstimate()
        }
    }

    /// Pause/Resume (⌥⌘.): no new image starts while paused; the ones already running finish.
    func togglePause() {
        guard isRunning, monitor.control != nil else { return }
        monitor.setPaused(!monitor.isPaused)
    }

    /// Moves `sources` (not started yet) to the front of the running batch.
    func processNext(_ sources: [URL]) {
        guard isRunning, !sources.isEmpty else { return }
        monitor.control?.prioritize(sources)
        let count = sources.count
        toasts.show(count == 1 ? "\(sources[0].lastPathComponent) is next" : "\(count) images are next", type: .info)
    }

    /// The selected image, for the menu item.
    func processSelectedNext() {
        guard let index = selectedItemIndex else { return }
        processNext([items[index].source])
    }

    /// Each item's pixel count from a header read (0 when unreadable), for the MP/s rate and the ETA.
    nonisolated static func sourcePixels(of batch: [InputItem]) async -> [Int] {
        await Task.detached(priority: .utility) {
            batch.map { item in ImageLoader.pixelSize(of: item.source).map { $0.width * $0.height } ?? 0 }
        }.value
    }

    // MARK: Interrupted batches

    private static var journalChecked = false

    /// `checkInterruptedRun` once per launch (the window can appear again).
    func checkInterruptedRunOnce() {
        guard !Self.journalChecked else { return }
        Self.journalChecked = true
        checkInterruptedRun()
    }

    /// At launch: offers a batch the app never got to the end of (crash, forced quit). Read off the main actor.
    func checkInterruptedRun() {
        let url = AppDefaults.journalURL
        Task { [weak self] in
            let journal = await Task.detached(priority: .utility) { RunJournal.pending(at: url) }.value
            guard let self, let journal, !isRunning else { return }
            if journal.remainingItems.isEmpty {
                RunJournal.discard(at: url)
            } else {
                interruptedRun = journal
                showsInterruptedRun = true
            }
        }
    }

    func discardInterruptedRun() {
        interruptedRun = nil
        RunJournal.discard(at: AppDefaults.journalURL)
    }

    /// Before Run replaces a kept interrupted batch's journal: asks, and discards it on confirmation.
    /// Returns false when the user keeps it (the run doesn't start).
    func confirmDiscardingInterruptedRun() -> Bool {
        guard let journal = interruptedRun else { return true }
        let left = journal.remainingItems.count
        let alert = NSAlert()
        alert.messageText = "Discard the interrupted batch?"
        alert.informativeText = "\(left) \(left == 1 ? "image" : "images") of the interrupted batch "
            + "\(left == 1 ? "wasn't" : "weren't") converted. A new run replaces it, so it can't be resumed afterwards."
        alert.addButton(withTitle: "Discard and Run")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        discardInterruptedRun()
        return true
    }

    /// Adds the images still to do and runs them with the batch's own pipeline and output mode, for this run
    /// only (the pipeline being edited and Save to stay as they are); files that are gone are reported. The sheet
    /// confirms overwriting first. The new run writes its own journal, replacing the old one.
    /// In the sandbox the batch's folders and loose files are opened again through the journal's bookmarks (the
    /// sandbox forgets them on quit); for any image still unreadable its folder is asked for before the plan is
    /// made, and images in a folder the user doesn't allow are reported as "couldn't open", never dropped silently.
    /// The interrupted batch stays (`interruptedRun`, so other runs still ask before replacing it) until its run has
    /// started; a refused start keeps it and says why (Core `ResumeStart`).
    func resumeInterruptedRun() {
        guard let journal = interruptedRun, !isRunning else { return }
        showsInterruptedRun = false
        let existing = items
        let regained = journal.regainAccess()
        _ = AccessStore.shared.holdForSession(regained.access)
        AccessStore.shared.holdFilesForSession(journal.regainFileAccess())
        Task { [weak self] in
            let remaining = journal.remainingItems.map(\.source)
            let unreadable = await Task.detached(priority: .userInitiated) {
                remaining.filter { !FileManager.default.isReadableFile(atPath: $0.path) }
            }.value
            let refused = AccessStore.shared.askToRead(unreadable)
            let plan = await Task.detached(priority: .userInitiated) {
                ResumePlan.make(journal: journal, existing: existing,
                                isReadable: { FileManager.default.isReadableFile(atPath: $0) },
                                directoryExists: { path in
                                    var isDirectory: ObjCBool = false
                                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                                        && isDirectory.boolValue
                                },
                                refusedFolders: refused)
            }.value
            self?.apply(plan)
        }
    }

    private func apply(_ plan: ResumePlan) {
        // Discarded meanwhile (another run's question, or Run): nothing to resume.
        guard interruptedRun != nil else { return }
        items.append(contentsOf: plan.toAdd)
        if !plan.missing.isEmpty {
            let names = plan.missing.map(\.lastPathComponent).sorted()
            let count = names.count
            toasts.show("\(count) \(count == 1 ? "file" : "files") of the interrupted batch \(count == 1 ? "is" : "are") missing",
                        type: .bad, description: names.prefix(20).joined(separator: "\n") + (count > 20 ? "\n…" : ""))
        }
        if !plan.unopened.isEmpty {
            let names = plan.unopened.map(\.lastPathComponent).sorted()
            let count = names.count
            toasts.show("\(count) \(count == 1 ? "file" : "files") of the interrupted batch couldn't be opened",
                        type: .bad, description: names.prefix(20).joined(separator: "\n") + (count > 20 ? "\n…" : "")
                            + "\nNo access to \(count == 1 ? "its folder" : "their folders"). Add them again to convert them.")
        }
        if !plan.alreadyReplaced.isEmpty {
            let names = plan.alreadyReplaced.map(\.lastPathComponent).sorted()
            let count = names.count
            toasts.show("\(count) \(count == 1 ? "original was" : "originals were") already replaced",
                        type: .info,
                        description: "Changed since the batch started, so not converted again:\n"
                            + names.prefix(20).joined(separator: "\n") + (count > 20 ? "\n…" : ""))
        }
        switch plan.problem {
        case .nothingLeft:
            discardInterruptedRun()
        case .outputFolderMissing(let folder):
            // Without its folder the batch can't run as it was: the images and pipeline are set up for a new Run.
            discardInterruptedRun()
            session = PresetSession(selected: nil, pipeline: plan.pipeline)
            toasts.show("The folder \(folder.lastPathComponent) can't be found", type: .bad,
                        description: "The images and the batch's pipeline were added. Choose an output folder, then Run.")
        case nil:
            Task { [weak self] in
                guard let started = await self?.startRun(plan.toRun, pipeline: plan.pipeline, mode: plan.mode,
                                                         presetName: nil) else { return }
                self?.resumeDidStart(started)
            }
        }
    }

    /// A refused or busy start keeps the interrupted batch (journal and question) and says why.
    /// Started: `startRun` replaced it with this run's journal. Not started: it's still there, unless the user
    /// discarded it meanwhile (another run's question), and then there's nothing to say.
    private func resumeDidStart(_ started: RunStart) {
        let outcome = ResumeStart.after(started)
        guard outcome.keepsInterruptedRun, interruptedRun != nil else { return }
        if let title = outcome.toastTitle {
            toasts.show(title, type: .bad, description: outcome.toastDescription)
        }
        if outcome.asksAgain, !isRunning { showsInterruptedRun = true }
    }

    #if DEBUG
    /// `-debugResumeInterrupted`: presses Resume once the sheet is up (no clicks in screenshot sessions).
    func debugResumeInterrupted(settings: AppSettings) {
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if interruptedRun != nil {
                    resumeInterruptedRun()
                    return
                }
            }
        }
    }

    /// `-debugAutoRun`: runs the batch once the launch's `-debugAddFiles` are in (screenshots of a running batch).
    func debugAutoRun(settings: AppSettings) {
        Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if !isAdding, !items.isEmpty {
                    run(settings: settings)
                    return
                }
            }
        }
    }
    #endif
}
