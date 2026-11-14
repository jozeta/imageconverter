import Foundation
import ImageconverterCore

/// What the privacy scan found per image (absent until scanned), and whether the chip's panel is open.
@MainActor @Observable
final class PrivacyState {
    var findings: [URL: PrivacyFindings] = [:]
    var showsPanel = false
    @ObservationIgnored let cache = PrivacyCache()
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var scanQueued = false
}

extension AppModel {
    /// One image's findings in the panel.
    struct PrivacyRow: Identifiable {
        let item: InputItem
        let findings: PrivacyFindings
        var id: URL { item.source }
    }

    /// Images with something found, most severe first (stable within a severity).
    var privacyRows: [PrivacyRow] {
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
    /// `PrivacyFindings.suggestion`).
    func removeFoundPrivacyData() {
        let merged = PrivacySummary.merged(Array(privacy.findings.values))
        guard !merged.isEmpty else { return }
        pipeline.metadata = merged.suggestion(from: pipeline.metadata)
        toasts.show("Metadata step set to remove these", type: .ok)
    }
}
