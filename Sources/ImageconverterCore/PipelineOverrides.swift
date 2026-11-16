import Foundation

/// Settings that win over a preset's or pipeline file's own: the command line's `--format`, `--quality`,
/// `--max-size`, `--resize`, `--variant`, `--strip-gps` and `--strip-all`, and the Shortcuts actions' options.
/// One place, so the command line and Shortcuts change a pipeline the same way.
public struct PipelineOverrides: Equatable, Sendable {
    public var format: OutputFormat?
    /// 0...1
    public var quality: Double?
    public var maxSizeBytes: Int?
    /// The longest edge in pixels: the first Resize step becomes "longest edge" (switched on), or one is added first.
    public var longEdge: Int?
    /// When non-empty, these replace the extra outputs.
    public var variants: [OutputVariant] = []
    public var stripGPS = false
    /// Really everything: the preset's "keep when removing all" list doesn't apply.
    public var stripAll = false

    public init(format: OutputFormat? = nil, quality: Double? = nil, maxSizeBytes: Int? = nil, longEdge: Int? = nil,
                variants: [OutputVariant] = [], stripGPS: Bool = false, stripAll: Bool = false) {
        self.format = format
        self.quality = quality
        self.maxSizeBytes = maxSizeBytes
        self.longEdge = longEdge
        self.variants = variants
        self.stripGPS = stripGPS
        self.stripAll = stripAll
    }

    public func applied(to base: Pipeline) -> Pipeline {
        var pipeline = base
        if let format { pipeline.output.format = format }
        if let quality { pipeline.output.quality = quality }
        if let maxSizeBytes { pipeline.output.compression = .maxSize(bytes: maxSizeBytes) }
        if let longEdge { Self.setLongestEdge(longEdge, in: &pipeline) }
        if !variants.isEmpty { pipeline.extraOutputs = variants }
        if stripGPS || stripAll {
            pipeline.metadata.isEnabled = true
            pipeline.metadata.isIncluded = true
            if stripGPS { pipeline.metadata.location = .remove }
            if stripAll {
                pipeline.metadata.removeAll = true
                pipeline.metadata.keepWhenRemovingAll = []
            }
        }
        return pipeline
    }

    private static func setLongestEdge(_ edge: Int, in pipeline: inout Pipeline) {
        if let index = pipeline.steps.firstIndex(where: { $0.operation.kind == .resize }),
           case .resize(var resize) = pipeline.steps[index].operation {
            resize.mode = .longestEdge(edge)
            pipeline.steps[index].operation = .resize(resize)
            pipeline.steps[index].isEnabled = true
        } else {
            pipeline.steps.insert(PipelineStep(operation: .resize(ResizeOptions(mode: .longestEdge(edge)))), at: 0)
        }
    }
}
