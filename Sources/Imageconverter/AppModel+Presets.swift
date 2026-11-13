import Foundation
import ImageconverterCore

extension AppModel {
    // MARK: Presets

    var allPresets: [Preset] { PresetStore.builtIns + userPresets }

    static func sorted(_ presets: [Preset]) -> [Preset] {
        presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reloadPresets() {
        userPresets = Self.sorted(presetStore.loadAll().presets)
    }

    /// Selects a preset, or goes ad hoc for nil. Returns `.needsConfirmation` when edits would be lost.
    func selectPreset(_ id: UUID?, force: Bool = false) -> PresetSession.Switch {
        guard let id else {
            session.deselect()
            return .done
        }
        guard let preset = allPresets.first(where: { $0.id == id }) else { return .done }
        return session.select(preset, force: force)
    }

    func resetToPreset() { session.resetToPreset() }

    /// Save (⌘S): overwrites a user preset; otherwise opens the "Save as" sheet.
    func saveCurrent() {
        guard case .overwrite(let id) = session.saveTarget(), var preset = session.selected, preset.id == id else {
            isSavingAs = true
            return
        }
        preset.pipeline = session.pipeline
        do {
            try presetStore.save(preset)
            reloadPresets()
            session.didSave(preset)
            toasts.show("Saved preset \(preset.name)", type: .ok)
        } catch {
            toasts.show("Couldn't save the preset", type: .bad, description: Self.message(error))
        }
    }

    /// Saves the current pipeline as a new preset. Throws a user-readable error for a bad name.
    func saveAs(name: String) throws {
        let preset = Preset(name: name, pipeline: session.pipeline)
        try presetStore.save(preset)
        reloadPresets()
        // The stored name is the validated one.
        session.didSave(userPresets.first { $0.id == preset.id } ?? preset)
        toasts.show("Saved preset \(session.selected?.name ?? name)", type: .ok)
    }

    func renameSelected(to name: String) throws {
        guard let selected = session.selected else { return }
        try presetStore.rename(id: selected.id, to: name)
        reloadPresets()
        if let renamed = userPresets.first(where: { $0.id == selected.id }) { session.didRename(renamed) }
    }

    func deleteSelected() {
        guard let selected = session.selected, !selected.isBuiltIn else { return }
        do {
            try presetStore.delete(id: selected.id)
            reloadPresets()
            session.deselect()
            toasts.show("Deleted preset \(selected.name)", type: .info)
        } catch {
            toasts.show("Couldn't delete the preset", type: .bad, description: Self.message(error))
        }
    }

    static func message(_ error: Error) -> String {
        (error as? PresetError)?.reason ?? error.localizedDescription
    }
}
