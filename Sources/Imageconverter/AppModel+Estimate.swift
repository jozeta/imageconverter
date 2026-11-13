import Foundation
import ImageconverterCore

/// Original and estimated output size for one item. `full` (the full-size images for zooming) is kept
/// for the selected item only and dropped when the selection changes.
struct SizeEstimate {
    let item: URL
    let original: Int?
    let output: Int?
    let full: EncodedPreview?
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
    }

    /// Recomputes the size estimate 400 ms after the last change, off the main actor.
    func scheduleEstimate() {
        guard !isRunning, let index = selectedItemIndex else {
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
        estimateTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.estimateDebounce) } catch { return }
            // Wait for the superseded render so two full-size renders never overlap.
            await previous?.value
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Int?, EncodedPreview?)? in
                if Task.isCancelled { return nil }
                let original = (try? item.source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                return (original, try? SizeEstimator.render(item: item, pipeline: pipeline))
            }.value
            guard let self, !Task.isCancelled, self.estimateKey == key, let outcome else { return }
            isEstimating = false
            estimateFailed = outcome.1 == nil
            sizeEstimate = SizeEstimate(item: item.source, original: outcome.0, output: outcome.1?.bytes, full: outcome.1)
        }
    }
}
