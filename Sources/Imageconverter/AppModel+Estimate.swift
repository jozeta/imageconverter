import Foundation
import ImageconverterCore

/// Original and estimated output size for one item. `full` (the full-size images for zooming) is kept
/// for the selected item only and dropped when the selection changes.
struct SizeEstimate {
    let item: URL
    let original: Int?
    let output: Int?
    let full: EncodedPreview?
    /// The quality a searching compression mode chose.
    let quality: Double?
    let note: String?
}

/// What the background render returned: the original's file size, the encode, or why there is none.
private struct EstimateOutcome: Sendable {
    let original: Int?
    let preview: EncodedPreview?
    let failure: String?
}

/// What an estimate depends on; an unchanged key needs no new computation.
struct EstimateKey: Equatable {
    let item: URL
    let pipeline: Pipeline
}

extension AppModel {
    static let estimateDebounce = Duration.milliseconds(400)

    func cancelEstimate() {
        estimateTask?.cancel()
        estimateTask = nil
        estimateKey = nil
        sizeEstimate = nil
        isEstimating = false
        estimateFailed = false
        estimateFailure = nil
    }

    /// Recomputes the size estimate 400 ms after the last change, off the main actor.
    func scheduleEstimate() {
        guard previewAllowed, let index = selectedItemIndex else {
            cancelEstimate()
            return
        }
        let item = items[index]
        let pipeline = self.pipeline
        let key = EstimateKey(item: item.source, pipeline: pipeline)
        if key == estimateKey { return }
        let previous = estimateTask
        previous?.cancel()
        estimateKey = key
        // Rule: `sizeEstimate` is nil or current. Anything computed for another item or pipeline
        // (and its large images) goes as soon as the inputs change.
        sizeEstimate = nil
        isEstimating = true
        estimateFailed = false
        estimateFailure = nil
        let presets = presetLibrary
        estimateTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.estimateDebounce) } catch { return }
            // Wait for the superseded render so two full-size renders never overlap.
            await previous?.value
            guard !Task.isCancelled else { return }
            // A detached task doesn't inherit cancellation, so forward it: a superseded search must stop.
            let worker = Task.detached(priority: .userInitiated) { () -> EstimateOutcome? in
                if Task.isCancelled { return nil }
                let original = (try? item.source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                do {
                    let preview = try SizeEstimator.render(item: item, pipeline: pipeline, presets: presets)
                    return EstimateOutcome(original: original, preview: preview, failure: nil)
                } catch let error as ConversionError {
                    return EstimateOutcome(original: original, preview: nil, failure: error.reason)
                } catch {
                    return EstimateOutcome(original: original, preview: nil, failure: nil)
                }
            }
            let outcome = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.estimateKey == key, let outcome else { return }
            isEstimating = false
            estimateFailed = outcome.preview == nil
            estimateFailure = outcome.failure
            sizeEstimate = SizeEstimate(
                item: item.source, original: outcome.original, output: outcome.preview?.bytes, full: outcome.preview,
                quality: outcome.preview?.quality, note: outcome.preview?.note)
        }
    }
}
