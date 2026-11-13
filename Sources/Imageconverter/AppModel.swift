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
    let toasts = LGToastCenter()

    @ObservationIgnored private var task: Task<Void, Never>?

    func add(_ urls: [URL]) {
        var seen = Set(items)
        for item in InputCollector.collect(urls) where seen.insert(item).inserted {
            items.append(item)
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
        guard !isRunning, !items.isEmpty else { return }
        if settings.modeKind == .newFolder, settings.outputFolder == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose output folder"
            panel.prompt = "Choose"
            guard panel.runModal() == .OK, let url = panel.url else { return }
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
                    if self?.isRunning == true { self?.progress = update }
                }
            })
            self?.finish(report)
        }
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
