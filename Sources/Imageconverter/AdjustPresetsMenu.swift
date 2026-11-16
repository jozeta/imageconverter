import SwiftUI
import ImageconverterCore

/// Presets ▸ looks and saved presets (applying one replaces every Adjust value), Save current as…, Duplicate ▸,
/// Rename ▸ and Delete ▸ for the Adjust editor. Built-in looks can be duplicated but not renamed or deleted.
struct AdjustPresetsMenu: View {
    @Binding var options: AdjustOptions
    @Environment(AdjustPresetsModel.self) private var presets: AdjustPresetsModel?
    @Environment(AppModel.self) private var model: AppModel?
    @State private var sheet: SheetKind?
    @State private var pendingDelete: AdjustPreset?

    private enum SheetKind: Identifiable {
        case save
        case duplicate(AdjustPreset)
        case rename(AdjustPreset)

        var id: String {
            switch self {
            case .save: return "save"
            case .duplicate(let preset): return "duplicate-\(preset.id)"
            case .rename(let preset): return "rename-\(preset.id)"
            }
        }
    }

    var body: some View {
        if let presets {
            Menu("Presets") {
                Section("Replaces the current adjustments") {
                    ForEach(presets.builtIns) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                }
                if !presets.saved.isEmpty {
                    Section("Saved") {
                        ForEach(presets.saved) { preset in
                            Button(preset.name) { apply(preset) }
                        }
                    }
                }
                Divider()
                Button("Save current as…") { sheet = .save }
                Menu("Duplicate") {
                    ForEach(presets.builtIns) { preset in
                        Button(preset.name) { sheet = .duplicate(preset) }
                    }
                    if !presets.saved.isEmpty {
                        Divider()
                        ForEach(presets.saved) { preset in
                            Button(preset.name) { sheet = .duplicate(preset) }
                        }
                    }
                }
                Menu("Rename") {
                    ForEach(presets.saved) { preset in
                        Button(preset.name) { sheet = .rename(preset) }
                    }
                }
                .disabled(presets.saved.isEmpty)
                Menu("Delete") {
                    ForEach(presets.saved) { preset in
                        Button(preset.name) { pendingDelete = preset }
                    }
                }
                .disabled(presets.saved.isEmpty)
            }
            .fixedSize()
            .help("Apply a look (replaces the current adjustments) or save your own")
            .accessibilityLabel("Adjust presets")
            .onAppear {
                let skipped = presets.loadIfNeeded()
                if !skipped.isEmpty {
                    model?.toasts.show("Skipped \(skipped.count) preset \(skipped.count == 1 ? "file" : "files")",
                                       type: .info,
                                       description: skipped.map { "\($0.file): \($0.reason)" }.joined(separator: "\n"))
                }
            }
            .sheet(item: $sheet) { kind in nameSheet(kind, presets: presets) }
            .confirmationDialog("Delete preset \(pendingDelete?.name ?? "")?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
    }

    private func apply(_ preset: AdjustPreset) {
        options = preset.options
    }

    @ViewBuilder
    private func nameSheet(_ kind: SheetKind, presets: AdjustPresetsModel) -> some View {
        switch kind {
        case .save:
            NameSheet(title: "Save adjustments as preset", initial: "", confirm: "Save", fieldLabel: "Preset name",
                      validate: { try presets.validate($0) },
                      onSubmit: { name in
                          try presets.save(name: name, options: options)
                          model?.toasts.show("Saved preset \(name)", type: .ok)
                      })
        case .duplicate(let preset):
            NameSheet(title: "Duplicate \(preset.name)", initial: presets.duplicateName(of: preset),
                      confirm: "Duplicate", fieldLabel: "Preset name",
                      validate: { try presets.validate($0) },
                      onSubmit: { name in
                          try presets.save(name: name, options: preset.options)
                          model?.toasts.show("Saved preset \(name)", type: .ok)
                      })
        case .rename(let preset):
            NameSheet(title: "Rename \(preset.name)", initial: preset.name, confirm: "Rename",
                      fieldLabel: "Preset name",
                      validate: { try presets.validate($0, excluding: preset.id) },
                      onSubmit: { name in try presets.rename(preset, to: name) })
        }
    }

    private func delete() {
        guard let preset = pendingDelete, let presets else { return }
        pendingDelete = nil
        do {
            try presets.delete(preset)
            model?.toasts.show("Deleted preset \(preset.name)", type: .info)
        } catch {
            model?.toasts.show("Couldn't delete the preset", type: .bad, description: AppModel.message(error))
        }
    }
}
