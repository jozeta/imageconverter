import SwiftUI
import ImageconverterCore

@main
struct ImageconverterApp: App {
    /// Finder services, AppleScript and `imageconverter://` links (see `ExternalActions.swift`).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(defaults: AppDefaults.store, presetStore: PresetStore(directory: AppDefaults.presetsDirectory))
    @State private var watermarkTemplates = WatermarkTemplatesModel(store: .watermark(
        directory: AppDefaults.templatesDirectory(folder: WatermarkTemplateStore.watermarkFolderName)))
    @State private var metadataTemplates = MetadataTemplatesModel(store: .metadata(
        directory: AppDefaults.templatesDirectory(folder: MetadataTemplateStore.folderName)))
    @State private var settings = AppSettings(defaults: AppDefaults.store)
    /// Saved jobs, their watchers and schedules (see `JobsController`).
    @State private var jobs = JobsController.shared

    init() {
        // A SwiftPM executable starts as a background process; make it a regular app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        // `swift run` has no bundle icon; use the repo's Resources/AppIcon.png when it is there.
        let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/AppIcon.png").standardizedFileURL
        if let image = NSImage(contentsOf: icon) { NSApplication.shared.applicationIconImage = image }
        // `-debugSimulateSandbox`: the folder-access questions appear as in the sandboxed app (screenshots).
        if CommandLine.arguments.contains("-debugSimulateSandbox") { Sandbox.simulated = true }
        #endif
        // Remembered folder grants are opened once, at launch, and stay open.
        AccessStore.shared.activate()
        // "Apply preset" actions in conditions read the app's own presets folder.
        PresetLibrary.shared.use(directory: AppDefaults.presetsDirectory)
    }

    var body: some Scene {
        WindowGroup("imageconverter", id: MainWindowContent.windowID) {
            MainWindowContent(model: model, settings: settings)
                .environment(model)
                .environment(watermarkTemplates)
                .environment(metadataTemplates)
                .onChange(of: PreviewRequest(model: model, mode: settings.outputMode), initial: true) { _, request in
                    model.schedulePreview(mode: request.mode)
                    model.scheduleEstimate()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            JobsCommands()
            HistoryCommands()
            PrivacyCommands()
            FolderAccessCommands()
            AboutCommands()
            CommandGroup(after: .saveItem) {
                Button("Save Preset") { model.saveCurrent() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isRunning)
            }
            CommandGroup(after: .toolbar) {
                Button(model.previewCollapsed ? "Show Preview" : "Hide Preview") { model.togglePreview() }
                    .keyboardShortcut("p", modifiers: [.option, .command])
                Button(model.pipelineCollapsed ? "Expand Pipeline" : "Collapse Pipeline") { model.togglePipeline() }
                .keyboardShortcut("l", modifiers: [.option, .command])
                Toggle("Low-Memory Mode", isOn: $model.lowMemoryMode)
                Divider()
                compareCommands
                Divider()
                zoomCommands
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { model.chooseInputs() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isRunning)
                Button("Run") { model.run(settings: settings) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.items.isEmpty || model.isRunning || model.isAdding)
                Button("Cancel Run") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isRunning)
                Button(model.monitor.isPaused ? "Resume Run" : "Pause Run") { model.togglePause() }
                    .keyboardShortcut(".", modifiers: [.option, .command])
                    .disabled(!model.isRunning || !model.monitor.isActive)
                Button("Process Selected Next") { model.processSelectedNext() }
                    .disabled(!model.isRunning || !model.monitor.isActive || model.items.isEmpty)
            }
        }

        Window("Jobs", id: JobsView.windowID) {
            JobsView(controller: jobs, model: model, settings: settings)
                .onAppear { MenuBarMode.shared.windowWillShow() }
        }
        .defaultSize(width: 860, height: 560)

        Window("History", id: HistoryView.windowID) {
            HistoryView(controller: HistoryController.shared)
        }
        .defaultSize(width: 900, height: 560)

        Window("About imageconverter", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Privacy", id: PrivacyWindow.windowID) {
            PrivacyWindow()
        }
        .defaultSize(width: 480, height: 520)

        Window("Folder Access", id: FolderAccessWindow.windowID) {
            FolderAccessWindow(store: AccessStore.shared)
        }
        .defaultSize(width: 520, height: 380)

        MenuBarExtra("imageconverter", systemImage: jobs.runningCount > 0 ? "arrow.triangle.2.circlepath" : "photo.stack",
                     isInserted: $jobs.keepInMenuBar) {
            MenuBarContent(controller: jobs)
        }
    }
}

