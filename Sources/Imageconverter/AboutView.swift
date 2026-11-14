import SwiftUI
import ImageconverterCore

/// App menu ▸ About imageconverter: version, one line on what the app is, and the privacy summary.
struct AboutView: View {
    static let windowID = "about"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: LadaGlass.Spacing.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("imageconverter").font(LadaGlass.Typography.title)
            Text("Version \(AppInfo.version) (build \(AppInfo.build))")
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .textSelection(.enabled)
            Text("Batch image processing for the Mac: resize, crop, rotate, watermark, metadata, rename and convert whole folders.")
                .multilineTextAlignment(.center)
            Text(PrivacyStatement.offline + " " + PrivacyStatement.frameworks)
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .multilineTextAlignment(.center)
            Text("MIT License · © 2026 Johan Zetterström")
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
            Button("Privacy details…") { openWindow(id: PrivacyWindow.windowID) }
                .buttonStyle(.lg(.secondary))
        }
        .font(LadaGlass.Typography.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(LadaGlass.Spacing.xl)
        .frame(width: 360)
        .lgBackdrop()
        .lgCompact()
    }
}

/// Replaces the standard About panel in the app menu.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About imageconverter") { openWindow(id: AboutView.windowID) }
        }
    }
}
