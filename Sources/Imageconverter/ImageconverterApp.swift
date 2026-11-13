import SwiftUI
import ImageconverterCore

@main
struct ImageconverterApp: App {
    init() {
        // A SwiftPM executable starts as a background process; make it a regular app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("imageconverter") {
            ContentView()
                .frame(minWidth: 520, minHeight: 340)
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("imageconverter").font(LadaGlass.Typography.title)
            Text(greeting(for: "world")).foregroundStyle(LadaGlass.Colors.muted)
            LGChip("Ready", status: .ok)
        }
        .lgPanel()
        .padding(LadaGlass.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
    }
}
