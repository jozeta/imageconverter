import AppKit
import CoreGraphics
import Observation
import ImageconverterCore

@MainActor @Observable
final class AppModel {
    var items: [InputItem] = []
    /// The selected preset and the pipeline being edited; both are saved to `UserDefaults` on every change.
    var session: PresetSession {
        didSet { persist() }
    }
    /// The image steps and output format being edited (the session's pipeline).
    var pipeline: Pipeline {
        get { session.pipeline }
        set { session.pipeline = newValue }
    }
    /// The user's saved presets, sorted by name; the built-ins are in `PresetStore.builtIns`.
    var userPresets: [Preset] = []
    /// Set by Save (⌘S) on a built-in or ad hoc pipeline; the preset bar shows its "Save as" sheet.
    var isSavingAs = false
    var progress: BatchProgress?
    /// The last run in the shared report model (summary plus one entry per file); cleared by a new run or Clear.
    var runReport: ProcessingReport?
    var isRunning = false
    /// Number of drops/pickers still being scanned off the main actor.
    private(set) var pendingAdds = 0
    var isAdding: Bool { pendingAdds > 0 }
    let toasts = LGToastCenter()
    /// The before/after zoom, shared by both preview sides and the View menu.
    let zoom = ZoomController()
    /// "Example: name.ext" for the Rename editor; see `refreshRenameExample()`.
    private(set) var renameExample = ""

