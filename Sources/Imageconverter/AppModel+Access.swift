import Foundation
import ImageconverterCore

extension AppModel {
    /// Renews stale watermark-image bookmarks (the file moved or its volume changed), and moved or stale
    /// extra-output folders (`refreshVariantFolders`), in the pipeline being edited,
    /// so the next launch opens them directly. Only the edited pipeline changes: a selected preset then shows
    /// unsaved changes, and its file is written only when the user saves it.
    func refreshWatermarkBookmarks() {
        refreshVariantFolders()
        guard let updated = pipeline.updatingImageWatermarks({ $0.refreshed() }) else { return }
        pipeline = updated
    }
}
