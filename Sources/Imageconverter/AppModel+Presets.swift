import Foundation
import ImageconverterCore

extension AppModel {
    // MARK: Presets

    var allPresets: [Preset] { PresetStore.builtIns + userPresets }

    func reloadPresets() {
        userPresets = PresetStore.userPresets(from: presetStore.loadAll().presets)
        // A selected user preset whose file is gone becomes an ad hoc pipeline (the pipeline is kept).
        if let selected = session.selected, !selected.isBuiltIn, !userPresets.contains(where: { $0.id == selected.id }) {
            session.deselect()
        }
    }

    /// Selects a preset, or goes ad hoc for nil. Returns `.needsConfirmation` when edits would be lost.
    func selectPreset(_ id: UUID?, force: Bool = false) -> PresetSession.Switch {
        guard let id else {
            session.deselect()
            return .done
        }
        guard let preset = allPresets.first(where: { $0.id == id }) else { return .done }
        let result = session.select(preset, force: force)
        if result == .done { refreshWatermarkBookmarks() }
        return result
    }

    func resetToPreset() { session.resetToPreset() }

    /// Save (⌘S): overwrites a user preset; otherwise opens the "Save as" sheet.
    func saveCurrent() {
        guard !isRunning else { return }
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

    /// The selected user preset's "Show in Finder Quick Actions" state; see `ServicePins`.
    var selectedPinnedForServices: Bool {
        guard let id = session.selected?.id else { return false }
        return userPresets.first { $0.id == id }?.pinnedForServices ?? false
    }

    /// Whether the selected preset can be pinned (a user preset, and fewer than five others pinned).
    var canPinSelected: Bool {
        guard let selected = session.selected, !selected.isBuiltIn else { return false }
        return ServicePins.canPin(selected.id, in: userPresets)
    }

    /// The service slot ("Convert with Preset n") the selected preset has while pinned.
    var selectedServiceSlot: Int? {
        guard let id = session.selected?.id else { return nil }
        return userPresets.first { $0.id == id }?.serviceSlot
    }

    func setSelectedPinnedForServices(_ pinned: Bool) {
        guard let selected = session.selected, !selected.isBuiltIn else { return }
        do {
            try presetStore.setPinnedForServices(id: selected.id, pinned)
            reloadPresets()
            // Keeps the session's copy current, so Save doesn't write the old flag back.
            if let updated = userPresets.first(where: { $0.id == selected.id }) { session.didRename(updated) }
            let slot = selectedServiceSlot.map { " as Convert with Preset \($0)" } ?? ""
            toasts.show(pinned ? "\(selected.name) shows in Finder Quick Actions\(slot)"
                               : "\(selected.name) no longer shows in Finder Quick Actions", type: .ok)
        } catch {
            toasts.show("Couldn't change the preset", type: .bad, description: Self.message(error))
        }
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
