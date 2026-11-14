import Foundation

/// Conditions in the batch: each item is resolved once, from its header, before anything is planned; copies
/// and skips then never decode.
/// One item of a dry run.
public struct PlannedFile: Equatable, Sendable {
    public let source: URL
    /// Nil when a condition skips the file.
    public let destination: URL?
    public let disposition: Disposition
}

extension BatchRunner {
    /// What a run does, item by item, once its conditions are resolved.
    struct RunPlan {
        /// One per item that isn't skipped, in input order.
        let plans: [PlannedOutput]
        /// The resolved pipeline of each plan.
        let jobs: [ResolvedPipeline]
        /// Sources a condition skipped, in input order.
        let skipped: [URL]
        /// Every image step the jobs use, so each watermark image is loaded once per batch.
        let assetPipeline: Pipeline
    }

    /// Resolves, names and plans `items`; nil when the task is cancelled part-way (nothing is written then).
    /// Skipped items take no name and no counter number, but their files stay reserved in the plan.
    static func planRun(_ items: [InputItem], pipeline: Pipeline, mode: OutputMode, maxPixels: Int) async -> RunPlan? {
        guard let resolved = await resolveAll(items, pipeline: pipeline, maxPixels: maxPixels) else { return nil }
        let active = items.indices.filter { resolved[$0].disposition != .skip }
        let jobs = active.map { resolved[$0] }
        guard let baseNames = renderedBaseNames(active.map { items[$0] }, jobs: jobs) else { return nil }
        let targets = zip(active, baseNames).map { index, name -> OutputTarget in
            resolved[index].disposition == .copyOriginal
                ? .copyOfOriginal(items[index], baseName: name)
                : OutputTarget(item: items[index], format: resolved[index].pipeline.output.format, baseName: name)
        }
        let skipped = items.indices.filter { resolved[$0].disposition == .skip }.map { items[$0].source }
        return RunPlan(plans: OutputPlanner.plan(targets, mode: mode, reservedSources: skipped), jobs: jobs,
                       skipped: skipped, assetPipeline: assetPipeline(pipeline, resolved: jobs))
    }

    /// What `run` would do with each item, without writing anything: conditions resolved, names rendered and
    /// destinations planned by the same path the batch uses. In input order; nil when the task is cancelled.
    public static func plan(_ items: [InputItem], pipeline: Pipeline, mode: OutputMode,
                            maxPixels: Int = 250_000_000) async -> [PlannedFile]? {
        guard let run = await planRun(items, pipeline: pipeline, mode: mode, maxPixels: maxPixels) else { return nil }
        var byPlan: [URL: (PlannedOutput, Disposition)] = [:]
        for (plan, job) in zip(run.plans, run.jobs) { byPlan[plan.item.source] = (plan, job.disposition) }
        return items.map { item in
            if let (plan, disposition) = byPlan[item.source] {
                return PlannedFile(source: item.source, destination: plan.destination, disposition: disposition)
            }
            return PlannedFile(source: item.source, destination: nil, disposition: .skip)
        }
    }

    /// Runs one planned item: a copy of the original, or the full load, apply, encode and commit.
    static func process(_ plan: PlannedOutput, job: ResolvedPipeline, assets: WatermarkAssets, maxPixels: Int,
                        trash: Trasher) -> (Result<WrittenItem?, ConversionError>, Int?) {
        if job.disposition == .copyOriginal { return copyOriginal(plan, trash: trash) }
        // A watermark image that can't be read fails every file using it, before its source is decoded.
        if let missing = assets.missingError(for: job.pipeline) {
            return (.failure(missing), fileSize(plan.item.source))
        }
        return convert(plan, pipeline: job.pipeline, assets: assets, maxPixels: maxPixels, trash: trash)
    }

    /// How many files' facts are read at once (header reads and small scans are mostly I/O).
    static let factReaders = 4

