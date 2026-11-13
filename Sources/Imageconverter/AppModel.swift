import AppKit
import Observation
import ImageconverterCore

@MainActor @Observable
final class AppModel {
    var items: [InputItem] = []
    /// The image steps and output format; saved to `UserDefaults` on every change.
    var pipeline: Pipeline {
        didSet { Self.save(pipeline, to: defaults) }
    }
    var progress: BatchProgress?
    var lastReport: BatchReport?
    var isRunning = false
    /// Number of drops/pickers still being scanned off the main actor.
    private(set) var pendingAdds = 0
    var isAdding: Bool { pendingAdds > 0 }
    let toasts = LGToastCenter()
    /// "Example: name.ext" for the Rename editor; see `refreshRenameExample()`.
    private(set) var renameExample = ""

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var exampleSource: (url: URL, info: RenameSource)?
    @ObservationIgnored private var exampleCache: (key: RenameExampleKey, text: String)?
    static let pipelineKey = "currentPipeline"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pipeline = Self.loadPipeline(from: defaults)
    }

    /// An undecodable or missing value gives an empty pipeline with the default output.
    static func loadPipeline(from defaults: UserDefaults) -> Pipeline {
        guard let data = defaults.data(forKey: pipelineKey),
              let pipeline = try? JSONDecoder().decode(Pipeline.self, from: data) else { return Pipeline() }
        return pipeline
    }

    private static func save(_ pipeline: Pipeline, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(pipeline) { defaults.set(data, forKey: pipelineKey) }
    }

    // MARK: Pipeline editing

    func addStep(_ kind: StepKind) -> PipelineStep {
        var operation = kind.defaultOperation
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if case .watermark(var options) = operation, !fullName.isEmpty {
            options.content = .text(TextWatermark(text: "© " + fullName))
            operation = .watermark(options)
        }
        let step = PipelineStep(operation: operation)
        pipeline.steps.append(step)
        return step
    }

    func removeStep(_ id: PipelineStep.ID) {
        pipeline.steps.removeAll { $0.id == id }
    }

    func moveStep(_ id: PipelineStep.ID, by offset: Int) {
        guard let index = pipeline.steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard pipeline.steps.indices.contains(target) else { return }
        pipeline.steps.swapAt(index, target)
    }

    /// Drag and drop: puts `id` where `target` is now.
    /// Returns false when either id is not a current step.
    func moveStep(_ id: PipelineStep.ID, to target: PipelineStep.ID) -> Bool {
        guard let from = pipeline.steps.firstIndex(where: { $0.id == id }),
              let dest = pipeline.steps.firstIndex(where: { $0.id == target }) else { return false }
        guard from != dest else { return true }
        let step = pipeline.steps.remove(at: from)
        pipeline.steps.insert(step, at: dest)
        return true
    }

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
        let pipeline = self.pipeline
        isRunning = true
        lastReport = nil
        progress = BatchProgress(completed: 0, failed: 0, total: batch.count)
        task = Task { [weak self] in
            let report = await BatchRunner.run(batch, pipeline: pipeline, mode: mode, progress: { update in
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

    // MARK: Rename example

    /// What the live example depends on; when it changes the example is recomputed.
    var renameExampleKey: RenameExampleKey {
        RenameExampleKey(
            firstItem: items.first?.source, pattern: pipeline.rename.pattern,
            counterStart: pipeline.rename.counterStart, format: pipeline.output.format, steps: pipeline.steps)
    }

    /// Renders the rename pattern for the first image (or a built-in sample when there are none).
    /// The file is read off the main actor; the header is kept per file and the result per key.
    func refreshRenameExample() async {
        let key = renameExampleKey
        if let cached = exampleCache, cached.key == key {
            renameExample = cached.text
            return
        }
        let pipeline = self.pipeline
        let known = exampleSource.flatMap { $0.url == key.firstItem ? $0.info : nil }
        let (info, text) = await Task.detached(priority: .userInitiated) {
            Self.renderExample(url: key.firstItem, known: known, pipeline: pipeline)
        }.value
        guard !Task.isCancelled else { return }
        if let url = key.firstItem { exampleSource = (url, info) }
        exampleCache = (key, text)
        renameExample = text
    }

    nonisolated private static func renderExample(
        url: URL?, known: RenameSource?, pipeline: Pipeline
    ) -> (RenameSource, String) {
        var info = known ?? RenameSource(header: nil, created: nil)
        if let url, known == nil {
            info = RenameSource(
                header: ImageLoader.header(of: url),
                created: (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
        }
        let name = RenameExample.render(source: url, header: info.header, created: info.created, pipeline: pipeline)
        return (info, "Example: \(name)")
    }
}

/// The part of a source image the rename example needs; read once per file.
struct RenameSource: @unchecked Sendable {
    let header: ImageHeader?
    let created: Date?
}

struct RenameExampleKey: Equatable {
    let firstItem: URL?
    let pattern: String
    let counterStart: Int
    let format: OutputFormat
    let steps: [PipelineStep]
}
