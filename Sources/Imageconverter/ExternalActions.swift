import AppKit
import ImageconverterCore

/// Installs the entry points other apps use: Finder services, the `imageconverter://` link handler and (through
/// the sdef in the bundle) AppleScript. They only become active in the packaged app, whose Info.plist declares
/// them (see `Resources/Info-fragments.plist`); `swift run` has no bundle, so macOS never routes them here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    /// Before launch finishes, so a link that launches the app isn't missed.
    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // Again after launch, in case SwiftUI installed its own (which would open a new window per link).
        installURLHandler()
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              string.utf8.count <= URLAction.maxURLLength, let url = URL(string: string) else { return }
        MainActor.assumeIsolated { ExternalActions.shared.handle(url) }
    }
}

/// The bridge from services, scripts and links to the app's model. Requests that arrive before the window
/// (and so the model) is up wait until `attach` is called.
@MainActor
final class ExternalActions {
    static let shared = ExternalActions()

    private(set) weak var model: AppModel?
    private(set) weak var settings: AppSettings?
    private var openWindow: (() -> Void)?
    private var waiting: [(AppModel, AppSettings) -> Void] = []
    /// Saved jobs, for `imageconverter://jobs/run`.
    let jobStore = JobStore(directory: AppDefaults.templatesDirectory(folder: "jobs"))

    func attach(model: AppModel, settings: AppSettings, openWindow: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.openWindow = openWindow
        let pending = waiting
        waiting = []
        for work in pending { work(model, settings) }
    }

    /// Runs `work` now, or once the model is attached.
    func withModel(_ work: @escaping (AppModel, AppSettings) -> Void) {
        if let model, let settings { work(model, settings) } else { waiting.append(work) }
    }

    /// Brings the app forward with its window (reopening it when it was closed).
    func showWindow() {
        NSApp.activate()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Asks in a sheet on the main window (or an alert when there is none) whether to go ahead.
    /// `message` must say exactly what will happen.
    func confirm(title: String, message: String, confirm: String, destructive: Bool = false) async -> Bool {
        showWindow()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let button = alert.addButton(withTitle: confirm)
        button.hasDestructiveAction = destructive
        // Cancel is the default (Return) for anything that writes, so a stray keypress can't confirm.
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        button.keyEquivalent = ""
        guard let window = mainWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// Adds files and folders to the batch and shows the window (Finder service, script, confirmed link).
    func add(_ urls: [URL]) {
        withModel { model, _ in
            self.showWindow()
            guard !model.isRunning else {
                model.toasts.show("Wait for the run to finish before adding images", type: .info)
                return
            }
            model.add(urls)
        }
    }

    /// Converts a checked plan in the background, asking first in overwrite mode. Returns the written files.
    func convert(_ plan: ConvertPlan, model: AppModel) async throws -> [URL] {
        if plan.needsOverwriteConfirmation {
            let count = plan.files.count
            let confirmed = await confirm(
                title: "Replace \(count) original \(count == 1 ? "image" : "images")?",
                message: "Converting with the preset \(plan.preset.name) "
                    + ExternalRequests.describe(plan.mode) + ". Output is set to overwrite in Settings.",
                confirm: "Replace Originals", destructive: true)
            guard confirmed else { throw ExternalRequestError.cancelled }
        }
        guard !model.isRunning else { throw ExternalRequestError.busy }
        let files = plan.files
        let items = await Task.detached(priority: .userInitiated) { InputCollector.collect(files) }.value
        guard !items.isEmpty else { throw ExternalRequestError.noFiles }
        return try await withCheckedThrowingContinuation { continuation in
            let started = model.startRun(items, pipeline: plan.preset.pipeline, mode: plan.mode,
                                         presetName: plan.preset.name) { report in
                continuation.resume(returning: report.written)
            }
            if !started { continuation.resume(throwing: ExternalRequestError.busy) }
        }
    }

    func reportProblem(_ error: Error, title: String) {
        let message = (error as? ExternalRequestError)?.message ?? error.localizedDescription
        withModel { model, _ in
            self.showWindow()
            model.toasts.show(title, type: .bad, description: message)
        }
    }
}
