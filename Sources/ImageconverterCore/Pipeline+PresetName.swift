import Foundation

/// The preset name a pipeline runs as (`Pipeline.presetName`); like the load notes it is not part of equality.
struct PresetNameTag: Equatable, Sendable {
    var name: String?

    static func == (lhs: PresetNameTag, rhs: PresetNameTag) -> Bool { true }
}

extension Pipeline {
    /// The preset this pipeline runs as, for `{preset}` (not saved; never makes pipelines unequal). Set by whoever
    /// starts the run: the app (the selected preset, or the preset a service or link runs), a job with a preset,
    /// the command line's `--preset`. Nil for an unsaved pipeline or a pipeline file.
    public var presetName: String? {
        get { presetTag.name }
        set { presetTag.name = newValue }
    }

    /// This pipeline with `presetName` set to `name`.
    public func named(_ name: String?) -> Pipeline {
        var copy = self
        copy.presetName = name
        return copy
    }
}
