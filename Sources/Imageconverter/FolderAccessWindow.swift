import SwiftUI
import ImageconverterCore

/// Help ▸ Folder Access…: the folders imageconverter remembers access to, with Add Folder…, Remove and Remove All.
/// Removing stops access at once, so it is refused while a batch or a job runs (`busy`): the run would lose the
/// folders it is writing into.
struct FolderAccessWindow: View {
    static let windowID = "folder-access"
    @Bindable var store: AccessStore
    /// A batch or a job is running.
    var busy = false
    @State private var selection: FolderGrantList.Grant.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Folder Access").font(LadaGlass.Typography.title)
            Text("Folders you allowed when a run needed them, or added here. imageconverter can read and save in "
                 + "these (and the folders inside them) without asking again, also for scripts, links and Quick "
                 + "Actions. Removing one means it asks the next time it is needed.")
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !Sandbox.isActive {
                Text("This copy isn't sandboxed, so it never asks; the folders are kept for the sandboxed app.")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
            }
            if store.grants.isEmpty {
                Text("No remembered folders.")
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.grants, selection: $selection) { grant in
                    row(grant)
                }
                .accessibilityLabel("Remembered folders")
            }
            HStack {
                Button("Add Folder\u{2026}") { addFolder() }
                    .accessibilityLabel("Add a folder imageconverter may use")
                Button("Remove") {
                    guard !busy else { return }
                    if let selection { store.remove(selection) }
                    selection = nil
                }
                .disabled(selection == nil || busy)
                .accessibilityLabel("Remove the selected folder")
                Button("Remove All") {
                    guard !busy else { return }
                    store.removeAll()
                    selection = nil
                }
                .disabled(store.grants.isEmpty || busy)
                Spacer()
            }
            .buttonStyle(.lg(.secondary))
            if busy {
                Text("Folders can't be removed while a batch or a job is running. Try again when it has finished.")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(minWidth: 440, minHeight: 320)
        .lgBackdrop()
        .lgCompact()
        .onAppear { store.activate() }
    }

    /// Allows a folder ahead of time, in an open panel (the sandbox's way of granting it).
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder imageconverter may read and save in without asking."
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.remember(url)
    }

    private func row(_ grant: FolderGrantList.Grant) -> some View {
        let missing = store.unavailable.contains(grant.path)
        let again = store.needsAllowing.contains(grant.path)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text(grant.name).font(LadaGlass.Typography.body)
                if missing { LGChip("Not found", status: .warn) }
                if again { LGChip("Allow again", status: .warn) }
            }
            Text(grant.path).font(LadaGlass.Typography.mono)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(grant.name), \(grant.path)\(missing ? ", not found" : "")\(again ? ", must be allowed again" : "")")
    }
}

struct FolderAccessCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Folder Access…") { openWindow(id: FolderAccessWindow.windowID) }
        }
    }
}
