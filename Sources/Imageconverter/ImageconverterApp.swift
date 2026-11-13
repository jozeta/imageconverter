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
            SidebarView(model: model, settings: settings)
                .frame(minWidth: 340, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save Preset") { model.saveCurrent() }
                    .keyboardShortcut("s", modifiers: .command)
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
        Settings {
            SettingsView(settings: settings)
        }
    }
}
