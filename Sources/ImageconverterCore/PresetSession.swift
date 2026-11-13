import Foundation

/// Where "Save" writes the current pipeline.
public enum SaveTarget: Equatable, Sendable {
    case overwrite(UUID)
    case saveAs
}

/// Which preset is selected and the pipeline being edited. While a preset is selected the
/// pipeline here is the source of truth; it differs from the preset once the user edits it.
public struct PresetSession: Equatable, Sendable {
    public private(set) var selected: Preset?
    public var pipeline: Pipeline

    public enum Switch: Equatable, Sendable {
        case done
        case needsConfirmation
    }

    public init(selected: Preset? = nil, pipeline: Pipeline = Pipeline()) {
        self.selected = selected
        self.pipeline = pipeline
    }

    /// An ad hoc pipeline (no preset) is never modified.
    public var isModified: Bool {
        guard let selected else { return false }
        return pipeline != selected.pipeline
    }

    /// Switches to `preset`. With unsaved edits it changes nothing and asks for confirmation
    /// unless `force` is set.
    public mutating func select(_ preset: Preset, force: Bool = false) -> Switch {
        if isModified && !force { return .needsConfirmation }
        selected = preset
        pipeline = preset.pipeline
        return .done
    }

    /// Goes back to ad hoc editing; the pipeline stays as it is.
    public mutating func deselect() {
        selected = nil
    }

    public mutating func resetToPreset() {
        if let selected { pipeline = selected.pipeline }
    }

    public func saveTarget() -> SaveTarget {
        guard let selected, !selected.isBuiltIn else { return .saveAs }
        return .overwrite(selected.id)
    }

    /// The preset was written (or renamed): it becomes the selection with the pipeline saved in it.
    public mutating func didSave(_ preset: Preset) {
        selected = preset
        pipeline = preset.pipeline
    }

    /// Only the name changed; the edited pipeline is kept.
    public mutating func didRename(_ preset: Preset) {
        selected = preset
    }
}
