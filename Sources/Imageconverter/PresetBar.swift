import SwiftUI
import ImageconverterCore

/// Preset picker with save, save as, rename, delete and reset.
struct PresetBar: View {
    @Bindable var model: AppModel
    @State private var pendingSwitch: UUID??
    @State private var showDiscard = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var showClearAll = false
    /// Bumped when a switch is cancelled so the picker redraws with the real selection.
    @State private var pickerReset = 0

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
                .id(pickerReset)
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
                    Divider()
                    Toggle(quickActionTitle, isOn: Binding(
                        get: { model.selectedPinnedForServices },
                        set: { model.setSelectedPinnedForServices($0) }))
                        .disabled(!model.selectedPinnedForServices && !model.canPinSelected)
                        .help(quickActionHelp)
                    Divider()
                    Button("Clear All…") { showClearAll = true }
                        .disabled(!model.canClearAll)
                        .accessibilityLabel("Clear all images and pipeline steps")
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
            Button("Cancel", role: .cancel) { cancelSwitch() }
        }
        .onChange(of: showDiscard) { _, shown in
            // Dismissing the dialog without a choice (Escape) also cancels.
            if !shown, pendingSwitch != nil { cancelSwitch() }
        }
        .disabled(model.isRunning)
        .confirmationDialog("Delete preset \(selectedName)?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Clear all images and pipeline steps?", isPresented: $showClearAll) {
            Button("Clear All", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every image from the list and resets the pipeline. Saved presets and your Save to setting aren't changed.")
        }
        .sheet(isPresented: $model.isSavingAs) {
            NameSheet(title: "Save as preset", initial: "", confirm: "Save", fieldLabel: "Preset name",
                      validate: { [presets = model.allPresets] in
                          _ = try PresetStore.validatedName($0, existing: presets, excluding: nil)
                      }, onSubmit: { try model.saveAs(name: $0) })
        }
        .sheet(isPresented: $showRename) {
            NameSheet(title: "Rename preset", initial: selected?.name ?? "", confirm: "Rename", fieldLabel: "Preset name",
                      validate: { [presets = model.allPresets, id = selected?.id] in
                          _ = try PresetStore.validatedName($0, existing: presets, excluding: id)
                      }, onSubmit: { try model.renameSelected(to: $0) })
        }
    }

    /// Names the Finder service slot while pinned, so the user knows which "Convert with Preset n" it is.
    private var quickActionTitle: String {
        model.selectedServiceSlot.map { "Show in Finder Quick Actions (Preset \($0))" } ?? "Show in Finder Quick Actions"
    }

    private var quickActionHelp: String {
        if selected == nil || selected?.isBuiltIn == true { return "Only your own presets can be shown in Finder." }
        if !model.selectedPinnedForServices && !model.canPinSelected {
            return "At most \(ServicePins.maxPinned) presets can be shown in Finder Quick Actions."
        }
        return "Finder's Quick Actions and Services menus convert the selected files with this preset."
    }

    private func cancelSwitch() {
        pendingSwitch = nil
        pickerReset += 1
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
