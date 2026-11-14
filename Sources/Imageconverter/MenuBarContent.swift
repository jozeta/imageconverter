import AppKit
import SwiftUI
import ImageconverterCore

/// The menu bar extra (only while "Keep running in the menu bar" is on): job status, pause all, the windows, quit.
struct MenuBarContent: View {
    @Bindable var controller: JobsController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if controller.jobs.isEmpty {
            Text("No jobs")
        }
        ForEach(controller.jobs) { job in
            let status = JobsView.statusText(job, status: controller.status(of: job.id), paused: controller.pausedAll)
            Text("\(job.name): \(status.0)")
        }
        Divider()
        Button(controller.pausedAll ? "Resume All Jobs" : "Pause All Jobs") { controller.pausedAll.toggle() }
        Divider()
        Button("Open imageconverter") {
            // Brings the existing main window forward; opens one only when it was closed.
            MenuBarMode.shared.windowWillShow()
            ExternalActions.shared.showWindow()
        }
        Button("Jobs…") { show(JobsView.windowID) }
        Divider()
        Button("Quit imageconverter") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        MenuBarMode.shared.windowWillShow()
        openWindow(id: id)
        NSApp.activate()
    }
}

/// The main window's scene id, shared by the menu bar and the app.
enum MainWindow {
    static let id = "main"
}

/// In menu bar mode the Dock icon goes away once the last window closes, and comes back with a window.
@MainActor
final class MenuBarMode {
    static let shared = MenuBarMode()
    private var observer: NSObjectProtocol?

    func install(controller: JobsController) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                          queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard controller.keepInMenuBar else { return }
                let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func windowWillShow() {
        NSApp.setActivationPolicy(.regular)
    }
}