    /// The selected image (index into `items`); see `selectedItemIndex` for the clamped value.
    var selectedIndex = 0
    /// The latest preview, kept on screen while the next one renders.
    var previewResult: PreviewResult?
    /// Why the last render failed (nil when it succeeded).
    var previewFailure: String?
    /// The name of the item whose render failed, shown when there is no result for it.
    var previewFailureName: String?
    var isRenderingPreview = false
    /// Original and estimated output size of the selected item (see `AppModel+Estimate.swift`).
    var sizeEstimate: SizeEstimate?
    @ObservationIgnored private var runInfo = (total: 0, started: Date(), mode: "")
    /// True while the estimate for the selected item is being computed.
    var isEstimating = false
    /// Set when the last estimate failed (shown as a dash).
    var estimateFailed = false
    /// Bumped when a filmstrip thumbnail has loaded, so cells refresh (see `AppModel+Preview.swift`).
    var thumbnailTick = 0
    var previewCollapsed: Bool {
        didSet { defaults.set(previewCollapsed, forKey: Self.previewCollapsedKey) }
    }
    var pipelineCollapsed: Bool {
        didSet { defaults.set(pipelineCollapsed, forKey: Self.pipelineCollapsedKey) }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    @ObservationIgnored var previewGeneration = 0
    @ObservationIgnored var estimateTask: Task<Void, Never>?
    @ObservationIgnored var estimateKey: EstimateKey?
    /// Sizes the main window to its panels and animates the preview and pipeline toggles.
    @ObservationIgnored let windowSizer: WindowSizer
    @ObservationIgnored var previewMode: OutputMode?
    @ObservationIgnored let previewRenderer = PreviewRenderer()
    @ObservationIgnored let thumbnailCache: NSCache<NSURL, CGImageBox> = {
        let cache = NSCache<NSURL, CGImageBox>()
        cache.countLimit = 500
        return cache
    }()
    @ObservationIgnored var thumbnailsLoading: Set<URL> = []
    @ObservationIgnored var thumbnailsFailed: Set<URL> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var exampleSource: (url: URL, info: RenameSource)?
    @ObservationIgnored private var exampleCache: (key: RenameExampleKey, text: String)?
    @ObservationIgnored let presetStore: PresetStore
    static let pipelineKey = "currentPipeline"
    static let selectedPresetKey = "selectedPresetID"
    static let previewCollapsedKey = "previewCollapsed"
    static let pipelineCollapsedKey = "pipelineCollapsed"

    init(defaults: UserDefaults = .standard,
         presetStore: PresetStore = PresetStore(directory: PresetStore.defaultDirectory)) {
        self.defaults = defaults
        self.presetStore = presetStore
        previewCollapsed = defaults.bool(forKey: Self.previewCollapsedKey)
        pipelineCollapsed = defaults.bool(forKey: Self.pipelineCollapsedKey)
        windowSizer = WindowSizer(previewShown: !defaults.bool(forKey: Self.previewCollapsedKey))
        let saved = Self.loadPipeline(from: defaults)
        session = PresetSession(selected: nil, pipeline: saved)
        let result = presetStore.loadAll()
        userPresets = PresetStore.userPresets(from: result.presets)
        // A remembered preset is selected again; if the saved pipeline differs it shows as modified.
        if let id = defaults.string(forKey: Self.selectedPresetKey).flatMap(UUID.init(uuidString:)),
           let preset = allPresets.first(where: { $0.id == id }) {
            session = PresetSession(selected: preset, pipeline: saved)
        }
        if !result.skipped.isEmpty {
            let count = result.skipped.count
            toasts.show("Skipped \(count) preset \(count == 1 ? "file" : "files")", type: .info,
                        description: result.skipped.map { "\($0.file): \($0.reason)" }.joined(separator: "\n"))
        }
    }

    /// An undecodable or missing value gives an empty pipeline with the default output.
    static func loadPipeline(from defaults: UserDefaults) -> Pipeline {
        guard let data = defaults.data(forKey: pipelineKey),
              let pipeline = try? JSONDecoder().decode(Pipeline.self, from: data) else { return Pipeline() }
        return pipeline
    }

    func persist() {
        if let data = try? JSONEncoder().encode(session.pipeline) { defaults.set(data, forKey: Self.pipelineKey) }
        if let id = session.selected?.id {
            defaults.set(id.uuidString, forKey: Self.selectedPresetKey)
        } else {
            defaults.removeObject(forKey: Self.selectedPresetKey)
        }
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
        selectedIndex = 0
        thumbnailCache.removeAllObjects()
        thumbnailsFailed = []
        resetPreview()
        cancelEstimate()
        progress = nil
        runReport = nil
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
        runInfo = (batch.count, Date(), mode.kind.rawValue)
        isRunning = true
        resetPreview()
        cancelEstimate()
        runReport = nil
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
        Task { await previewRenderer.purge() }
        schedulePreview(mode: previewMode)
        scheduleEstimate()
        runReport = ProcessingReport(batch: report, total: runInfo.total, outputMode: runInfo.mode,
                                     presetName: session.selected?.name, startedAt: runInfo.started)
        progress = nil
        dropMissingItems()
        let done = report.written.count
        let skipped = report.failures.count
        let prefix = report.cancelled ? "Cancelled. " : ""
        let totals = runReport?.summary
        let saved = SizeFormat.savedPhrase(input: totals?.inputBytes ?? 0, output: totals?.outputBytes ?? 0).map { " · \($0)" } ?? ""
        let what = skipped == 0 ? "\(done) \(done == 1 ? "image" : "images")" : "\(done), \(skipped) skipped"
        toasts.show("\(prefix)Converted \(what)\(saved)", type: skipped > 0 ? .bad : (report.cancelled ? .info : .ok))
    }

    // MARK: Rename example

    /// What the live example depends on; when it changes the example is recomputed.
    var renameExampleKey: RenameExampleKey {
        RenameExampleKey(
            exampleItem: selectedItemIndex.map { items[$0].source }, index: selectedItemIndex ?? 0, pattern: pipeline.rename.pattern,
            counterStart: pipeline.rename.counterStart,
            replacements: pipeline.rename.replacements,
            format: pipeline.output.format, steps: pipeline.steps)
    }

    /// Renders the rename pattern for the selected image (the first by default, or a built-in sample when there are none).
    /// The file is read off the main actor; the header is kept per file and the result per key.
    func refreshRenameExample() async {
        let key = renameExampleKey
        if let cached = exampleCache, cached.key == key {
            renameExample = cached.text
            return
        }
        let pipeline = self.pipeline
        let known = exampleSource.flatMap { $0.url == key.exampleItem ? $0.info : nil }
        let (info, text) = await Task.detached(priority: .userInitiated) {
            Self.renderExample(url: key.exampleItem, known: known, pipeline: pipeline, index: key.index)
        }.value
        guard !Task.isCancelled else { return }
        if let url = key.exampleItem { exampleSource = (url, info) }
        exampleCache = (key, text)
        renameExample = text
    }

    nonisolated private static func renderExample(
        url: URL?, known: RenameSource?, pipeline: Pipeline, index: Int
    ) -> (RenameSource, String) {
        var info = known ?? RenameSource(header: nil, created: nil)
        if let url, known == nil {
            info = RenameSource(
                header: ImageLoader.header(of: url),
                created: (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
        }
        let name = RenameExample.render(source: url, header: info.header, created: info.created, pipeline: pipeline,
                                    index: index)
        return (info, "Example: \(name)")
    }
}

/// The part of a source image the rename example needs; read once per file.
struct RenameSource: @unchecked Sendable {
    let header: ImageHeader?
    let created: Date?
}

struct RenameExampleKey: Equatable {
    let exampleItem: URL?
    let index: Int
    let pattern: String
    let counterStart: Int
    let replacements: [ReplacementRule]
    let format: OutputFormat
    let steps: [PipelineStep]
}

/// Reference wrapper so `NSCache` can hold a `CGImage`.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
