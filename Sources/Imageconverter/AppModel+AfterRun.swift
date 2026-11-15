import AppKit
import ImageconverterCore

extension AppModel {
    /// The "When finished" setting: select the outputs in Finder and/or post a notification (background only).
    func runAfterRunAction(_ report: BatchReport, summary: String) {
        let failed = report.failures.count
        let plan = afterRunSetting.plan(written: report.written, failed: failed, appIsActive: NSApp.isActive)
        if !plan.reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(plan.reveal) }
        guard plan.notify else { return }
        let (title, body) = AfterRunAction.notification(for: report, summary: summary)
        JobNotifier.shared.post(title: title, body: body, kind: JobNotifier.runKind)
    }
}
