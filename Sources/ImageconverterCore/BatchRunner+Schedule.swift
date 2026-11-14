import Foundation

extension BatchRunner {
    /// Added to the note of a file that failed once and was written by the end-of-batch retry.
    static let retriedNote = "Succeeded on retry"

    /// `run` with test seams (`hooks`); the public `run` passes the live system state.
    static func run(
        _ items: [InputItem], pipeline: Pipeline, mode: OutputMode, maxPixels: Int = 250_000_000,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryBudgetPixels: Int = BatchRunner.defaultMemoryBudgetPixels, trash: @escaping Trasher = systemTrash,
        control: BatchControl? = nil, journal: URL? = nil, hooks: BatchHooks,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in },
        events: @escaping @Sendable (ItemEvent) -> Void = { _ in }
    ) async -> BatchReport {
        let writer = journal.map {
            RunJournalWriter(url: $0, journal: RunJournal(items: items, pipeline: pipeline, mode: mode))
        }
        writer?.writeNow()
        // A normal finish and a cancel both end here; only a crash or a forced quit leaves the journal.
        defer { writer?.remove() }
        StaleTempFiles.remove(in: StaleTempFiles.folders(for: items, mode: mode))
        guard let plan = await planRun(items, pipeline: pipeline, mode: mode, maxPixels: maxPixels), !Task.isCancelled
        else { return BatchReport(cancelled: true) }

        announce(plan, items: items, events: events, writer: writer)
        if !plan.skipped.isEmpty {
            progress(BatchProgress(completed: plan.skipped.count, failed: 0, total: items.count))
        }
        let settings = BatchScheduler.Settings(
            total: items.count, maxPixels: maxPixels, concurrency: concurrency, budget: memoryBudgetPixels,
            trash: trash, control: control, hooks: hooks, progress: progress, events: events)
        let scheduler = BatchScheduler(plan: plan, settings: settings, writer: writer)
        await scheduler.execute()
        return makeReport(plans: plan.plans, outcomes: scheduler.outcomes, inputSizes: scheduler.inputSizes,
                          cancelled: scheduler.cancelled,
                          durations: scheduler.durations)
            .insertingSkipped(plan.skipped, inputOrder: items.map(\.source))
    }

    /// The first event of every item, in input order: skipped ones are done at once, the rest queued.
    private static func announce(_ plan: RunPlan, items: [InputItem], events: (ItemEvent) -> Void,
                                 writer: RunJournalWriter?) {
        var stages = [ItemEvent.Stage?](repeating: nil, count: items.count)
        for index in plan.skippedIndices { stages[index] = .skipped }
        for index in plan.planIndices { stages[index] = .queued }
        for (index, stage) in stages.enumerated() {
            guard let stage else { continue }
            let source = items[index].source
            events(ItemEvent(index: index, source: source, stage: stage,
                             inputBytes: stage == .skipped ? fileSize(source) : nil))
            if stage == .skipped { writer?.markCompleted(index) }
        }
    }
}

/// What a worker hands back for one item.
struct WorkerResult: Sendable {
    let index: Int
    let result: Result<WrittenItem?, ConversionError>
    let inputBytes: Int?
    let duration: TimeInterval
}

/// Runs a planned batch: admission by count and memory, limits that adapt between items, pause, priorities,
/// the end-of-batch retry, events, progress and the journal. Used from one task only (the run's).
final class BatchScheduler {
    struct Settings {
        let total: Int
        let maxPixels: Int
        let concurrency: Int
        let budget: Int
        let trash: Trasher
        let control: BatchControl?
        let hooks: BatchHooks
        let progress: @Sendable (BatchProgress) -> Void
        let events: @Sendable (ItemEvent) -> Void
    }

    private let plan: BatchRunner.RunPlan
    private let settings: Settings
    private let writer: RunJournalWriter?
    private let assets: WatermarkAssets
    private let monitor: MemoryPressureMonitor?

