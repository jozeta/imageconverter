import Foundation
import Observation
import ImageconverterCore

/// Live state of the running batch for the progress line, the performance panel, the list and the thumbnail
/// rings: each item's stage, throughput and ETA, CPU and memory. Kept after a run until the next one or Clear.
@MainActor @Observable
final class RunMonitor {
    /// Seconds between CPU/memory samples and ETA refreshes; nothing is sampled while no batch runs.
    static let sampleInterval = Duration.seconds(1)
    /// Stage changes reach the views at most this often (a fast batch sends thousands of events a second).
    static let stageFlushInterval = Duration.milliseconds(100)

    private(set) var isPaused = false
    private(set) var isActive = false
    /// The run replaces its originals: the preview and estimate stay off until it ends (they'd read files
    /// that are being replaced or moved to the Trash).
    private(set) var overwriting = false
    /// Throughput and ETA, refreshed every second while running; the final one after the run.
    private(set) var snapshot: RunMetrics.Snapshot?
    private(set) var resources: ResourceSampler.Sample?
    private(set) var workersInUse = 0
    private(set) var peakMemory: UInt64 = 0
    private(set) var averageCPU: Double?
    /// Megapixels of the items written so far (published with the stages, at most 10 times a second).
    private(set) var megapixelsDone = 0.0
    @ObservationIgnored private var pendingMegapixels = 0.0
    /// Stops while paused, so the rate, ETA and elapsed time leave pauses out.
    @ObservationIgnored private var clock = PausableClock()
    /// Bumped when stages changed, so views that read `stage(for:)` refresh.
    private(set) var stageTick = 0
    /// The Performance disclosure.
    var expanded = false

    @ObservationIgnored private(set) var control: BatchControl?
    @ObservationIgnored private var tracker = ItemStageTracker()
    @ObservationIgnored private var metrics: RunMetrics?
    @ObservationIgnored private var pixels: [Int] = []
    @ObservationIgnored private var cpuSamples = (sum: 0.0, count: 0)
    @ObservationIgnored private var continuation: AsyncStream<ItemEvent>.Continuation?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var flushPending = false
    /// Bumped by every reset, so a late `end` of an earlier run can't touch the next one.
    @ObservationIgnored private var generation = 0

    /// True when there is something to show (a run is going or finished since the last reset).
    var hasResults: Bool { snapshot != nil || isActive }

    func stage(for source: URL) -> ItemStage? {
        _ = stageTick
        return tracker.stage(for: source)
    }

    /// Forgets the last run (new run, Clear).
    func reset() {
        generation += 1
        stop()
        tracker = ItemStageTracker()
        metrics = nil
        snapshot = nil
        resources = nil
        workersInUse = 0
        peakMemory = 0
        averageCPU = nil
        megapixelsDone = 0
        pendingMegapixels = 0
        overwriting = false
        clock = PausableClock()
        cpuSamples = (0, 0)
        isPaused = false
        control = nil
        stageTick += 1
    }

    /// A new run with `control`; `begin` follows once the source sizes are known.
    func prepare(control: BatchControl, overwriting: Bool) {
        reset()
        self.control = control
        self.overwriting = overwriting
        isActive = true
    }

    /// Starts the clock and the sampling; returns the batch's event sink. `sourcePixels[i]` is item i's size.
    func begin(sourcePixels: [Int]) -> @Sendable (ItemEvent) -> Void {
        pixels = sourcePixels
        let clock = self.clock
        metrics = RunMetrics(sourcePixels: sourcePixels) { clock.now() }
        snapshot = metrics?.snapshot()
        // A stream keeps the order of one item's events, which separate main-actor tasks wouldn't promise.
        let (stream, continuation) = AsyncStream<ItemEvent>.makeStream()
        self.continuation = continuation
        // Explicit priorities: created from the batch's `.utility` task, these would inherit its priority and
        // wait behind the workers; the UI's numbers must not.
        eventTask = Task(priority: .userInitiated) { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        let sampler = ResourceSampler()
        samplingTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard !Task.isCancelled, let self else { return }
                // Three task_info calls: microseconds, fine on the main actor.
                self.record(sampler.sample())
            }
        }
        return { continuation.yield($0) }
    }

    /// The run returned: handle the events still queued, then freeze the final numbers.
    func end() {
        continuation?.finish()
        continuation = nil
        samplingTask?.cancel()
        samplingTask = nil
        let pending = eventTask
        let run = generation
        Task { [weak self] in
            await pending?.value
            guard let self, run == generation else { return }
            tracker.finishRun()
            workersInUse = 0
            megapixelsDone = pendingMegapixels
            snapshot = metrics?.snapshot()
            isActive = false
            isPaused = false
            control = nil
            stageTick += 1
        }
    }

    func setPaused(_ paused: Bool) {
        guard let control else { return }
        if paused {
            control.pause()
            clock.pause()
        } else {
            control.resume()
            clock.resume()
        }
        isPaused = paused
    }

    private func stop() {
        continuation?.finish()
        continuation = nil
        eventTask?.cancel()
        eventTask = nil
        samplingTask?.cancel()
        samplingTask = nil
        isActive = false
    }

    private func handle(_ event: ItemEvent) {
        tracker.record(event)
        metrics?.record(event)
        if event.stage == .done, pixels.indices.contains(event.index) {
            pendingMegapixels += Double(pixels[event.index]) / 1_000_000
        }
        guard !flushPending else { return }
        flushPending = true
        Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: Self.stageFlushInterval)
            guard let self else { return }
            flushPending = false
            workersInUse = tracker.workersInUse
            megapixelsDone = pendingMegapixels
            stageTick += 1
        }
    }

    private func record(_ sample: ResourceSampler.Sample?) {
        guard isActive else { return }
        snapshot = metrics?.snapshot()
        guard let sample else { return }
        resources = sample
        peakMemory = max(peakMemory, sample.memoryBytes)
        cpuSamples.sum += sample.cpuPercent
        cpuSamples.count += 1
        averageCPU = cpuSamples.sum / Double(cpuSamples.count)
    }
}
