import Foundation

/// Conditions in the batch: each item is resolved once, from its header, before anything is planned; copies
/// and skips then never decode.
/// One item of a dry run.
public struct PlannedFile: Equatable, Sendable {
    public let source: URL
    /// Nil when a condition skips the file.
    public let destination: URL?
    public let disposition: Disposition
    /// Overwrite mode: the original is replaced in place.
    public var replacesSource = false
    /// Overwrite mode: the result has a new name or format, and the original goes to the Trash once it is saved.
    public var trashesSource = false
    /// The item's extra outputs, each a new file.
    public var variants: [PlannedVariant] = []
}

extension BatchRunner {
    /// What a run does, item by item, once its conditions are resolved.
    struct RunPlan {
        /// One per item that isn't skipped, in input order.
        let plans: [PlannedOutput]
        /// The resolved pipeline of each plan.
        let jobs: [ResolvedPipeline]
        /// The extra outputs of each plan (empty for copies, skipped extras and refused plans).
        var variants: [[PlannedVariant]] = []
        /// Sources a condition skipped or another run holds, in input order, with the reason for each.
        let skipped: [URL]
        let skipReasons: [String]
        /// The input indices of the sources another run holds.
        let busyIndices: Set<Int>
        /// The input index of each plan, and of each skipped source.
        let planIndices: [Int]
        let skippedIndices: [Int]
        /// Every image step the jobs use, so each watermark image is loaded once per batch.
        let assetPipeline: Pipeline
    }

    /// Resolves, names and plans `items`; nil when the task is cancelled part-way (nothing is written then).
    /// Skipped items take no name and no counter number, but their files stay reserved in the plan. Items whose
    /// `fileKey` is in `busy` (held by another run) are skipped with `ActiveSources.busyReason`.
    static func planRun(_ items: [InputItem], pipeline: Pipeline, mode: OutputMode, maxPixels: Int,
                        busy: Set<String> = [], presets: PresetLibrary = .standard,
                        analysis: ImageAnalysisCache = .shared) async -> RunPlan? {
        guard var resolved = await resolveAll(items, pipeline: pipeline, maxPixels: maxPixels, presets: presets,
                                              analysis: analysis)
        else { return nil }
        noteNewerSystemOnce(&resolved)
        let busyIndices = Set(items.indices.filter { busy.contains(items[$0].fileKey) })
        for index in busyIndices {
            resolved[index] = ResolvedPipeline(pipeline: pipeline.withoutConditions, disposition: .skip,
                                               notes: [ActiveSources.busyReason])
        }
        let active = items.indices.filter { resolved[$0].disposition != .skip }
        var jobs = active.map { resolved[$0] }
        guard let (baseNames, slowNames) = renderedBaseNames(active.map { items[$0] }, jobs: jobs),
              let extras = renderedExtras(active.map { items[$0] }, jobs: jobs) else { return nil }
        for index in jobs.indices {
            if slowNames.contains(index), !jobs[index].notes.contains(BoundedRegex.timeoutNote) {
                jobs[index].notes.append(BoundedRegex.timeoutNote)
            }
            jobs[index].notes += extras[index].notes
            if mode == .overwrite, jobs[index].subfolder != nil { jobs[index].notes.append(Self.subfolderIgnoredNote) }
        }
        let targets = active.indices.map { position -> OutputTarget in
            let (index, name, folder) = (active[position], baseNames[position], extras[position].subfolder)
            return resolved[index].disposition == .copyOriginal
                ? .copyOfOriginal(items[index], baseName: name, subfolder: folder)
                : OutputTarget(item: items[index], format: resolved[index].pipeline.output.format, baseName: name,
                               subfolder: folder)
        }
        let skippedIndices = items.indices.filter { resolved[$0].disposition == .skip }
        let skipped = skippedIndices.map { items[$0].source }
        guard let reasons = skipReasons(skippedIndices, items: items, resolved: resolved, busy: busyIndices) else {
            return nil
        }
        let primaries = OutputPlanner.plan(targets, mode: mode, reservedSources: skipped)
        guard let variants = plannedVariants(active.map { items[$0] }, jobs: &jobs, baseNames: baseNames,
                                             primaries: primaries, reserved: skipped) else { return nil }
        var run = RunPlan(plans: primaries, jobs: jobs, skipped: skipped, skipReasons: reasons,
                          busyIndices: busyIndices, planIndices: active, skippedIndices: skippedIndices,
                          assetPipeline: assetPipeline(pipeline, resolved: jobs))
        run.variants = variants
        return run
    }

