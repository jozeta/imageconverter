import SwiftUI
import ImageconverterCore

@main
struct ImageconverterApp: App {
    @State private var model = AppModel()
    @State private var settings = AppSettings()

    init() {
        // A SwiftPM executable starts as a background process; make it a regular app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("imageconverter") {
            MainWindowContent(model: model, settings: settings)
                .onChange(of: PreviewRequest(model: model, mode: settings.outputMode), initial: true) { _, request in
                    model.schedulePreview(mode: request.mode)
                    model.scheduleEstimate()
                }
        }
        .windowResizability(.contentSize)
        .commands {
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
            }
        }
    }
}

extension ImageconverterApp {
    /// Zoom the before/after preview; ⌘= also zooms in (see `ZoomController.installKeyMonitor`).
    @ViewBuilder private var zoomCommands: some View {
        let disabled = !model.zoom.canZoom || model.previewCollapsed || model.previewResult == nil
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
    @Bindable var model: AppModel
    var settings: AppSettings

    var body: some View {
        let sizer = model.windowSizer
        let frozen = sizer.previewFrozenWidth
        HStack(spacing: 0) {
            SidebarView(model: model, settings: settings)
                .frame(width: WindowLayout.sidebarWidth)
                .overlay(alignment: .trailing) { previewHandle }
                .overlay(alignment: .bottom) { pipelineHandle }
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
        .background(WindowAccessor { sizer.attach($0) })
        .onAppear {
            model.zoom.installKeyMonitor()
            #if DEBUG
            applyDebugArguments()
            #endif
        }
    }

    #if DEBUG
    private static var debugArgumentsApplied = false

    /// Debug-only launch options for screenshots: `-debugAddFiles <path>…` adds images at launch,
    /// `-debugZoom <scale>` starts the preview zoomed (scale relative to fit) and `-debugWindowWidth <points>`
    /// widens the window once it has its first size.
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

    /// Centred on the sidebar/preview border, or just inside the window's right edge when the preview is hidden.
    private var previewHandle: some View {
        let collapsed = model.previewCollapsed
        let halfWidth = EdgeHandle.thickness / 2 + EdgeHandle.hitMargin
        return EdgeHandle(edge: .trailing, pointsOutward: collapsed,
                          label: collapsed ? "Show preview" : "Hide preview") { model.togglePreview() }
            .offset(x: collapsed ? halfWidth - LadaGlass.Spacing.m / 2 : halfWidth)
            .animation(.easeInOut(duration: WindowSizer.animationDuration), value: collapsed)
    }

    /// Centred in the padding under the sidebar panel, on the window's bottom edge.
    private var pipelineHandle: some View {
        let collapsed = model.pipelineCollapsed
        let halfHeight = EdgeHandle.thickness / 2 + EdgeHandle.hitMargin
        return EdgeHandle(edge: .bottom, pointsOutward: collapsed,
                          label: collapsed ? "Expand pipeline" : "Collapse pipeline") { model.togglePipeline() }
        .offset(y: halfHeight - LadaGlass.Spacing.m / 2)
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
