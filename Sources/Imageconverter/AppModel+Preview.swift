import AppKit
import CoreGraphics
import ImageconverterCore

extension AppModel {
    nonisolated static let thumbnailPixels = 64

    /// The selected image's index, kept inside `items` (nil when the batch is empty).
    var selectedItemIndex: Int? {
        items.isEmpty ? nil : min(max(selectedIndex, 0), items.count - 1)
    }

    /// A quick proxy is on screen and its exact render is on the way ("Refining…" in the preview header).
    var showsPreviewProxy: Bool {
        isRenderingPreview && previewFailure == nil && previewResult?.isProxy == true
    }

    /// Moves the selection by `offset`, stopping at both ends.
    func moveSelection(by offset: Int) {
        guard let current = selectedItemIndex else { return }
        selectedIndex = min(max(current + offset, 0), items.count - 1)
    }

    /// Flips the preview pane; `WindowSizer` animates the window edge (hiding shrinks the window to the
    /// sidebar, showing restores the preview width it had before).
    func togglePreview() {
        previewCollapsed.toggle()
        windowSizer.setPreviewShown(!previewCollapsed)
    }

    /// Collapses or expands the pipeline with the sidebar motion; the window edge follows the panel.
    func togglePipeline() {
        SidebarMotion.perform { pipelineCollapsed.toggle() }
    }

    /// Collapses the Output panel to its summary line or opens it again (at the height it had).
    func toggleOutput() {
        // A drag cut short by the shortcut must not leave the window pinned.
        windowSizer.requestRelease()
        SidebarMotion.perform { outputPanel.collapsed.toggle() }
    }

