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
    /// The preview and the size estimate run during a batch too, unless low-memory mode is on.
    var previewAllowed: Bool { !isRunning || !lowMemoryMode }

    /// Hands the mode to a running batch and starts or stops the preview to match.
    func lowMemoryModeChanged() {
        monitor.control?.setLowMemory(lowMemoryMode)
        guard isRunning else { return }
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
            }
        }
    }

    func discardInterruptedRun() {
        interruptedRun = nil
        RunJournal.discard(at: AppDefaults.journalURL)
    }

    /// Adds the items still to do, restores the batch's pipeline and output mode, reports files that are gone
    /// and runs the rest. The new run writes its own journal, replacing the old one.
    func resumeInterruptedRun(settings: AppSettings) {
        guard let journal = interruptedRun, !isRunning else { return }
        interruptedRun = nil
        let remaining = journal.remainingItems
        Task { [weak self] in
            let missing = await Task.detached(priority: .userInitiated) {
                Set(remaining.filter { !FileManager.default.fileExists(atPath: $0.source.path) }.map(\.source))
            }.value
            guard let self else { return }
            let present = remaining.filter { !missing.contains($0.source) }
            var seen = Set(items)
            for item in present where seen.insert(item).inserted { items.append(item) }
            session = PresetSession(selected: nil, pipeline: journal.pipeline)
            settings.apply(journal.outputMode)
            if !missing.isEmpty {
                let names = missing.map(\.lastPathComponent).sorted()
                toasts.show("\(missing.count) \(missing.count == 1 ? "file" : "files") of the interrupted batch "
                            + "\(missing.count == 1 ? "is" : "are") missing", type: .bad,
                            description: names.prefix(20).joined(separator: "\n") + (names.count > 20 ? "\n…" : ""))
            }
            guard !present.isEmpty, let mode = settings.outputMode, Self.folderExists(for: mode) else {
                if !present.isEmpty { toasts.show("Choose an output folder, then Run", type: .info) }
                RunJournal.discard(at: AppDefaults.journalURL)
                return
            }
            startRun(present, pipeline: journal.pipeline, mode: mode, presetName: nil)
        }
    }

    private static func folderExists(for mode: OutputMode) -> Bool {
        guard case .newFolder(let folder) = mode else { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    #if DEBUG
    /// `-debugResumeInterrupted`: presses Resume once the sheet is up (no clicks in screenshot sessions).
    func debugResumeInterrupted(settings: AppSettings) {
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if interruptedRun != nil {
                    resumeInterruptedRun(settings: settings)
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

extension AppSettings {
    /// Sets the output mode a resumed batch had.
    func apply(_ mode: OutputMode) {
        switch mode {
        case .newFolder(let folder):
            outputFolder = folder
            modeKind = .newFolder
        case .sameFolder(let suffix):
            sameFolderSuffix = suffix
            modeKind = .sameFolder
        case .overwrite:
            modeKind = .overwrite
        }
    }
}
