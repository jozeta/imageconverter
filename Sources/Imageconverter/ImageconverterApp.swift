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
            HStack(spacing: 0) {
                SidebarView(model: model, settings: settings)
                    .frame(minWidth: 340, idealWidth: 360, maxWidth: 380)
                if !model.previewCollapsed {
                    PreviewPane(model: model)
                        .frame(minWidth: 420)
                }
            }
            .frame(minHeight: 420)
            .background(WindowAccessor { model.mainWindow = $0 })
            .onChange(of: PreviewRequest(model: model, mode: settings.outputMode), initial: true) { _, request in
                model.schedulePreview(mode: request.mode)
                model.scheduleEstimate()
            }
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save Preset") { model.saveCurrent() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isRunning)
            }
            CommandGroup(after: .toolbar) {
                Button(model.previewCollapsed ? "Show Preview" : "Hide Preview") { model.togglePreview() }
                    .keyboardShortcut("p", modifiers: [.option, .command])
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

/// Hands the hosting window to `onWindow` once the view is in one, so the model knows which window is the main one.
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
