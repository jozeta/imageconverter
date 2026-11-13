import AppKit
import Observation
import ImageconverterCore

@MainActor @Observable
final class AppModel {
    var items: [InputItem] = []
    var output = OutputSettings()
    var progress: BatchProgress?
    var lastReport: BatchReport?
    var isRunning = false
    /// Number of drops/pickers still being scanned off the main actor.
    private(set) var pendingAdds = 0
    var isAdding: Bool { pendingAdds > 0 }
    let toasts = LGToastCenter()

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Scans `urls` off the main actor (large folders), then merges new items in, skipping duplicates.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingAdds += 1
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { InputCollector.collect(urls) }.value
            guard let self else { return }
            var seen = Set(self.items)
            for item in found where seen.insert(item).inserted {
                self.items.append(item)
            }
            self.pendingAdds -= 1
        }
    }

    func clear() {
        guard !isRunning else { return }
        items = []
        progress = nil
        lastReport = nil
    }

    /// Asks for files and folders to add.
    func chooseInputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func run(settings: AppSettings) {
        guard !isRunning, !isAdding, !items.isEmpty else { return }
        if settings.modeKind == .newFolder, !Self.isExistingDirectory(settings.outputFolder) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose output folder"
            panel.prompt = "Choose"
            guard panel.runModal() == .OK, let url = panel.url else {
                toasts.show("Choose an output folder to run", type: .info)
                return
            }
            settings.outputFolder = url
        }
        guard let mode = settings.outputMode else { return }

        let batch = items
        let format = output
        isRunning = true
        lastReport = nil
        progress = BatchProgress(completed: 0, failed: 0, total: batch.count)
        task = Task { [weak self] in
            let report = await BatchRunner.run(batch, output: format, mode: mode, progress: { update in
                Task { @MainActor in
                    // Updates can arrive out of order; only move forward.
                    guard let self, self.isRunning, update.completed > (self.progress?.completed ?? 0) else { return }
                    self.progress = update
                }
            })
            self?.finish(report)
        }
    }

    private static func isExistingDirectory(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func cancel() { task?.cancel() }

    private func finish(_ report: BatchReport) {
        isRunning = false
        task = nil
        lastReport = report
        progress = nil
        let done = report.written.count
        let skipped = report.failures.count
        let prefix = report.cancelled ? "Cancelled. " : ""
        if skipped == 0 {
            toasts.show("\(prefix)Converted \(done) \(done == 1 ? "image" : "images")", type: report.cancelled ? .info : .ok)
        } else {
            toasts.show("\(prefix)Converted \(done), \(skipped) skipped", type: .bad)
        }
    }
}