    /// Each item's pipeline with its conditions resolved, from header-only facts (plus a small alpha scan when a
    /// condition asks about transparency), read a few at a time and returned in input order. Nil when the task
    /// is cancelled part-way.
    static func resolveAll(_ items: [InputItem], pipeline: Pipeline, maxPixels: Int) async -> [ResolvedPipeline]? {
        guard pipeline.hasConditions else {
            let plain = ResolvedPipeline(pipeline: pipeline.withoutConditions)
            return items.map { _ in plain }
        }
        var resolved = [ResolvedPipeline?](repeating: nil, count: items.count)
        let finished = await withTaskGroup(of: (Int, ResolvedPipeline).self) { group -> Bool in
            var next = 0
            func startNext() {
                let index = next
                let url = items[index].source
                next += 1
                group.addTask { (index, pipeline.resolved(forSource: url, maxPixels: maxPixels)) }
            }
            while next < min(items.count, factReaders) { startNext() }
            while let (index, result) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return false
                }
                resolved[index] = result
                if next < items.count { startNext() }
            }
            return !Task.isCancelled
        }
        guard finished else { return nil }
        return resolved.compactMap { $0 }
    }

    /// One pipeline holding every image step the items use, so each watermark image is loaded once per batch.
    private static func assetPipeline(_ pipeline: Pipeline, resolved: [ResolvedPipeline]) -> Pipeline {
        guard pipeline.hasConditions else { return pipeline }
        var union = pipeline
        var seen = Set<UUID>()
        union.steps = resolved.filter { $0.disposition == .process }.flatMap(\.pipeline.steps)
            .filter { seen.insert($0.id).inserted }
        return union
    }

    /// Renders each item's rename template, serially in input order (the counter depends on it); an item whose
    /// pipeline doesn't rename gets nil. Nil when the task is cancelled part-way (nothing is written then).
    /// The header and creation date are only read when the template uses them.
    private static func renderedBaseNames(_ items: [InputItem], jobs: [ResolvedPipeline]) -> [String?]? {
        var names: [String?] = []
        names.reserveCapacity(items.count)
        for (index, (item, job)) in zip(items, jobs).enumerated() {
            guard job.pipeline.rename.isActive else {
                names.append(nil)
                continue
            }
            if Task.isCancelled { return nil }
            guard let name = RenameRendering.baseName(for: item, index: index, pipeline: job.pipeline,
                                                      isCopy: job.disposition == .copyOriginal) else { return nil }
            names.append(name)
        }
        return names
    }

    /// Writes the source's bytes unchanged (no decode) through the same atomic commit. Overwrite mode plans
    /// the copy in place, where the file already is its own copy: nothing is written.
    private static func copyOriginal(_ plan: PlannedOutput, trash: Trasher) -> (Result<WrittenItem?, ConversionError>, Int?) {
        let inputBytes = fileSize(plan.item.source)
        let note = ConditionalStep.copiedNote
        if plan.replacesSource {
            return (.success(WrittenItem(url: plan.destination, note: note, inputBytes: inputBytes,
                                         outputBytes: inputBytes ?? 0)), inputBytes)
        }
        return (autoreleasepool { () -> Result<WrittenItem?, ConversionError> in
            do {
                let data: Data
                do { data = try Data(contentsOf: plan.item.source, options: .mappedIfSafe) } catch {
                    return .failure(.unreadable)
                }
                try FileCommitter.commit(data, for: plan, trash: trash)
                return .success(WrittenItem(url: plan.destination, note: note, inputBytes: inputBytes,
                                            outputBytes: data.count))
            } catch let error as ConversionError {
                return .failure(error)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }, inputBytes)
    }
}

extension BatchReport {
    /// Adds the skipped files and puts them into `order` at their input positions.
    func insertingSkipped(_ sources: [URL], inputOrder: [URL]) -> BatchReport {
        guard !sources.isEmpty else { return self }
        var report = self
        report.insertSkipped(sources, inputOrder: inputOrder)
        return report
    }

    private mutating func insertSkipped(_ sources: [URL], inputOrder: [URL]) {
        skipped = sources.map { BatchSkip(source: $0, inputBytes: BatchRunner.fileSize($0)) }
        let listed = Set(order).union(sources)
        order = inputOrder.filter { listed.contains($0) }
    }
}
