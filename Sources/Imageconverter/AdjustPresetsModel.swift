import Foundation
import Observation
import ImageconverterCore

/// The built-in looks and saved presets behind the Adjust editor's Presets menu.
@MainActor @Observable
final class AdjustPresetsModel {
    private(set) var presets: [AdjustPreset] = AdjustPresets.builtIns
    @ObservationIgnored private let store: AdjustPresetStore
    @ObservationIgnored private var loaded = false

    init(store: AdjustPresetStore) {
        self.store = store
    }

    var builtIns: [AdjustPreset] { presets.filter(\.isBuiltIn) }
    var saved: [AdjustPreset] { presets.filter { !$0.isBuiltIn } }

    /// Reads the folder once (on the first editor that appears); returns the files that were skipped and why.
    func loadIfNeeded() -> [(file: String, reason: String)] {
        guard !loaded else { return [] }
        loaded = true
        return reload()
    }

    @discardableResult
    private func reload() -> [(file: String, reason: String)] {
        let result = store.load()
        presets = result.templates
        return result.skipped
    }

    /// Throws when `name` can't be used (the same rules `save` and `rename` apply); `excluding` is the preset
    /// being renamed.
    func validate(_ name: String, excluding: UUID? = nil) throws {
        _ = try store.validatedName(name, existing: presets, excluding: excluding)
    }

    func save(name: String, options: AdjustOptions) throws {
        try store.save(AdjustPreset(name: name, options: options))
        reload()
    }

    /// The suggested name for a copy of `preset` ("Dramatic copy").
    func duplicateName(of preset: AdjustPreset) -> String {
        AdjustPresets.duplicate(preset, existing: presets).name
    }

    func rename(_ preset: AdjustPreset, to name: String) throws {
        try store.rename(id: preset.id, to: name)
        reload()
    }

    func delete(_ preset: AdjustPreset) throws {
        try store.delete(id: preset.id)
        reload()
    }
}
