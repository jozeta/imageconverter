import Foundation

/// Which branch of an if/then/else step one image takes.
public enum ConditionBranch: String, Equatable, Sendable {
    case then, otherwise

    /// The preview chip: "Then branch" / "Else branch"; with several condition steps "1 then · 2 else".
    public static func chipText(_ branches: [ConditionBranch]) -> String {
        if branches.count == 1 { return branches[0] == .then ? "Then branch" : "Else branch" }
        return branches.enumerated().map { "\($0.offset + 1) \($0.element == .then ? "then" : "else")" }
            .joined(separator: " · ")
    }
}

/// The counts in the run notice.
public enum RunCountsText {
    /// "Converted 20 images", or "Converted 20 · 3 skipped by conditions · 1 failed".
    public static func make(written: Int, skipped: Int, failed: Int) -> String {
        guard skipped > 0 || failed > 0 else { return "Converted \(written) \(written == 1 ? "image" : "images")" }
        var parts = ["Converted \(written)"]
        if skipped > 0 { parts.append("\(skipped) skipped by \(skipped == 1 ? "a condition" : "conditions")") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// "1 extra output failed", "3 extra outputs failed".
    public static func extraFailures(_ count: Int) -> String {
        "\(count) extra \(count == 1 ? "output" : "outputs") failed"
    }

    /// The end-of-run line for the toast and the notification: the counts, then the failed extra outputs, then
    /// the saving of the primary outputs against their sources ("Converted 20 images · 2 extra outputs failed ·
    /// saved 31 MB (62 %)"). `hasProblems` is true when files or extra outputs failed.
    public static func runSummary(_ report: BatchReport) -> (text: String, hasProblems: Bool) {
        var text = make(written: report.convertedCount, skipped: report.skipped.count, failed: report.failures.count)
        if !report.extraFailures.isEmpty { text += " · " + extraFailures(report.extraFailures.count) }
        if let saved = SizeFormat.savedPhrase(input: report.inputBytes, output: report.primaryOutputBytes) {
            text += " · \(saved)"
        }
        return (text, !report.failures.isEmpty || !report.extraFailures.isEmpty)
    }
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
        /// What was read beyond the header (an entry without the transparency scan can't answer a transparency
        /// condition, one without XMP can't answer an XMP field).
        let needs: FactNeeds
        /// When it was last used, for evicting the least recently used entries.
        var lastUse: Int
    }

    private let maxPixels: Int
    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    /// How many files were read (for tests).
    public private(set) var readCount = 0

    public init(maxPixels: Int = ImageLoader.defaultMaxPixels, limit: Int = 5000) {
        self.maxPixels = maxPixels
        self.limit = max(1, limit)
    }

    public func removeAll() { entries = [:] }

    /// Forgets files that are no longer in the batch (after Clear, or when items are removed).
    public func retain(only urls: Set<URL>) {
        entries = entries.filter { urls.contains($0.key.url) }
    }

    /// The facts of `url`; nil when it isn't a readable image.
    public func facts(for url: URL, scanAlpha: Bool) -> ItemFacts? {
        facts(for: url, needs: scanAlpha ? .all : FactNeeds.all.subtracting(.alphaScan))
    }

    /// The facts of `url` with at least `needs` read; nil when it isn't a readable image. A cached entry that
    /// read less is read again (with both entries' needs).
    public func facts(for url: URL, needs: FactNeeds) -> ItemFacts? {
        let key = Key(url)
        clock += 1
        if let entry = entries[key], entry.needs.isSuperset(of: needs) {
            entries[key]?.lastUse = clock
            return entry.facts
        }
        readCount += 1
        let wanted = needs.union(entries[key]?.needs ?? [])
        let facts = ItemFacts.read(url, needs: wanted, maxPixels: maxPixels)
        if entries[key] == nil, entries.count >= limit { evictLeastRecentlyUsed() }
        entries[key] = Entry(facts: facts, needs: wanted, lastUse: clock)
        return facts
    }

    /// Drops the least recently used quarter (at least one), so a full cache isn't sorted on every read.
    private func evictLeastRecentlyUsed() {
        let count = max(1, entries.count / 4)
        for key in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }).prefix(count).map(\.key) {
            entries[key] = nil
        }
    }

    /// The counter index, branches and resolved pipeline of `items[index]`, as the batch would see them.
    /// Items before it are only read when a condition can skip files. Nil when cancelled part-way or out of range.
    public func preview(of index: Int, in items: [InputItem], pipeline: Pipeline,
                        presets: PresetLibrary = .standard) -> ConditionPreview? {
        guard items.indices.contains(index) else { return nil }
        guard pipeline.hasConditions else {
            return ConditionPreview(counterIndex: index, branches: [],
                                    resolved: pipeline.resolved(forSource: items[index].source, maxPixels: maxPixels,
                                                                       presets: presets))
        }
        let needs = pipeline.conditionFactNeeds
        var counter = index
        if pipeline.canSkipByCondition {
            counter = 0
            for item in items[..<index] {
                if Task.isCancelled { return nil }
                // Unreadable files aren't skipped: the batch gives them a number and fails them later.
                if pipeline.resolved(for: facts(for: item.source, needs: needs), presets: presets).disposition != .skip {
                    counter += 1
                }
            }
        }
        let facts = facts(for: items[index].source, needs: needs)
        return ConditionPreview(counterIndex: counter, branches: facts.map(pipeline.branches(for:)) ?? [],
                                resolved: pipeline.resolved(for: facts, presets: presets))
    }
}
