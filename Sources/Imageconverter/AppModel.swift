import AppKit
import CoreGraphics
import Observation
import ImageconverterCore

@MainActor @Observable
final class AppModel {
    var items: [InputItem] = [] { didSet { schedulePrivacyScan() } }
    let privacy = PrivacyState()  // the privacy scan's results and panel (`AppModel+Privacy.swift`)
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
    /// Comparison mode, batch browser mode and the selected item's difference and quality renders.
    let compare: CompareController
    /// "Example: name.ext" for the Rename editor; see `refreshRenameExample()`.
    var renameExample = ""

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
    /// Why the last estimate failed, when it is worth telling (e.g. a maximum size that can't be met).
    var estimateFailure: String?
    /// Bumped when a filmstrip thumbnail has loaded, so cells refresh (see `AppModel+Preview.swift`).
    var thumbnailTick = 0
    var previewCollapsed: Bool {
        didSet { defaults.set(previewCollapsed, forKey: Self.previewCollapsedKey) }
    }
    var pipelineCollapsed: Bool {
        didSet { defaults.set(pipelineCollapsed, forKey: Self.pipelineCollapsedKey) }
    }
    /// Two workers and a quarter of the memory budget; also stops the preview during a run. Applies to a
    /// running batch from its next item on (see `AppModel+Performance.swift`).
    var lowMemoryMode: Bool {
        didSet {
            defaults.set(lowMemoryMode, forKey: Self.lowMemoryModeKey)
            lowMemoryModeChanged()
        }
    }
    /// Stages, throughput and resources of the running (or last) batch.
    let monitor = RunMonitor()
    /// An unfinished batch found at launch (see `AppModel+Performance.swift`); the sheet shows while `shows…` is set.
    var interruptedRun: RunJournal?
    var showsInterruptedRun = false

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    @ObservationIgnored var previewGeneration = 0
    @ObservationIgnored var estimateTask: Task<Void, Never>?
    @ObservationIgnored var estimateKey: EstimateKey?
    /// Sizes the main window to its panels and animates the preview and pipeline toggles.
    @ObservationIgnored let windowSizer: WindowSizer
    @ObservationIgnored var previewMode: OutputMode?
    @ObservationIgnored let previewRenderer = PreviewRenderer()
    /// Source facts for the preview's counter number and condition branches (see `AppModel+Preview.swift`).
    @ObservationIgnored let factsCache = ItemFactsCache()
    /// The condition branches and counter number of the item the latest preview shows.
    var previewConditions: ConditionPreview?
    @ObservationIgnored let thumbnailCache: NSCache<NSURL, CGImageBox> = {
        let cache = NSCache<NSURL, CGImageBox>()
        cache.countLimit = 500
        return cache
    }()
    @ObservationIgnored var thumbnailsLoading: Set<URL> = []
    @ObservationIgnored var thumbnailsFailed: Set<URL> = []
    @ObservationIgnored private let defaults: UserDefaults
    /// History saves still being written (`recordRun`); the quit waits for them.
    @ObservationIgnored var pendingHistoryWrites = 0
    @ObservationIgnored var exampleSource: (url: URL, info: RenameSource)?
    @ObservationIgnored var exampleCache: (key: RenameExampleKey, text: String)?
    @ObservationIgnored let presetStore: PresetStore
    static let pipelineKey = "currentPipeline"
    static let selectedPresetKey = "selectedPresetID"
    static let previewCollapsedKey = "previewCollapsed"
    static let pipelineCollapsedKey = "pipelineCollapsed"
    static let lowMemoryModeKey = "lowMemoryMode"
    /// The "When finished" setting, mirrored from `AppSettings` by the main window.
    @ObservationIgnored var afterRunSetting: AfterRunAction = .nothing
    /// Bumped when a run notification is clicked; the sidebar opens the report.
    var reportRequest = 0

    init(defaults: UserDefaults = .standard,
         presetStore: PresetStore = PresetStore(directory: PresetStore.defaultDirectory)) {
        self.defaults = defaults
        self.presetStore = presetStore
        compare = CompareController(defaults: defaults)
        previewCollapsed = defaults.bool(forKey: Self.previewCollapsedKey)
        pipelineCollapsed = defaults.bool(forKey: Self.pipelineCollapsedKey)
        lowMemoryMode = defaults.bool(forKey: Self.lowMemoryModeKey)
        windowSizer = WindowSizer(previewShown: !defaults.bool(forKey: Self.previewCollapsedKey), defaults: defaults)
        let saved = Self.loadPipeline(from: defaults)
        session = PresetSession(selected: nil, pipeline: saved)
        let result = presetStore.loadAll()
        userPresets = PresetStore.userPresets(from: result.presets)
        // A remembered preset is selected again; if the saved pipeline differs it shows as modified.
        if let id = defaults.string(forKey: Self.selectedPresetKey).flatMap(UUID.init(uuidString:)),
           let preset = allPresets.first(where: { $0.id == id }) {
            session = PresetSession(selected: preset, pipeline: saved)
        }
        refreshWatermarkBookmarks()
        announceLoadNotes(saved)
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
        let step = PipelineStep(operation: Self.newOperation(kind))
        pipeline.steps.append(step)
        return step
    }

