import AppKit
import ImageconverterCore

extension AppModel {
    /// The "When finished" setting: select the outputs in Finder and/or post a notification (background only).
    func runAfterRunAction(written: [URL], summary: String) {
        let action = defaults.string(forKey: AppSettings.afterRunKey).flatMap(AfterRunAction.init(rawValue:)) ?? .nothing
        let plan = action.plan(written: written, appIsActive: NSApp.isActive)
        if !plan.reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(plan.reveal) }
        if plan.notify { afterRunNotifier.post(title: "Run finished", body: summary) }
    }
}
