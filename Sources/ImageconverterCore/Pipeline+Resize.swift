import CoreGraphics
import Foundation
import ImageIO

extension Pipeline {
    /// The DPI written to the output for a `sourceWidth` x `sourceHeight` image, or nil to keep the source's.
    ///
    /// Resize steps are walked in order: a physical size always sets its DPI, and it is kept while later
    /// steps don't change the size (so a DPI-only step can't break the print size). A step that changes
    /// the size sets its own DPI, or keeps the one before it when it has none.
    public func outputDPI(sourceWidth: Int, sourceHeight: Int) -> Double? {
        var size = CGSize(width: max(1, sourceWidth), height: max(1, sourceHeight))
        var dpi: Double?
        var pinnedByPhysical = false
        for step in steps where step.isEnabled {
            if case .resize(let options) = step.operation {
                let plan = Geometry.resizePlan(source: size, options: options)
                if options.mode.isPrintSize {
                    dpi = options.effectiveDPI ?? dpi
                    pinnedByPhysical = true
                } else if plan != .unchanged {
                    pinnedByPhysical = false
                    dpi = options.effectiveDPI ?? dpi
                } else if !pinnedByPhysical {
                    dpi = options.effectiveDPI ?? dpi
                }
            }
            size = Self.size(after: step.operation, from: size)
        }
        return dpi
    }

    /// The metadata written with the output: the metadata options with this image's metadata overrides
    /// (`effectiveMetadata`) applied to `source` (and its XMP view `metadata`, see `MetadataOps.output`), the
    /// overrides' removals, then the DPI.
    /// With an enabled Redact step that hides faces, face and person regions are left out of the XMP.
    public func outputProperties(from source: [String: Any], metadata sourceXMP: CGImageMetadata? = nil,
                                 sourceWidth: Int, sourceHeight: Int) -> [String: Any] {
        outputPropertiesNoting(from: source, metadata: sourceXMP, sourceWidth: sourceWidth,
                               sourceHeight: sourceHeight).properties
    }

    /// `outputProperties` and whether face regions were removed from them (for the report note).
    func outputPropertiesNoting(from source: [String: Any], metadata sourceXMP: CGImageMetadata?,
                                sourceWidth: Int, sourceHeight: Int) -> (properties: [String: Any], removedFaces: Bool) {
        // The metadata panel's changes for this image: set fields go in with the step's options, removals and the
        // rating come last, so they win over the step (`MetadataOverrides`).
        var properties = metadataOverrides.finish(MetadataOps.output(effectiveMetadata, properties: source,
                                                                     metadata: sourceXMP))
        var removed = false
        if redactsFaces { (properties, removed) = MetadataOps.removingFaceRegions(from: properties) }
        return (MetadataOps.setDPI(outputDPI(sourceWidth: sourceWidth, sourceHeight: sourceHeight),
                                   format: output.format, in: properties), removed)
    }

    /// Pixels held at once by a Lanczos resize of an `input`-sized image: the input, vImage's copy of
    /// the part being scaled, the scaled buffer and its image copy, plus the canvas when padding.
    /// Other methods draw straight into the result, so the step's input and output cover them.
    /// ML enlarge counts its tiles, the 4× model result and the output (`MLEnlarge.workingPixels`), plus the model's
    /// own session memory (`MLEnlarge.modelSessionPixels`).
    static func resizeWorkingPixels(input: CGSize, options: ResizeOptions) -> Int {
        if case .mlEnlarge(let factor) = options.mode {
            let (sum, overflow) = MLEnlarge.workingPixels(input: input, factor: factor)
                .addingReportingOverflow(MLEnlarge.modelSessionPixels)
            return overflow ? Int.max : sum
        }
        guard options.resampling == .lanczos else { return 0 }
        let source = pixels(input)
        switch Geometry.resizePlan(source: input, options: options) {
        case .unchanged:
            return source
        case .scale(let target):
            return saturatingSum([source, source, pixels(target), pixels(target)])
        case .fitAndPad(let content, let canvas):
            return saturatingSum([source, source, pixels(content), pixels(content), pixels(canvas)])
        case .fillAndCrop(let scaled, let crop):
            let region = Geometry.fillCropSourceRect(source: input, scaled: scaled, crop: crop).size
            return saturatingSum([source, pixels(region), pixels(crop), pixels(crop)])
        }
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }
}

extension ResizeMode {
    /// A mode that names a print size and so carries its own DPI.
    var isPrintSize: Bool {
        switch self {
        case .physical, .printSheet: return true
        default: return false
        }
    }

    /// Enlarging with the super-resolution model (resampling doesn't apply).
    public var isMLEnlarge: Bool {
        if case .mlEnlarge = self { return true }
        return false
    }
}
