import Foundation
import ImageconverterCore

/// What the privacy scan found per image (absent until scanned), and whether the chip's panel is open.
@MainActor @Observable
final class PrivacyState {
    var findings: [URL: PrivacyFindings] = [:] { didSet { revision += 1 } }
    var showsPanel = false
    @ObservationIgnored let cache = PrivacyCache()
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var scanQueued = false
    struct RowsKey: Equatable { let items: Int; let results: Int; let revision: Int }
    @ObservationIgnored var rows: (key: RowsKey, rows: [AppModel.PrivacyRow])?
    /// Bumped whenever `findings` or the item list change in a way a count would miss.
    @ObservationIgnored var revision = 0
}

extension AppModel {
    /// One image's findings in the panel.
    struct PrivacyRow: Identifiable {
        let item: InputItem
        let findings: PrivacyFindings
        var id: URL { item.source }
    }

    /// Images with something found, most severe first (stable within a severity). Cached per scan result and
    /// item list (`PrivacyState.rows`), since the panel reads it several times per render.
    var privacyRows: [PrivacyRow] {
        let key = PrivacyState.RowsKey(items: items.count, results: privacy.findings.count, revision: privacy.revision)
        if let cached = privacy.rows, cached.key == key { return cached.rows }
        let rows = computePrivacyRows()
        privacy.rows = (key, rows)
        return rows
    }

    private func computePrivacyRows() -> [PrivacyRow] {
        items.compactMap { item in
            privacy.findings[item.source].flatMap { $0.isEmpty ? nil : PrivacyRow(item: item, findings: $0) }
        }
        .enumerated()
        .sorted { ($0.element.findings.highestSeverity ?? .low, $1.offset) > ($1.element.findings.highestSeverity ?? .low, $0.offset) }
        .map(\.element)
    }

    var privacyChip: (text: String, severity: PrivacySeverity)? {
        PrivacySummary.chip(Array(privacy.findings.values))
    }

    /// Scans the images that have no result yet. Called through `items.didSet`, which fires once per appended item,
    /// so the work is queued once per main-actor turn.
    func schedulePrivacyScan() {
        privacy.revision += 1  // the item list changed: cached rows are stale
        guard !privacy.scanQueued else { return }
        privacy.scanQueued = true
        Task { @MainActor [weak self] in
            self?.privacy.scanQueued = false
            self?.startPrivacyScan()
        }
    }

    private func startPrivacyScan() {
        privacy.task?.cancel()
        let sources = items.map(\.source)
        let current = Set(sources)
        privacy.findings = privacy.findings.filter { current.contains($0.key) }
        let todo = sources.filter { privacy.findings[$0] == nil }
        let cache = privacy.cache
        privacy.task = Task { [weak self] in
            await cache.retain(only: current)
            var batch: [URL: PrivacyFindings] = [:]
            for url in todo {
                if Task.isCancelled { break }
                batch[url] = await cache.findings(for: url)
                // Publish in chunks so the chip fills in while a big folder is still being scanned.
                if batch.count >= 100 { self?.publishPrivacy(batch); batch = [:] }
            }
            self?.publishPrivacy(batch)
        }
    }

    private func publishPrivacy(_ batch: [URL: PrivacyFindings]) {
        guard !batch.isEmpty else { return }
        let current = Set(items.map(\.source))
        for (url, findings) in batch where current.contains(url) { privacy.findings[url] = findings }
    }

    /// Turns on the Metadata step with what the findings need; existing removals stay on (see
    /// `PrivacyFindings.suggestion`). The step's removals are a floor, so images a condition routes to its own
    /// metadata settings or to "Copy original unchanged" lose them too (`MetadataOptions.withRemovals(from:)`).
    func removeFoundPrivacyData() {
        let merged = PrivacySummary.merged(Array(privacy.findings.values))
        guard !merged.isEmpty else { return }
        pipeline.metadata = merged.suggestion(from: pipeline.metadata)
        toasts.show("Metadata step set to remove these", type: .ok)
    }
}
