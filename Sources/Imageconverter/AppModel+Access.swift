import Foundation
import ImageconverterCore

extension AppModel {
    /// Renews stale watermark-image bookmarks (the file moved or its volume changed) in the pipeline being edited,
    /// so the next launch opens them directly. Only the edited pipeline changes: a selected preset then shows
    /// unsaved changes, and its file is written only when the user saves it.
    func refreshWatermarkBookmarks() {
        guard let updated = pipeline.updatingImageWatermarks({ $0.refreshed() }) else { return }
        pipeline = updated
    }
}
