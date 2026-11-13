import AppKit
import CoreGraphics
import ImageIO
import ImageconverterCore

extension AppModel {
    /// Wait after the last change before a preview render starts.
    static let previewDebounce = Duration.milliseconds(300)
    nonisolated static let thumbnailPixels = 64
    /// The thumbnail cache is emptied when it grows past this many images.
    static let thumbnailLimit = 500

    /// The selected image's index, kept inside `items` (nil when the batch is empty).
    var selectedItemIndex: Int? {
        items.isEmpty ? nil : min(max(selectedIndex, 0), items.count - 1)
    }

    /// Moves the selection by `offset`, stopping at both ends.
    func moveSelection(by offset: Int) {
        guard let current = selectedItemIndex else { return }
        selectedIndex = min(max(current + offset, 0), items.count - 1)
    }

    /// Flips the preview pane and moves the window edge by the pane's width.
    func togglePreview() {
        previewCollapsed.toggle()
        guard let window = NSApp.keyWindow else { return }
        let delta: CGFloat = 440
        var frame = window.frame
        frame.size.width = max(window.minSize.width, frame.width + (previewCollapsed ? -delta : delta))
        if let visible = window.screen?.visibleFrame { frame.size.width = min(frame.width, visible.width) }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Drops the shown preview and frees the renderer's caches (batch start, clear).
    func resetPreview() {
        previewTask?.cancel()
        previewGeneration += 1
        previewResult = nil
        previewFailure = nil
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
        guard !previewCollapsed, !isRunning, let index = selectedItemIndex else {
            isRenderingPreview = false
            if items.isEmpty {
                previewResult = nil
                previewFailure = nil
            }
            return
        }
        let item = items[index]
        let pipeline = self.pipeline
        isRenderingPreview = true
        previewTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.previewDebounce) } catch { return }
            guard let renderer = self?.previewRenderer else { return }
            let outcome = await renderer.render(item: item, index: index, pipeline: pipeline, mode: mode)
            guard let self, generation == self.previewGeneration else { return }
            switch outcome {
            case .ready(let result):
                previewResult = result
                previewFailure = nil
            case .failed(let reason):
                // A cancelled render belongs to a newer request that is already on its way.
                if reason == "Cancelled" { return }
                previewResult = nil
                previewFailure = reason
            }
            isRenderingPreview = false
        }
    }

    // MARK: Thumbnails

    /// Loads the filmstrip thumbnail for `url` off the main actor, once; images over the pixel
    /// limit and unreadable files get no thumbnail.
    func loadThumbnail(for url: URL) async {
        guard thumbnails[url] == nil, !thumbnailsFailed.contains(url), thumbnailsLoading.insert(url).inserted else { return }
        defer { thumbnailsLoading.remove(url) }
        let image = await Task.detached(priority: .utility) { Self.makeThumbnail(url) }.value
        if thumbnails.count >= Self.thumbnailLimit { thumbnails.removeAll() }
        if let image { thumbnails[url] = image } else { thumbnailsFailed.insert(url) }
    }

    nonisolated private static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let pixels = ImageLoader.pixelCount(of: url), pixels <= ImageLoader.defaultMaxPixels else { return nil }
        let loadOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, loadOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