    /// A new step's settings: the kind's defaults, with the user's name in a text watermark.
    static func newOperation(_ kind: StepKind) -> ImageOperation {
        var operation = kind.defaultOperation
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if case .watermark(var options) = operation, !fullName.isEmpty {
            options.content = .text(TextWatermark(text: "© " + fullName))
            operation = .watermark(options)
        }
        return operation
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
    /// `userChosen`: dropped or picked in a panel, so the sandbox lets the app use those folders this session
    /// (false for scripts, services and links, which bring no such permission). Nothing is added while a run is
    /// in progress (drops, Add…, Open With and Services are all refused then).
    func add(_ urls: [URL], userChosen: Bool = true) {
        guard !urls.isEmpty, !isRunning else { return }
        if userChosen { AccessStore.shared.noteAdded(urls) }
        pendingAdds += 1
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { InputCollector.collect(urls) }.value
            guard let self else { return }
            // By file, not by item: a file added loose and again through its folder is listed once.
            var seen = Set(self.items.map(\.fileKey))
            for item in found where seen.insert(item.fileKey).inserted {
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
        compare.clear()
        resetPreview()
        cancelEstimate()
        progress = nil
        runReport = nil
        monitor.reset()
        Task { await factsCache.removeAll(); await privacy.cache.removeAll() }
    }

    func run(settings: AppSettings) {
        guard !isRunning, !isAdding, !items.isEmpty, variantsCanRun(), confirmDiscardingInterruptedRun() else { return }
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
        let batch = items, pipeline = pipeline, presetName = session.selected?.name
        Task { await startRun(batch, pipeline: pipeline, mode: mode, presetName: presetName) }
    }

    /// Runs `batch` with `pipeline` (Run, or a service, script, link or resume with its own files and preset),
    /// showing progress and the report like Run. In the sandbox it first asks for any folder the run needs that
    /// the app can't use yet (`AccessStore.ensureAccess`; `quietAccess`: the caller reports a refusal itself).
    /// `completion` gets the report.
    @discardableResult
    func startRun(_ batch: [InputItem], pipeline: Pipeline, mode: OutputMode, presetName: String?,
                  quietAccess: Bool = false,
                  completion: (@MainActor (BatchReport) -> Void)? = nil) async -> AppRunStart {
        // One item per file, so the run's event indices match this list (the runner deduplicates the same way).
        let batch = InputItem.unique(batch)
        guard !isRunning, !batch.isEmpty else { return .busy }
        guard await AccessStore.shared.ensureAccess(sources: batch.map(\.source), mode: mode, toasts: toasts,
                                                    quiet: quietAccess) else {
            return .noAccess
        }
        // The panels run a modal loop: another request may have started a run meanwhile.
        guard !isRunning else { return .busy }
        runInfo = (batch.count, Date(), mode.kind.rawValue)
        isRunning = true
        let control = BatchControl(lowMemory: lowMemoryMode)
        let presets = presetLibrary
        monitor.prepare(control: control, overwriting: mode == .overwrite)
        // The preview stays alive, at a higher priority than the batch, unless `previewAllowed` says otherwise.
        if !previewAllowed {
            resetPreview()
            cancelEstimate()
        }
        runReport = nil
        progress = BatchProgress(completed: 0, failed: 0, total: batch.count)
        interruptedRun = nil  // this run's journal replaces the old one
        // Batch work is `.utility` so the UI and the preview (`.userInitiated`) stay responsive.
        task = Task(priority: .utility) { [weak self] in
            let pixels = await Self.sourcePixels(of: batch)
            guard let events = self?.monitor.begin(sourcePixels: pixels) else { return }
            let report = await BatchRunner.run(batch, pipeline: pipeline, mode: mode, control: control,
                                               journal: AppDefaults.journalURL, presets: presets, progress: { update in
                // `.userInitiated`: inheriting the batch's `.utility` would let the bar lag behind the workers.
                Task(priority: .userInitiated) { @MainActor in
                    // Updates can arrive out of order; only move forward.
                    guard let self, self.isRunning, update.completed > (self.progress?.completed ?? 0) else { return }
                    self.progress = update
                }
            }, events: events)
            self?.finish(report, presetName: presetName)
            completion?(report)
        }
        return .started
    }

    func cancel() { task?.cancel() }

    private func finish(_ report: BatchReport, presetName: String?) {
        isRunning = false
        task = nil
        monitor.end()
        Task { await previewRenderer.purge() }
        schedulePreview(mode: previewMode)
        scheduleEstimate()
        runReport = ProcessingReport(batch: report, total: runInfo.total, outputMode: runInfo.mode,
                                     presetName: presetName, startedAt: runInfo.started)
        if let finished = runReport { recordRun(finished) }
        progress = nil
        dropMissingItems()
        let prefix = report.cancelled ? "Cancelled. " : ""
        // Failed files or failed extra outputs make it a warning.
        let (summary, hasProblems) = RunCountsText.runSummary(report)
        toasts.show("\(prefix)\(summary)", type: hasProblems ? .bad : (report.cancelled ? .info : .ok))
        runAfterRunAction(report, summary: summary)
    }
}

/// What `startRun` did.
enum AppRunStart: Equatable {
    case started
    /// A run is already going (or there was nothing to run).
    case busy
    /// Sandbox: the user didn't allow a folder the run needs (a toast said so).
    case noAccess
}

extension AppModel {
    /// Asks for files and folders to add (not while a run is in progress).
    func chooseInputs() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private static func isExistingDirectory(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
