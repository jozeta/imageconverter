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
    /// The file version each finding was read from, so a file rewritten in place (Overwrite originals) is scanned
    /// again (`AppModel.refreshRewrittenSources`).
    @ObservationIgnored var versions: [URL: FileVersion] = [:]
    struct RowsKey: Equatable { let items: Int; let results: Int; let revision: Int }
    @ObservationIgnored var rows: (key: RowsKey, rows: [AppModel.PrivacyRow])?
    /// Bumped whenever `findings` or the item list change in a way a count would miss.
    @ObservationIgnored var revision = 0

    /// The opt-in content check (faces and text, on this Mac); off by default, remembered.
    var looksForContent: Bool = AppDefaults.store.bool(forKey: PrivacyState.looksForContentKey) {
        didSet { AppDefaults.store.set(looksForContent, forKey: Self.looksForContentKey) }
    }
    /// What the content check found per image (absent until checked, or when the analysis failed).
    var content: [URL: ContentCheckResult] = [:]
    @ObservationIgnored var contentTask: Task<Void, Never>?
    static let looksForContentKey = "privacyLooksForContent"
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

    /// The most severe metadata finding; else what the content check found; else, once every image is scanned,
    /// a neutral chip, so the panel (and its content check) can still be opened.
    var privacyChip: (text: String, severity: PrivacySeverity)? {
        if let chip = PrivacySummary.chip(Array(privacy.findings.values)) { return chip }
        if let first = privacyContentLines.first(where: { $0.target != nil }) { return (first.text, .medium) }
        guard !items.isEmpty, items.allSatisfy({ privacy.findings[$0.source] != nil }) else { return nil }
        return ("No private metadata found", .low)
    }

    /// "2 images show faces", "1 image contains text" for the images in the batch (empty while the check is off).
    var privacyContentLines: [(text: String, target: RedactTarget?)] {
        guard privacy.looksForContent else { return [] }
        return ContentPrivacySummary.lines(items.compactMap { privacy.content[$0.source] })
    }

    /// Switches the content check on or off; on, it checks the images that have no result yet.
    func setLooksForContent(_ isOn: Bool) {
        privacy.looksForContent = isOn
        if isOn { startContentScan() } else { privacy.contentTask?.cancel() }
    }

    /// Checks the batch's images for faces and text with the Redact step's detection (same resolution), off the main
    /// actor, one image at a time. A failed check is kept and shown as such.
    func startContentScan() {
        privacy.contentTask?.cancel()
        guard privacy.looksForContent else { return }
        let current = Set(items.map(\.source))
        privacy.content = privacy.content.filter { current.contains($0.key) }
        let todo = items.map(\.source).filter { privacy.content[$0] == nil }
        guard !todo.isEmpty else { return }
        privacy.contentTask = Task { [weak self] in
            for url in todo {
                if Task.isCancelled { return }
                let found = await Task.detached(priority: .utility) { ContentCheck.run(url) }.value
                guard let self, !Task.isCancelled else { return }
                if self.items.contains(where: { $0.source == url }) { self.privacy.content[url] = found }
            }
        }
    }

    /// Adds a Redact step for what the content check found (or widens the one there); never runs anything.
    func addSuggestedRedaction(_ target: RedactTarget) {
        guard !isRunning else { return }
        SidebarMotion.perform { _ = pipeline.addRedaction(target) }
        toasts.show("Redact step added; check the results before you share them", type: .ok)
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
            self?.startContentScan()
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
            var batch: [URL: (PrivacyFindings, FileVersion)] = [:]
            for url in todo {
                if Task.isCancelled { break }
                let scanned = await cache.versionedFindings(for: url)
                batch[url] = (scanned.findings, scanned.version)
                // Publish in chunks so the chip fills in while a big folder is still being scanned.
                if batch.count >= 100 { self?.publishPrivacy(batch); batch = [:] }
            }
            self?.publishPrivacy(batch)
        }
    }

    private func publishPrivacy(_ batch: [URL: (PrivacyFindings, FileVersion)]) {
        guard !batch.isEmpty else { return }
        let current = Set(items.map(\.source))
        for (url, (findings, version)) in batch where current.contains(url) {
            privacy.findings[url] = findings
            privacy.versions[url] = version
        }
    }

    /// After a run: sources rewritten in place (Overwrite originals keeps the URL) lose their privacy findings and
    /// content check and are scanned again; the size estimate and the metadata panel follow the file's version
    /// themselves (`EstimateKey`, `filesRevision`). Versions are read off the main actor.
    func refreshRewrittenSources() {
        filesRevision += 1
        let current = Set(items.map(\.source))
        privacy.versions = privacy.versions.filter { current.contains($0.key) }
        let known = privacy.versions
        guard !known.isEmpty else { return }
        Task { [weak self] in
            let changed = await Task.detached(priority: .utility) { FileVersion.changed(known) }.value
            guard let self, !changed.isEmpty else { return }
            for url in changed {
                // Only when nothing newer was recorded meanwhile.
                guard privacy.versions[url] == known[url] else { continue }
                privacy.findings[url] = nil
                privacy.content[url] = nil
                privacy.versions[url] = nil
                // The filmstrip's thumbnail is keyed by URL: drop the old picture and load it again.
                thumbnailCache.removeObject(forKey: url as NSURL)
                thumbnailsFailed.remove(url)
            }
            thumbnailTick += 1
            schedulePrivacyScan()
        }
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