    /// After a run, forgets items whose file is gone (overwrite mode trashes originals when the name or format changes).
    /// The file checks run off the main actor; the result is applied (and announced) back on it.
    func dropMissingItems() {
        let sources = items.map(\.source)
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(sources.filter { !FileManager.default.fileExists(atPath: $0.path) })
            }.value
            guard let self, !missing.isEmpty else { return }
            let kept = items.filter { !missing.contains($0.source) }
            let removed = items.count - kept.count
            guard removed > 0 else { return }
            items = kept
            let remaining = Set(kept.map(\.source))
            Task { await self.factsCache.retain(only: remaining) }
            selectedIndex = min(selectedIndex, max(kept.count - 1, 0))
            resetPreview()
            toasts.show("Removed \(removed) \(removed == 1 ? "image" : "images") whose "
                        + "\(removed == 1 ? "original was" : "originals were") moved to the Trash", type: .info)
        }
    }

    /// Drops the shown preview and frees the renderer's caches (batch start, clear).
    func resetPreview() {
        previewTask?.cancel()
        previewGeneration += 1
        previewResult = nil
        previewConditions = nil
        previewFailure = nil
        previewFailureName = nil
        isRenderingPreview = false
        previewDetecting = nil
        previewScheduledSource = nil
        Task { await previewRenderer.purge() }
    }

    /// Cancels the running render and starts a new one: at once for a newly selected image, 300 ms after the last edit
    /// otherwise (`PreviewTiming`). A scale-invariant pipeline first shows a quick proxy (marked "Refining…"), at once
    /// even while a slider moves; the exact render replaces it. The previous result stays visible until the new one
    /// arrives; a result is applied only if no newer request was made.
    func schedulePreview(mode: OutputMode?) {
        previewMode = mode
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        previewDetecting = nil
        guard !previewCollapsed, previewAllowed, let index = selectedItemIndex else {
            isRenderingPreview = false
            if items.isEmpty {
                previewResult = nil
                previewConditions = nil
                previewFailure = nil
                previewFailureName = nil
            }
            return
        }
        let item = items[index]
        let batch = items
        let pipeline = self.pipeline
        let delay = PreviewTiming.previewDelay(selectionChanged: previewScheduledSource != item.source)
        previewScheduledSource = item.source
        isRenderingPreview = true
        let renderer = previewRenderer
        let presets = presetLibrary
        let cache = factsCache
        let activity = detectionActivity(generation: generation)
        // Only a scale-invariant pipeline gets a proxy (it has no conditions, so the item's own index is its counter).
        let proxy: (() async -> PreviewRendering?)? = pipeline.isScaleInvariant ? {
            guard let result = await renderer.renderProxy(item: item, index: index, pipeline: pipeline, mode: mode,
                                                          presets: presets), !Task.isCancelled else { return nil }
            return PreviewRendering(outcome: .ready(await Self.measured(result)), conditions: nil)
        } : nil
        previewTask = Task(priority: .userInitiated) { [weak self] in
            await PreviewTiming.run(exactDelay: delay, proxy: proxy, exact: {
                // The counter number the batch would give this item (skipped items before it take none), and the
                // branch each condition takes. Only read from files when the pipeline has conditions.
                let conditions = pipeline.hasConditions
                    ? await cache.preview(of: index, in: batch, pipeline: pipeline, presets: presets) : nil
                guard !Task.isCancelled else { return nil }
                var outcome = await renderer.render(item: item, index: conditions?.counterIndex ?? index,
                                                    pipeline: pipeline, mode: mode, presets: presets,
                                                    redactActivity: activity)
                // The histograms of the images about to be shown, measured off the main actor.
                if case .ready(let result) = outcome {
                    guard !Task.isCancelled else { return nil }
                    outcome = .ready(await Self.measured(result))
                }
                return PreviewRendering(outcome: outcome, conditions: conditions)
            }, deliver: { @MainActor rendering, final in
                guard let self, generation == self.previewGeneration else { return }
                self.apply(rendering.outcome, for: item, conditions: rendering.conditions, final: final)
            })
        }
    }

    /// Sets `previewDetecting` from the render's thread, in order, while `generation` is the newest request.
    private func detectionActivity(generation: Int) -> @Sendable (RedactTarget?) -> Void {
        { [weak self] target in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.previewGeneration else { return }
                    self.previewDetecting = target
                }
            }
        }
    }

    /// Shows a finished render (only called for the newest request). A proxy (`final` false) keeps the render
    /// running state and the shown image's alt text question until the exact result replaces it.
    private func apply(_ outcome: PreviewOutcome, for item: InputItem, conditions: ConditionPreview?, final: Bool) {
        if final {
            isRenderingPreview = false
            previewDetecting = nil
        }
        switch outcome {
        case .ready(var result):
            if result.isProxy, let shown = previewResult, shown.source == result.source {
                result.altTextRequest = shown.altTextRequest
            }
            previewResult = result
            previewConditions = conditions
            previewFailure = nil
            previewFailureName = nil
        case .failed(let reason):
            // A cancelled render belongs to a newer request that is already on its way.
            if reason == "Cancelled" { return }
            // The previous image stays only when it belongs to this same item.
            if previewResult?.source != item.source { previewResult = nil }
            previewConditions = conditions
            previewFailureName = item.source.lastPathComponent
            previewFailure = reason
        }
    }

    /// `result` with the histograms of its display images; runs on the global executor (nonisolated async).
    nonisolated static func measured(_ result: PreviewResult) async -> PreviewResult {
        result.withHistograms()
    }

    /// Makes the clipping overlay for the shown result (View ▸ Show Clipping) off the main actor; nil when it's off.
    func renderClippingMask(for key: ClippingKey) async {
        guard key.enabled, let after = key.image else {
            histogram.clippingMask = nil
            return
        }
        if histogram.clippingMask?.after === after { return }
        let mask = await Self.makeClippingMask(after)
        guard !Task.isCancelled else { return }
        histogram.clippingMask = mask.map { ClippingMask(after: after, mask: $0) }
    }

    nonisolated private static func makeClippingMask(_ image: CGImage) async -> CGImage? {
        Task.isCancelled ? nil : ImageHistogram.clippingMask(for: image)
    }

    // MARK: Thumbnails

    /// The cached thumbnail for `url`, if loaded. Reading `thumbnailTick` makes views refresh when one arrives.
    func thumbnail(for url: URL) -> CGImage? {
        _ = thumbnailTick
        return thumbnailCache.object(forKey: url as NSURL)?.image
    }

    /// Loads the filmstrip thumbnail for `url` off the main actor unless it is cached; images over
    /// the pixel limit and unreadable files get no thumbnail. Evicted entries load again on demand.
    func loadThumbnail(for url: URL) async {
        guard thumbnailCache.object(forKey: url as NSURL) == nil, !thumbnailsFailed.contains(url),
              thumbnailsLoading.insert(url).inserted else { return }
        defer { thumbnailsLoading.remove(url) }
        let image = await Self.decodeThumbnail(url)
        // Cancelled (the cell scrolled away or the list was cleared): don't record a failure.
        guard !Task.isCancelled else { return }
        if let image {
            thumbnailCache.setObject(CGImageBox(image), forKey: url as NSURL)
            thumbnailTick += 1
        } else {
            thumbnailsFailed.insert(url)
        }
    }

    /// Runs on the global executor (nonisolated async), inherits the caller's cancellation.
    nonisolated private static func decodeThumbnail(_ url: URL) async -> CGImage? {
        if Task.isCancelled { return nil }
        return makeThumbnail(url)
    }

    nonisolated private static func makeThumbnail(_ url: URL) -> CGImage? {
        // Core's decode limits decide first, like every other reader.
        ImageLoader.thumbnail(of: url, maxPixelSize: thumbnailPixels)
    }
}

/// One render handed from the preview task to the main actor: the outcome and the item's condition branches.
struct PreviewRendering: @unchecked Sendable {
    let outcome: PreviewOutcome
    let conditions: ConditionPreview?
}

/// Reference wrapper so `NSCache` can hold a `CGImage`.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