    private(set) var outcomes: [Result<WrittenItem?, ConversionError>?]
    private(set) var inputSizes: [Int?]
    /// Seconds each plan's last attempt took.
    private(set) var durations: [TimeInterval]
    private(set) var cancelled = false

    /// Plan indices in the order they start; `head` is the next one.
    private var queue: [Int]
    private var head = 0
    private var retryQueue: [Int] = []
    private var retrying = false
    private var attempts: [Int]
    private var finished: [Bool]
    private var weights: [Int?]
    private var window: WorkWindow
    private var completed: Int
    private var failed = 0

    init(plan: BatchRunner.RunPlan, settings: Settings, writer: RunJournalWriter?) {
        self.plan = plan
        self.settings = settings
        self.writer = writer
        let count = plan.plans.count
        assets = WatermarkAssets.load(for: plan.assetPipeline, maxPixels: settings.maxPixels)
        monitor = settings.hooks.memoryPressure == nil ? MemoryPressureMonitor() : nil
        outcomes = Array(repeating: nil, count: count)
        inputSizes = Array(repeating: nil, count: count)
        durations = Array(repeating: 0, count: count)
        queue = Array(0..<count)
        attempts = Array(repeating: 0, count: count)
        finished = Array(repeating: false, count: count)
        weights = Array(repeating: nil, count: count)
        window = WorkWindow(maxItems: max(1, settings.concurrency), maxWeight: settings.budget)
        completed = plan.skipped.count
    }

    func execute() async {
        await withTaskGroup(of: WorkerResult.self) { group in
            var inFlight = 0
            while true {
                applyPriorities()
                beginRetryIfReady(inFlight: inFlight)
                inFlight += startItems(in: &group)
                if inFlight == 0 {
                    if cancelled { break }
                    // Items are waiting but none could start: the batch is paused.
                    if head < queue.count {
                        await settings.control?.waitWhilePaused()
                        continue
                    }
                    if retryQueue.isEmpty { break }
                    continue
                }
                guard let result = await group.next() else { break }
                inFlight -= 1
                window.finish(weight: weights[result.index] ?? 1)
                handle(result)
            }
        }
        // Every item ends with a final event, also when the run stopped before it.
        for index in finished.indices where !finished[index] {
            if case .failure(let error) = outcomes[index] {
                emit(index, .failed(error.reason), inputBytes: inputSizes[index])
            } else {
                emit(index, .cancelled)
            }
        }
    }

    // MARK: Starting items

    private func startItems(in group: inout TaskGroup<WorkerResult>) -> Int {
        var started = 0
        while head < queue.count {
            if Task.isCancelled {
                cancelled = true
                break
            }
            if settings.control?.isPaused == true { break }
            let lowMemory = retrying || settings.control?.isLowMemory == true
            let conditions = BatchConditions(thermal: settings.hooks.thermalState(), pressure: memoryPressure,
                                             lowMemory: lowMemory, retrying: retrying)
            let limits = BatchLimits.effective(concurrency: settings.concurrency, budget: settings.budget,
                                               conditions: conditions)
            window.setLimits(maxItems: limits.maxItems, maxWeight: limits.maxWeight)
            let index = queue[head]
            let weight = weight(of: index)
            guard window.canStart(weight: weight) else { break }
            head += 1
            window.start(weight: weight)
            attempts[index] += 1
            launch(index, lowMemory: lowMemory, in: &group)
            started += 1
        }
        if cancelled {
            head = queue.count
            retryQueue = []
        }
        return started
    }

    private var memoryPressure: MemoryPressure {
        settings.hooks.memoryPressure?() ?? monitor?.current ?? .normal
    }

    /// Read once per item (a header read), not each time the window is asked.
    private func weight(of index: Int) -> Int {
        if let known = weights[index] { return known }
        let job = plan.jobs[index]
        let weight = job.disposition == .process ? BatchRunner.weight(of: plan.plans[index], pipeline: job.pipeline) : 1
        weights[index] = weight
        return weight
    }

