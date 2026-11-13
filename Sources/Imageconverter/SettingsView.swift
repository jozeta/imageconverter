import AppKit
import SwiftUI
import ImageconverterCore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var pendingOverwrite = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Output").font(LadaGlass.Typography.subtitle)
            Picker("Mode", selection: modeBinding) {
                Text("New folder").tag(OutputModeKind.newFolder)
                Text("Same folder, new name").tag(OutputModeKind.sameFolder)
                Text("Overwrite originals").tag(OutputModeKind.overwrite)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Output mode")

            switch settings.modeKind {
            case .newFolder:
                HStack {
                    Text(settings.outputFolder?.path ?? "No folder chosen")
                        .font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                        .buttonStyle(.lg(.secondary))
                        .accessibilityLabel("Choose output folder")
                }
            case .sameFolder:
                TextField("Name suffix", text: $settings.sameFolderSuffix)
                    .accessibilityLabel("Name suffix")
            case .overwrite:
                Text("Converted images replace the originals. When the format or name changes, the original is moved to the Trash.")
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted)
            }
        }
        .lgPanel()
        .padding(LadaGlass.Spacing.m)
        .frame(width: 440)
        .lgBackdrop()
        .lgCompact()
        .confirmationDialog("Overwrite originals?", isPresented: $pendingOverwrite) {
            Button("Use overwrite") { settings.modeKind = .overwrite }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Converted images will replace the originals. When the format or name changes, "
                + "the original is moved to the Trash. You won't be asked again when running.")
        }
    }

    /// Reads the stored kind; writing asks first when the change needs the overwrite warning.
    private var modeBinding: Binding<OutputModeKind> {
        Binding(
            get: { settings.modeKind },
            set: { new in
                if needsOverwriteWarning(from: settings.modeKind, to: new) {
                    pendingOverwrite = true
                } else {
                    settings.modeKind = new
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder"
        panel.prompt = "Choose"
        if panel.runModal() == .OK { settings.outputFolder = panel.url }
    }
}
