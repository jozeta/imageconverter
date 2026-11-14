import Foundation
import ImageconverterCore

extension AppModel {
    /// Whether "Clear All" is available: not while a run is going or files are being added.
    var canClearAll: Bool { !isRunning && !isAdding }

    /// Resets the working area: every image leaves the list and the pipeline goes back to a fresh
    /// default (no steps, default output), ad hoc with no unsaved-change dot. Saved presets and the
    /// Save to setting are not touched.
    func clearAll() {
        guard canClearAll else { return }
        clear()
        session = PresetSession(selected: nil, pipeline: Pipeline())
        zoom.track(item: nil)
        resetPreview()
    }
}
