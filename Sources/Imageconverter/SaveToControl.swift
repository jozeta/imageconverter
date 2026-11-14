import AppKit
import SwiftUI
import ImageconverterCore

/// The "Save to" picker with its suffix field or folder chooser, shared by the Output row and the job editor.
/// Switching to overwrite asks once, here, never at run time.
struct SaveToControl: View {
    @Binding var kind: OutputModeKind
    @Binding var folder: URL?
    @Binding var suffix: String
    /// The overwrite note's second sentence differs: jobs have no Rename lock to explain.
    var overwriteNote = "Converted images replace the originals. The Rename step is off while overwriting."
    @State private var pendingOverwrite = false
    /// Bumped when the overwrite dialog is cancelled, so the menu picker redraws the real mode.
    @State private var pickerID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Save to", selection: modeBinding.sidebarAnimated) {
                Text("Overwrite original files").tag(OutputModeKind.overwrite)
                Text("Same folder as original").tag(OutputModeKind.sameFolder)
                Text("New folder").tag(OutputModeKind.newFolder)
            }
            .id(pickerID)
            .accessibilityLabel("Save to")
            switch kind {
            case .overwrite:
                note(overwriteNote)
            case .sameFolder:
                note("Added when the name is unchanged")
                TextField("Added when the name is unchanged", text: $suffix)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Added when the name is unchanged")
            case .newFolder:
                HStack {
                    Text(folder?.path ?? "No folder chosen")
                        .font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Choose folder…", action: chooseFolder)
                        .buttonStyle(.lg(.secondary))
                        .accessibilityLabel("Choose output folder")
                }
            }
        }
        .onChange(of: pendingOverwrite) { _, pending in
            if !pending, kind != .overwrite { pickerID += 1 }
        }
        .confirmationDialog("Overwrite originals?", isPresented: $pendingOverwrite) {
            Button("Use overwrite") { SidebarMotion.perform { kind = .overwrite } }
            Button("Cancel", role: .cancel) { pickerID += 1 }
        } message: {
            Text("Converted images will replace the originals. When the format or name changes, "
                + "the original is moved to the Trash. You won't be asked again when running.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
    }

    /// Reads the stored kind; writing asks first when the change needs the overwrite warning.
    private var modeBinding: Binding<OutputModeKind> {
        Binding(
            get: { kind },
            set: { new in
                if needsOverwriteWarning(from: kind, to: new) {
                    pendingOverwrite = true
                } else {
                    kind = new
                }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder"
        panel.prompt = "Choose"
        if panel.runModal() == .OK { folder = panel.url }
    }
}