/// Window ▸ Jobs (⌘J). A `Window` scene lists itself in the Window menu, but without a shortcut.
private struct JobsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Jobs") { openWindow(id: JobsView.windowID) }
                .keyboardShortcut("j", modifiers: .command)
            Divider()
        }
    }
}

extension ImageconverterApp {
    /// The preview's comparison modes, ⌘1…⌘4; the current one has a check mark.
    @ViewBuilder private var compareCommands: some View {
        ForEach(CompareMode.allCases) { mode in
            Toggle(mode.title, isOn: Binding(get: { model.compare.mode == mode },
                                             set: { if $0 { model.compare.mode = mode } }))
                .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: .command)
                .disabled(model.previewCollapsed || model.items.isEmpty)
        }
    }

    /// Zoom the before/after preview; ⌘= also zooms in (see `ZoomController.installKeyMonitor`).
    @ViewBuilder private var zoomCommands: some View {
        let disabled = !model.zoom.canZoom || model.previewCollapsed || model.items.isEmpty || model.previewResult == nil
        Button("Zoom In") { model.zoom.zoomIn() }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(disabled)
        Button("Zoom Out") { model.zoom.zoomOut() }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(disabled)
        Button("Zoom to Fit") { model.zoom.zoomToFit() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(disabled)
        Button("Actual Size") { model.zoom.actualSize() }
            .keyboardShortcut("0", modifiers: [.option, .command])
            .disabled(disabled)
    }
}

