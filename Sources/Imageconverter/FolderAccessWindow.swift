import SwiftUI
import ImageconverterCore

/// Help ▸ Folder Access…: the folders imageconverter remembers access to, with Remove and Remove All.
struct FolderAccessWindow: View {
    static let windowID = "folder-access"
    @Bindable var store: AccessStore
    @State private var selection: AccessStore.Grant.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Folder Access").font(LadaGlass.Typography.title)
            Text("Folders you allowed when a run needed them. imageconverter can save into these (and the folders "
                 + "inside them) without asking again. Removing one means it asks the next time it is needed.")
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
                Button("Remove") {
                    if let selection { store.remove(selection) }
                    selection = nil
                }
                .disabled(selection == nil)
                .accessibilityLabel("Remove the selected folder")
                Button("Remove All") {
                    store.removeAll()
                    selection = nil
                }
                .disabled(store.grants.isEmpty)
                Spacer()
            }
            .buttonStyle(.lg(.secondary))
        }
        .padding(LadaGlass.Spacing.l)
        .frame(minWidth: 440, minHeight: 320)
        .lgBackdrop()
        .lgCompact()
        .onAppear { store.activate() }
    }

    private func row(_ grant: AccessStore.Grant) -> some View {
        let missing = store.unavailable.contains(grant.path)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text(grant.name).font(LadaGlass.Typography.body)
                if missing { LGChip("Not found", status: .warn) }
            }
            Text(grant.path).font(LadaGlass.Typography.mono)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(grant.name), \(grant.path)\(missing ? ", not found" : "")")
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
