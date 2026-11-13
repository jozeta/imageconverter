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
        Settings {
            SettingsView(settings: settings)
        }
    }
}