/// The sidebar and the preview side by side, sized by `WindowSizer`: the sidebar has a fixed width,
/// the preview fills the rest, and the window edge clips the preview while it slides in or out.
private struct MainWindowContent: View {
    static let windowID = MainWindow.id
    @Bindable var model: AppModel
    var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sizer = model.windowSizer
        let frozen = sizer.previewFrozenWidth
        HStack(spacing: 0) {
            SidebarView(model: model, settings: settings)
                .frame(width: WindowLayout.sidebarWidth)
                .overlay(alignment: .trailing) { previewHandle }
                // Above the preview, so the handle on the shared border is drawn and clickable.
                .zIndex(1)
            if sizer.previewMounted {
                PreviewPane(model: model)
                    .frame(width: frozen)
                    .frame(minWidth: frozen ?? WindowLayout.previewMinWidth, maxWidth: frozen ?? .infinity)
            }
        }
        .frame(minWidth: sizer.widthRange.lowerBound, maxWidth: sizer.widthRange.upperBound,
               minHeight: sizer.heightRange.lowerBound, maxHeight: sizer.heightRange.upperBound,
               alignment: .topLeading)
        .clipped()
        .windowDropTarget(model: model)
        .interruptedRunSheet(model: model)
        .background(WindowAccessor {
            sizer.attach($0)
            ExternalActions.shared.attachWindow($0)
        })
        .onAppear {
            MenuBarMode.shared.windowWillShow()
            model.zoom.installKeyMonitor()
            ExternalActions.shared.attach(model: model, settings: settings) { [openWindow] in
                openWindow(id: Self.windowID)
            }
            model.checkInterruptedRunOnce()
            #if DEBUG
            applyDebugArguments()
            #endif
        }
    }

    #if DEBUG
    private static var debugArgumentsApplied = false

    /// `-debugShowJobs` opens the Jobs window; `-debugEditJob <name>` also opens that job's editor;
    /// `-debugShowHistory` opens the History window.
    private func openJobsWindowIfAsked(_ arguments: [String]) {
        if arguments.contains("-debugShowJobs") || arguments.contains("-debugEditJob") { openWindow(id: JobsView.windowID) }
        if arguments.contains("-debugShowAbout") { openWindow(id: AboutView.windowID) }
        if arguments.contains("-debugShowPrivacy") { openWindow(id: PrivacyWindow.windowID) }
        if arguments.contains("-debugShowHistory") { openWindow(id: HistoryView.windowID) }
        if arguments.contains("-debugShowFolderAccess") { openWindow(id: FolderAccessWindow.windowID) }
    }

    /// Debug-only launch options for screenshots: `-debugAddFiles <path>…` adds images at launch,
    /// `-debugZoom <scale>` starts the preview zoomed (scale relative to fit) and `-debugWindowWidth <points>`
    /// widens the window once it has its first size, `-debugSelect <index>` selects an image and
    /// `-debugShowQuality` opens the Compare quality panel.
    private func applyDebugArguments() {
        // Once per launch, not every time the window reappears.
        guard !Self.debugArgumentsApplied else { return }
        Self.debugArgumentsApplied = true
        let arguments = CommandLine.arguments
        if let start = arguments.firstIndex(of: "-debugAddFiles") {
            let paths = arguments[(start + 1)...].prefix { !$0.hasPrefix("-") }
            model.add(paths.map { URL(fileURLWithPath: $0) })
        }
        if let index = arguments.firstIndex(of: "-debugZoom"), index + 1 < arguments.count,
           let scale = Double(arguments[index + 1]) {
            model.zoom.pendingScale = CGFloat(scale)
        }
        if let index = arguments.firstIndex(of: "-debugSelect"), index + 1 < arguments.count,
           let selected = Int(arguments[index + 1]) {
            model.selectedIndex = selected
        }
        if arguments.contains("-debugShowQuality") { model.compare.showsQuality = true }
        openJobsWindowIfAsked(arguments)
        // `-debugAutoRun` runs the batch once the files are in; `-debugExpandPerformance` opens the panel;
        // `-debugResumeInterrupted` presses Resume on the interrupted-batch sheet.
        if arguments.contains("-debugExpandPerformance") { model.monitor.expanded = true }
        if arguments.contains("-debugAutoRun") { model.debugAutoRun(settings: settings) }
        if arguments.contains("-debugResumeInterrupted") { model.debugResumeInterrupted(settings: settings) }
        if let index = arguments.firstIndex(of: "-debugWindowWidth"), index + 1 < arguments.count,
           let width = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }
                var frame = window.frame
                frame.size.width = CGFloat(width)
                window.setFrame(frame, display: true)
            }
        }
    }
    #endif

    /// In the sidebar's trailing padding, at the same spot whether the preview is shown or hidden
    /// (so it never jumps under the pointer), fully inside the window when the preview is hidden.
    private var previewHandle: some View {
        let collapsed = model.previewCollapsed
        let halfWidth = EdgeHandle.thickness / 2 + EdgeHandle.hitMargin
        return EdgeHandle(edge: .trailing, pointsOutward: collapsed,
                          label: collapsed ? "Show preview" : "Hide preview") { model.togglePreview() }
            .offset(x: halfWidth - LadaGlass.Spacing.m / 2)
    }
}

/// Everything a preview depends on; a change schedules a new render.
private struct PreviewRequest: Equatable {
    let item: URL?
    let pipeline: Pipeline
    let mode: OutputMode?
    let collapsed: Bool
    let itemCount: Int

    @MainActor init(model: AppModel, mode: OutputMode?) {
        item = model.selectedItemIndex.map { model.items[$0].source }
        pipeline = model.pipeline
        self.mode = mode
        collapsed = model.previewCollapsed
        itemCount = model.items.count
    }
}

/// Hands the hosting window to `onWindow` once the view is in one, so `WindowSizer` knows which window to size.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
    }
}
