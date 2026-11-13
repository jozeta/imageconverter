import SwiftUI
import ImageconverterCore

/// Preset picker with save, save as, rename, delete and reset.
struct PresetBar: View {
    @Bindable var model: AppModel
    @State private var pendingSwitch: UUID??
    @State private var showDiscard = false
    @State private var showRename = false
    @State private var showDelete = false

    private var selected: Preset? { model.session.selected }
    private var selectedName: String { selected?.name ?? "this preset" }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Picker("Preset", selection: selection) {
                    Text("None (ad hoc)").tag(UUID?.none)
                    Divider()
                    ForEach(PresetStore.builtIns) { Text($0.name).tag(Optional($0.id)) }
                    if !model.userPresets.isEmpty {
                        Divider()
                        ForEach(model.userPresets) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                .accessibilityLabel("Preset")
                if model.session.isModified {
                    Text("•")
                        .foregroundStyle(LadaGlass.accent.color)
                        .accessibilityLabel("Modified")
                        .help("Modified since the preset was saved")
                }
            }
            HStack(spacing: LadaGlass.Spacing.s) {
                Button(selected?.isBuiltIn == false ? "Save" : "Save as…") { model.saveCurrent() }
                    .buttonStyle(.lg(.secondary))
                    .accessibilityLabel(selected?.isBuiltIn == false ? "Save preset" : "Save as a new preset")
                Menu("More") {
                    Button("Save as…") { model.isSavingAs = true }
                    Button("Rename…") { showRename = true }
                        .disabled(selected == nil || selected?.isBuiltIn == true)
                    Button("Delete…") { showDelete = true }
                        .disabled(selected == nil || selected?.isBuiltIn == true)
                    Button("Reset to preset") { model.resetToPreset() }
                        .disabled(!model.session.isModified)
                }
                .fixedSize()
                .accessibilityLabel("More preset actions")
            }
        }
        .confirmationDialog("Discard changes to \(selectedName)?", isPresented: $showDiscard) {
            Button("Discard", role: .destructive) {
                if let target = pendingSwitch { _ = model.selectPreset(target, force: true) }
                pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) { pendingSwitch = nil }
        }
        .confirmationDialog("Delete preset \(selectedName)?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $model.isSavingAs) {
            PresetNameSheet(title: "Save as preset", initial: "", confirm: "Save",
                            excluding: nil, existing: model.allPresets) { try model.saveAs(name: $0) }
        }
        .sheet(isPresented: $showRename) {
            PresetNameSheet(title: "Rename preset", initial: selected?.name ?? "", confirm: "Rename",
                            excluding: selected?.id, existing: model.allPresets) { try model.renameSelected(to: $0) }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { selected?.id },
            set: { new in
                guard new != selected?.id else { return }
                if model.selectPreset(new) == .needsConfirmation {
                    pendingSwitch = .some(new)
                    showDiscard = true
                }
            })
    }
}

/// A name field with inline validation, shared by "Save as" and "Rename".
private struct PresetNameSheet: View {
    let title: String
    let initial: String
    let confirm: String
    let excluding: UUID?
    let existing: [Preset]
    let onSubmit: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// The reason the typed name can't be used yet (nil when it is fine).
    private var problem: String? {
        do {
            _ = try PresetStore.validatedName(name, existing: existing, excluding: excluding)
            return nil
        } catch {
            return AppModel.message(error)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text(title).font(LadaGlass.Typography.body.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Preset name")
            if let message = failure ?? (name.isEmpty ? nil : problem) {
                Text(message)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
                    .accessibilityLabel("Problem: \(message)")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.lg(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .buttonStyle(.lg(.primary))
                    .disabled(problem != nil)
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(minWidth: 300)
        .lgSheetSurface()
        .onAppear {
            name = initial
            focused = true
        }
        .onChange(of: name) { _, _ in failure = nil }
    }

    private func submit() {
        guard problem == nil else { return }
        do {
            try onSubmit(name)
            dismiss()
        } catch {
            failure = AppModel.message(error)
        }
    }
}