    private func launch(_ index: Int, lowMemory: Bool, in group: inout TaskGroup<WorkerResult>) {
        let planned = plan.plans[index]
        let job = plan.jobs[index]
        let inputIndex = plan.planIndices[index]
        let source = planned.item.source
        let (assets, maxPixels, trash, events) = (assets, settings.maxPixels, settings.trash, settings.events)
        let hook = settings.hooks.beforeEncode
        let attempt = attempts[index]
        group.addTask {
            let started = Date()
            let options = ItemRunOptions(downsample: true, lowMemory: lowMemory, attempt: attempt, beforeEncode: hook,
                                         stage: { events(ItemEvent(index: inputIndex, source: source, stage: $0)) })
            let outcome = BatchRunner.process(planned, job: job, assets: assets, maxPixels: maxPixels, trash: trash,
                                              options: options)
            return WorkerResult(index: index, result: outcome.0, inputBytes: outcome.1,
                                duration: Date().timeIntervalSince(started))
        }
    }

    // MARK: Queue order

    /// Moves waiting items whose source was asked for to the front, in the order asked.
    private func applyPriorities() {
        guard let control = settings.control else { return }
        for request in control.takePriorityRequests() {
            var rank: [String: Int] = [:]
            for (position, url) in request.enumerated() where rank[key(url)] == nil { rank[key(url)] = position }
            let waiting = Array(queue[head...])
            let rankOf = { (index: Int) in rank[self.key(self.plan.plans[index].item.source)] }
            let moved = waiting.filter { rankOf($0) != nil }.enumerated().sorted { lhs, rhs in
                let (left, right) = (rankOf(lhs.element) ?? 0, rankOf(rhs.element) ?? 0)
                return left != right ? left < right : lhs.offset < rhs.offset
            }.map(\.element)
            guard !moved.isEmpty else { continue }
            let movedSet = Set(moved)
            queue = Array(queue[..<head]) + moved + waiting.filter { !movedSet.contains($0) }
        }
    }

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Once everything else is done, the items that failed in a way worth retrying run again, one at a time.
    private func beginRetryIfReady(inFlight: Int) {
        guard !cancelled, inFlight == 0, head == queue.count, !retryQueue.isEmpty else { return }
        queue = retryQueue
        head = 0
        retryQueue = []
        retrying = true
    }

    // MARK: Results

    private func handle(_ result: WorkerResult) {
        let index = result.index
        inputSizes[index] = result.inputBytes
        durations[index] = result.duration
        switch result.result {
        case .success(nil):
            // Cancelled during its compression search: nothing written. A retry keeps its first failure.
            cancelled = true
        case .success(let item?):
            let written = attempts[index] > 1 ? item.addingNote(BatchRunner.retriedNote) : item
            outcomes[index] = .success(written)
            finish(index, .done, result: result, outputBytes: written.outputBytes)
            writer?.markCompleted(plan.planIndices[index])
        case .failure(let error):
            outcomes[index] = .failure(error)
            if attempts[index] == 1, error.isRetryable {
                retryQueue.append(index)
                emit(index, .queued)
                return
            }
            failed += 1
            finish(index, .failed(error.reason), result: result, outputBytes: nil)
        }
    }

    private func finish(_ index: Int, _ stage: ItemEvent.Stage, result: WorkerResult, outputBytes: Int?) {
        finished[index] = true
        completed += 1
        emit(index, stage, inputBytes: result.inputBytes, outputBytes: outputBytes, duration: result.duration)
        settings.progress(BatchProgress(completed: completed, failed: failed, total: settings.total))
    }

    private func emit(_ index: Int, _ stage: ItemEvent.Stage, inputBytes: Int? = nil, outputBytes: Int? = nil,
                      duration: TimeInterval? = nil) {
        settings.events(ItemEvent(index: plan.planIndices[index], source: plan.plans[index].item.source, stage: stage,
                                  inputBytes: inputBytes, outputBytes: outputBytes, duration: duration))
    }
}

extension WrittenItem {
    func addingNote(_ text: String) -> WrittenItem {
        var copy = self
        copy.note = [note, text].compactMap { $0 }.joined(separator: "; ")
        return copy
    }
}
