import CoreGraphics
import Foundation

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
                if case .physical = options.mode {
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

    /// The metadata written with the output: the metadata options applied to `source`, then the DPI.
    public func outputProperties(from source: [String: Any], sourceWidth: Int, sourceHeight: Int) -> [String: Any] {
        MetadataOps.setDPI(outputDPI(sourceWidth: sourceWidth, sourceHeight: sourceHeight), format: output.format,
                           in: MetadataOps.apply(metadata, to: source))
    }

    /// Pixels held at once by a Lanczos resize of an `input`-sized image: the input, vImage's copy of
    /// the part being scaled, the scaled buffer and its image copy, plus the canvas when padding.
    /// Other methods draw straight into the result, so the step's input and output cover them.
    static func resizeWorkingPixels(input: CGSize, options: ResizeOptions) -> Int {
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