    /// Each plan's extra outputs, named like its primary output (`OutputPlanner.planVariants`). Outputs that
    /// can't run or found no free name are left out with a note on the item. Nil when cancelled part-way.
    private static func plannedVariants(_ items: [InputItem], jobs: inout [ResolvedPipeline], baseNames: [String?],
                                        primaries: [PlannedOutput], reserved: [URL]) -> [[PlannedVariant]]? {
        guard jobs.contains(where: { !$0.pipeline.extraOutputs.isEmpty }) else { return jobs.map { _ in [] } }
        var targets: [VariantTarget] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled { return nil }
            let (kept, notes) = OutputVariant.validated(jobs[index].pipeline.extraOutputs)
            jobs[index].pipeline.extraOutputs = kept
            jobs[index].notes += notes
            targets.append(VariantTarget(variants: kept, baseName: baseNames[index],
                                         subfolders: RenameRendering.variantFolders(for: item, index: index,
                                                                                    job: jobs[index])))
        }
        let (plans, failures) = OutputPlanner.planVariants(targets, primaries: primaries, reservedSources: reserved)
        for (index, missing) in failures.enumerated() {
            jobs[index].notes += missing.map { noFreeNameNote($0.displayName) }
            jobs[index].unplannedOutputs = missing.map(\.displayName)
        }
        return plans
    }

    /// The note when an extra output found no free name (it isn't written; the item is).
    static func noFreeNameNote(_ name: String) -> String {
        "Extra output “\(name)” not written: \(OutputPlanner.noFreeNameReason.lowercased())"
    }

    /// The report note when a "Save into subfolder" action meets overwrite mode.
    public static let subfolderIgnoredNote = "Subfolder ignored when overwriting originals"

    /// "Skipped by a condition", then the item's notes (a missing preset, "Add a note" lines); another run's
    /// hold is its own reason. Nil when cancelled part-way.
    private static func skipReasons(_ indices: [Int], items: [InputItem], resolved: [ResolvedPipeline],
                                    busy: Set<Int>) -> [String]? {
        var reasons: [String] = []
        for index in indices {
            if Task.isCancelled { return nil }
            if busy.contains(index) {
                reasons.append(ActiveSources.busyReason)
                continue
            }
            let notes = RenameRendering.extras(for: items[index], index: 0, job: resolved[index]).notes
            reasons.append(([ConditionalStep.skippedReason] + resolved[index].notes + notes).joined(separator: "; "))
        }
        return reasons
    }

    /// Each item's rendered subfolder and notes, in input order (the counter as for its name). Nil when
    /// cancelled part-way.
    private static func renderedExtras(_ items: [InputItem], jobs: [ResolvedPipeline])
        -> [(subfolder: [String], notes: [String])]? {
        var extras: [(subfolder: [String], notes: [String])] = []
        extras.reserveCapacity(items.count)
        for (index, (item, job)) in zip(items, jobs).enumerated() {
            if job.subfolder != nil || !job.noteTemplates.isEmpty, Task.isCancelled { return nil }
            extras.append(RenameRendering.extras(for: item, index: index, job: job))
        }
        return extras
    }

    /// What `run` would do with each item, without writing anything: conditions resolved, names rendered and
    /// destinations planned by the same path the batch uses. In input order; nil when the task is cancelled.
    public static func plan(_ items: [InputItem], pipeline: Pipeline, mode: OutputMode,
                            maxPixels: Int = 250_000_000, presets: PresetLibrary = .standard,
                            analysis: ImageAnalysisCache = .shared) async -> [PlannedFile]? {
        let items = InputItem.unique(items)
        guard let run = await planRun(items, pipeline: pipeline, mode: mode, maxPixels: maxPixels, presets: presets,
                                      analysis: analysis)
        else { return nil }
        var byPlan: [URL: PlannedFile] = [:]
        for (index, (plan, job)) in zip(run.plans, run.jobs).enumerated() {
            byPlan[plan.item.source] = PlannedFile(
                source: plan.item.source, destination: plan.destination, disposition: job.disposition,
                replacesSource: plan.replacesSource, trashesSource: plan.trashesSource,
                variants: index < run.variants.count ? run.variants[index] : [])
        }
        return items.map { item in
            if let file = byPlan[item.source] { return file }
            return PlannedFile(source: item.source, destination: nil, disposition: .skip)
        }
    }

    /// Runs one planned item: a copy of the original, or the full load, apply, encode and commit.
    static func process(_ plan: PlannedOutput, job: ResolvedPipeline, assets: WatermarkAssets, maxPixels: Int,
                        trash: Trasher, options: ItemRunOptions = ItemRunOptions(), variants: [PlannedVariant] = [])
        -> (Result<WrittenItem?, ConversionError>, Int?) {
        // Refused by the planner (a second plan for one original, or no free name): fail before anything is read
        // or written.
        if plan.isRefused {
            return (.failure(.writeFailed(plan.failureReason ?? "Invalid output plan")), fileSize(plan.item.source))
        }
        if job.disposition == .copyOriginal {
            options.stage(.writing)
            // Overwrite mode leaves the original as it is: an untouched original is never tagged.
            guard !plan.replacesSource || job.finderTags.isEmpty else {
                return flagged(copyOriginal(plan, trash: trash, notes: job.notes + [FinderTags.untouchedNote]),
                               job.warning)
            }
            return flagged(tagged(copyOriginal(plan, trash: trash, notes: job.notes), tags: job.finderTags), job.warning)
        }
        // A watermark image that can't be read fails every file using it, before its source is decoded.
        if let missing = assets.missingError(for: job.pipeline) {
            return (.failure(missing), fileSize(plan.item.source))
        }
        var (result, inputBytes) = convert(plan, pipeline: job.pipeline, assets: assets, maxPixels: maxPixels,
                                           trash: trash, options: options, variants: variants)
        if !job.unplannedOutputs.isEmpty, case .success(var written?) = result {
            // Named in the item's note already (`noFreeNameNote`); counted as failed extras too.
            written.extraFailures += job.unplannedOutputs.map {
                BatchExtraFailure(source: plan.item.source, name: $0, destination: nil,
                                  reason: OutputPlanner.noFreeNameReason)
            }
            result = .success(written)
        }
        let resolutionNotes = job.runNotes
        guard !resolutionNotes.isEmpty, case .success(var written?) = result else {
            return flagged(tagged((result, inputBytes), tags: job.finderTags), job.warning)
        }
        // How the item was resolved comes first, then the step and encoder notes.
        written.note = (resolutionNotes + [written.note].compactMap { $0 }).joined(separator: "; ")
        return flagged(tagged((.success(written), inputBytes), tags: job.finderTags), job.warning)
    }

    /// Marks a written item as a warning when its resolution said so (`ResolvedPipeline.warning`).
    private static func flagged(_ outcome: (Result<WrittenItem?, ConversionError>, Int?), _ warning: Bool)
        -> (Result<WrittenItem?, ConversionError>, Int?) {
        guard warning, case .success(var written?) = outcome.0 else { return outcome }
        written.warning = true
        return (.success(written), outcome.1)
    }

    /// Adds the Finder tags to a written file; a failure is a note, not a failed file.
    private static func tagged(_ outcome: (Result<WrittenItem?, ConversionError>, Int?), tags: [String])
        -> (Result<WrittenItem?, ConversionError>, Int?) {
        guard !tags.isEmpty, case .success(var written?) = outcome.0 else { return outcome }
        let tagged = [written.url] + written.extras.map(\.url)
        if !tagged.allSatisfy({ FinderTags.add(tags, to: $0) }) {
            written.note = ([written.note].compactMap { $0 } + [FinderTags.failedNote]).joined(separator: "; ")
        }
        return (.success(written), outcome.1)
    }

    /// How many files' facts are read at once (header reads and small scans are mostly I/O).
    static let factReaders = 4

    /// Each item's pipeline with its conditions resolved, from header-only facts (plus a small alpha scan when a
    /// condition asks about transparency), read a few at a time and returned in input order. Nil when the task
    /// is cancelled part-way.
    static func resolveAll(_ items: [InputItem], pipeline: Pipeline, maxPixels: Int, presets: PresetLibrary = .standard,
                           analysis: ImageAnalysisCache = .shared) async -> [ResolvedPipeline]? {
        guard pipeline.needsFacts else {
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
                group.addTask {
                    (index, pipeline.resolved(forSource: url, maxPixels: maxPixels, presets: presets, analysis: analysis))
                }
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

    /// The "needs macOS 15" note is about the Mac, not the file: only the first item that has it keeps it.
    static func noteNewerSystemOnce(_ resolved: inout [ResolvedPipeline]) {
        let note = ImageAnalysis.needsNewerSystemNote
        guard let first = resolved.firstIndex(where: { $0.notes.contains(note) }) else { return }
        for index in resolved.indices where index != first { resolved[index].notes.removeAll { $0 == note } }
    }

    /// One pipeline holding every image-watermark step the items use, once per image path and bookmark (not per
    /// step id: steps a preset brings keep the preset's ids, which can repeat with another image), so each watermark
    /// image is loaded once per batch, through whichever of its bookmarks opens it (`WatermarkAssets.load`).
    static func assetPipeline(_ pipeline: Pipeline, resolved: [ResolvedPipeline]) -> Pipeline {
        guard pipeline.hasConditions else { return pipeline }
        var union = pipeline
        var seen = Set<WatermarkAssets.Key>()
        union.steps = resolved.filter { $0.disposition == .process }.flatMap(\.pipeline.steps).filter { step in
            guard step.isEnabled, case .watermark(let options) = step.operation,
                  case .image(let watermark) = options.content else { return false }
            return seen.insert(WatermarkAssets.Key(watermark)).inserted
        }
        return union
    }

    /// Renders each item's rename template, serially in input order (the counter depends on it); an item whose
    /// pipeline doesn't rename gets nil. Nil when the task is cancelled part-way (nothing is written then).
    /// The header and creation date are only read when the template uses them.
    /// Also returns the positions whose find-and-replace pattern was stopped for taking too long.
    private static func renderedBaseNames(_ items: [InputItem], jobs: [ResolvedPipeline]) -> ([String?], Set<Int>)? {
        var names: [String?] = []
        var slow = Set<Int>()
        names.reserveCapacity(items.count)
        for (index, (item, job)) in zip(items, jobs).enumerated() {
            guard job.pipeline.rename.isActive else {
                names.append(nil)
                continue
            }
            if Task.isCancelled { return nil }
            guard let rendered = RenameRendering.checkedBaseName(for: item, index: index, pipeline: job.pipeline,
                                                                 isCopy: job.disposition == .copyOriginal,
                                                                 labels: job.labels)
            else { return nil }
            names.append(rendered.name)
            if rendered.timedOut { slow.insert(index) }
        }
        return (names, slow)
    }

    /// Writes the source's bytes unchanged (no decode) through the same atomic commit. Overwrite mode plans
    /// the copy in place, where the file already is its own copy: nothing is written.
    private static func copyOriginal(_ plan: PlannedOutput, trash: Trasher, notes: [String] = [])
        -> (Result<WrittenItem?, ConversionError>, Int?) {
        let inputBytes = fileSize(plan.item.source)
        let note = ([ConditionalStep.copiedNote] + notes).joined(separator: "; ")
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
    /// Adds the skipped files (each with its reason) and puts them into `order` at their input positions.
    func insertingSkipped(_ sources: [URL], reasons: [String], inputOrder: [URL]) -> BatchReport {
        guard !sources.isEmpty else { return self }
        var report = self
        report.insertSkipped(sources, reasons: reasons, inputOrder: inputOrder)
        return report
    }

    private mutating func insertSkipped(_ sources: [URL], reasons: [String], inputOrder: [URL]) {
        skipped = zip(sources, reasons).map { BatchSkip(source: $0, reason: $1, inputBytes: BatchRunner.fileSize($0)) }
        let listed = Set(order).union(sources)
        order = inputOrder.filter { listed.contains($0) }
    }
}
