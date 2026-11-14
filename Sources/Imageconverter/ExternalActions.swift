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

    /// A running batch or job is stopped cleanly first (see `QuitCoordinator`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { QuitCoordinator.shared.shouldTerminate() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Watching and schedules start with the app, not with the Jobs window.
        MainActor.assumeIsolated {
            JobsController.shared.start()
            MenuBarMode.shared.install(controller: JobsController.shared)
        }
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
    /// The document window hosting the model (from the root view's window accessor).
    private weak var window: NSWindow?
    private var openWindow: (() -> Void)?
    private var waiting: [(AppModel, AppSettings) -> Void] = []
    /// Saved jobs, for `imageconverter://jobs/run`: the Jobs controller's store, so ledgers share one lock.
    var jobStore: JobStore { JobsController.shared.store }

    func attach(model: AppModel, settings: AppSettings, openWindow: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.openWindow = openWindow
        // Results of runs the user started (Run now, links) and missing folders show as toasts in this window.
        JobsController.shared.messenger = { [weak model] text, isProblem in
            model?.toasts.show(text, type: isProblem ? .bad : .ok)
        }
        let pending = waiting
        waiting = []
        for work in pending { work(model, settings) }
    }

    /// Called by the main window's accessor, so sheets go to that window and never to Settings or a panel.
    func attachWindow(_ window: NSWindow?) {
        if let window { self.window = window }
    }

    /// Runs `work` now, or once the model is attached.
    func withModel(_ work: @escaping (AppModel, AppSettings) -> Void) {
        if let model, let settings { work(model, settings) } else { waiting.append(work) }
    }

    /// Brings the app forward with its main window: restored from the Dock when minimised, reopened only
    /// when it was closed (never a second one).
    func showWindow() {
        NSApp.activate()
        guard let window, window.isVisible || window.isMiniaturized else {
            openWindow?()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// The alert for `confirm`: Escape (and the Cancel button) cancels; the confirm button has no key
    /// equivalent, so neither Return nor a stray keypress can approve something a link or script asked for.
    static func makeConfirmation(title: String, message: String, confirm: String, destructive: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let button = alert.addButton(withTitle: confirm)
        button.hasDestructiveAction = destructive
        button.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }

    /// Asks in a sheet on the main window (or an alert when it isn't open yet) whether to go ahead.
    /// `message` must say exactly what will happen.
    func confirm(title: String, message: String, confirm: String, destructive: Bool = false) async -> Bool {
        showWindow()
        let alert = Self.makeConfirmation(title: title, message: message, confirm: confirm, destructive: destructive)
        guard let window, window.isVisible || window.isMiniaturized else {
            return alert.runModal() == .alertFirstButtonReturn
        }
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

    /// Before an external request starts a run: a kept interrupted batch would be replaced (its journal can't be
    /// resumed afterwards). `interactive` (a Finder service) asks like Run; a script is refused with a message.
    func checkInterruptedRun(model: AppModel, interactive: Bool) async throws {
        switch ExternalRequests.interruptedRunDecision(hasInterruptedRun: model.interruptedRun != nil,
                                                       interactive: interactive) {
        case .proceed: return
        case .refuse: throw ExternalRequestError.interruptedBatchWaiting
        case .ask: break
        }
        let left = model.interruptedRun?.remainingItems.count ?? 0
        let confirmed = await confirm(
            title: "Discard the interrupted batch?",
            message: "\(left) \(left == 1 ? "image" : "images") of the interrupted batch "
                + "\(left == 1 ? "wasn't" : "weren't") converted. This conversion replaces it, so it can't be resumed "
                + "afterwards.",
            confirm: "Discard and Convert", destructive: true)
        guard confirmed else { throw ExternalRequestError.cancelled }
        model.discardInterruptedRun()
    }

    /// Converts a checked plan in the background, asking first in overwrite mode. Returns the written files.
    /// A kept interrupted batch is asked about first (`interactive`) or refuses the run (scripts).
    func convert(_ plan: ConvertPlan, model: AppModel, interactive: Bool) async throws -> [URL] {
        try await checkInterruptedRun(model: model, interactive: interactive)
        if plan.needsOverwriteConfirmation {
            let count = plan.files.count
            let confirmed = await confirm(
                title: "Replace \(count) original \(count == 1 ? "image" : "images")?",
                message: ExternalRequests.runSummary(files: plan.files, pipelineName: "the preset \(plan.preset.name)",
                                                     mode: plan.mode),
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
        reportProblem(title: title, message: message)
    }

    func reportProblem(title: String, message: String) {
        withModel { model, _ in
            self.showWindow()
            model.toasts.show(title, type: .bad, description: message)
        }
    }

    // MARK: Link confirmations

    /// True while a link's confirmation is waiting; further links are dropped (see `URLActions.swift`).
    var linkPending = false
    /// Links dropped while one was pending, reported in one toast when it closes.
    var droppedLinks = 0
}
