import Foundation

/// Which branch of an if/then/else step one image takes.
public enum ConditionBranch: String, Equatable, Sendable {
    case then, otherwise
}

/// What the preview needs to know about the conditions for one selected item.
public struct ConditionPreview: Equatable, Sendable {
    /// The item's place in the rename counter: items before it that a condition skips take no number.
    public var counterIndex: Int
    /// The branch each enabled condition step takes for the item, in pipeline order; empty when the pipeline
    /// has no conditions or the file's facts can't be read.
    public var branches: [ConditionBranch]
    /// The item's pipeline with its conditions resolved.
    public var resolved: ResolvedPipeline

    public init(counterIndex: Int, branches: [ConditionBranch], resolved: ResolvedPipeline) {
        self.counterIndex = counterIndex
        self.branches = branches
        self.resolved = resolved
    }
}

extension Pipeline {
    /// The branch each enabled condition step chooses for `facts`, in order.
    public func branches(for facts: ItemFacts) -> [ConditionBranch] {
        steps.compactMap { step in
            guard step.isEnabled, case .condition(let conditional) = step.operation else { return nil }
            return conditional.matches(facts) ? .then : .otherwise
        }
    }

    /// True when an enabled condition can skip a file; only then can an item give up its counter number.
    public var canSkipByCondition: Bool {
        steps.contains { step in
            guard step.isEnabled, case .condition(let conditional) = step.operation else { return false }
            return (conditional.then + conditional.otherwise).contains(.skip)
        }
    }

    var conditionsScanAlpha: Bool {
        steps.contains { step in
            guard step.isEnabled, case .condition(let conditional) = step.operation else { return false }
            return conditional.conditions.contains(where: \.needsAlphaScan)
        }
    }
}

/// Source facts for the preview, read once per file version (URL, modification date and size) and off the
/// main actor. The batch reads its own; this only keeps the preview's counter and branch cheap to recompute.
public actor ItemFactsCache {
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            // A fresh URL: a URL caches its resource values, which would hide a rewritten file.
            let values = try? URL(fileURLWithPath: url.path)
                .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.url = url
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private struct Entry {
        let facts: ItemFacts?
        /// Whether the transparency scan ran (an unscanned entry can't answer a transparency condition).
        let scanned: Bool
    }

    private let maxPixels: Int
    private let limit: Int
    private var entries: [Key: Entry] = [:]
    /// How many files were read (for tests).
    public private(set) var readCount = 0

    public init(maxPixels: Int = ImageLoader.defaultMaxPixels, limit: Int = 5000) {
        self.maxPixels = maxPixels
        self.limit = max(1, limit)
    }

    public func removeAll() { entries = [:] }

    /// The facts of `url`; nil when it isn't a readable image.
    public func facts(for url: URL, scanAlpha: Bool) -> ItemFacts? {
        let key = Key(url)
        if let entry = entries[key], entry.scanned || !scanAlpha { return entry.facts }
        readCount += 1
        let facts = ItemFacts.read(url, scanAlpha: scanAlpha, maxPixels: maxPixels)
        if entries.count >= limit { entries = [:] }
        entries[key] = Entry(facts: facts, scanned: scanAlpha)
        return facts
    }

    /// The counter index, branches and resolved pipeline of `items[index]`, as the batch would see them.
    /// Items before it are only read when a condition can skip files. Nil when cancelled part-way or out of range.
    public func preview(of index: Int, in items: [InputItem], pipeline: Pipeline) -> ConditionPreview? {
        guard items.indices.contains(index) else { return nil }
        guard pipeline.hasConditions else {
            return ConditionPreview(counterIndex: index, branches: [],
                                    resolved: pipeline.resolved(forSource: items[index].source, maxPixels: maxPixels))
        }
        let scan = pipeline.conditionsScanAlpha
        var counter = index
        if pipeline.canSkipByCondition {
            counter = 0
            for item in items[..<index] {
                if Task.isCancelled { return nil }
                // Unreadable files aren't skipped: the batch gives them a number and fails them later.
                if pipeline.resolved(for: facts(for: item.source, scanAlpha: scan)).disposition != .skip { counter += 1 }
            }
        }
        let facts = facts(for: items[index].source, scanAlpha: scan)
        return ConditionPreview(counterIndex: counter, branches: facts.map(pipeline.branches(for:)) ?? [],
                                resolved: pipeline.resolved(for: facts))
    }
}
