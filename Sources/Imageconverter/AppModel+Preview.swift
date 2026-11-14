import AppKit
import CoreGraphics
import ImageconverterCore

extension AppModel {
    /// Wait after the last change before a preview render starts.
    static let previewDebounce = Duration.milliseconds(300)
    nonisolated static let thumbnailPixels = 64

    /// The selected image's index, kept inside `items` (nil when the batch is empty).
    var selectedItemIndex: Int? {
        items.isEmpty ? nil : min(max(selectedIndex, 0), items.count - 1)
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

    /// Collapses or expands the pipeline; the window follows the new sidebar height right away.
    func togglePipeline() {
        windowSizer.pipelineWillToggle()
        pipelineCollapsed.toggle()
    }

    /// After a run, forgets items whose file is gone (overwrite mode trashes originals when the format changes).
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
        Task { await previewRenderer.purge() }
    }

    /// Cancels the running render and starts a new one after 300 ms. The previous result stays
    /// visible until the new one arrives; a result is applied only if no newer request was made.
    func schedulePreview(mode: OutputMode?) {
        previewMode = mode
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
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
        isRenderingPreview = true
        previewTask = Task(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(for: Self.previewDebounce) } catch { return }
            guard let renderer = self?.previewRenderer, let cache = self?.factsCache else { return }
            // The counter number the batch would give this item (skipped items before it take none), and the
            // branch each condition takes. Only read from files when the pipeline has conditions.
            let conditions = pipeline.hasConditions ? await cache.preview(of: index, in: batch, pipeline: pipeline) : nil
            guard !Task.isCancelled else { return }
            let outcome = await renderer.render(item: item, index: conditions?.counterIndex ?? index, pipeline: pipeline,
                                                mode: mode)
            guard let self, generation == self.previewGeneration else { return }
            isRenderingPreview = false
            switch outcome {
            case .ready(let result):
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

/// Reference wrapper so `NSCache` can hold a `CGImage`.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
