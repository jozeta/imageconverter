import CoreGraphics
import Foundation

/// Where a crop or canvas is anchored.
public enum Anchor: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    public var displayName: String {
        switch self {
        case .topLeft: return "top left"
        case .top: return "top"
        case .topRight: return "top right"
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        case .bottomLeft: return "bottom left"
        case .bottom: return "bottom"
        case .bottomRight: return "bottom right"
        }
    }
}

/// A color with components in 0...1.
public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// How an exact width x height is reached when the aspect ratio differs.
public enum ExactFill: String, Codable, CaseIterable, Sendable {
    case stretch, fitAndPad, fillAndCrop
}

public enum CropMode: Codable, Equatable, Sendable {
    case size(width: Int, height: Int)
    case aspect(width: Double, height: Double)
}

public enum CanvasMode: Codable, Equatable, Sendable {
    case padding(pixels: Int)
    case paddingPercent(Double)
    case size(width: Int, height: Int)
    /// Grows the canvas (never crops) to this aspect ratio.
    case aspect(width: Double, height: Double)
}

public struct CanvasOptions: Codable, Equatable, Sendable {
    public var mode: CanvasMode
    public var anchor: Anchor
    public var background: RGBAColor

    public init(mode: CanvasMode = .padding(pixels: 20), anchor: Anchor = .center, background: RGBAColor = .white) {
        self.mode = mode
        self.anchor = anchor
        self.background = background
    }
}

public enum ColorProfile: String, Codable, CaseIterable, Sendable {
    case keep, sRGB, displayP3, gray

    public var displayName: String {
        switch self {
        case .keep: return "Keep original"
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .gray: return "Gray"
        }
    }
}

public enum StepKind: String, Codable, CaseIterable, Sendable {
    case resize, crop, rotateFlip, perspective, trim, canvas, colorProfile, adjust, watermark, condition

    public var displayName: String {
        switch self {
        case .resize: return "Resize"
        case .crop: return "Crop"
        case .rotateFlip: return "Rotate / flip"
        case .perspective: return "Perspective"
        case .trim: return "Trim"
        case .canvas: return "Canvas / padding"
        case .colorProfile: return "Color profile"
        case .adjust: return "Adjust"
        case .watermark: return "Watermark"
        case .condition: return "Condition"
        }
    }

    public var defaultOperation: ImageOperation {
        switch self {
        case .resize: return .resize(ResizeOptions())
        case .crop: return .crop(CropOptions())
        case .rotateFlip: return .rotateFlip(RotateFlipOptions())
        case .perspective: return .perspective(PerspectiveOptions())
        case .trim: return .trim(TrimOptions())
        case .canvas: return .canvas(CanvasOptions())
        case .colorProfile: return .colorProfile(.sRGB)
        case .adjust: return .adjust(AdjustOptions())
        case .watermark: return .watermark(WatermarkOptions())
        case .condition: return .condition(ConditionalStep())
        }
    }
}

public enum ImageOperation: Codable, Equatable, Sendable {
    case resize(ResizeOptions)
    case crop(CropOptions)
    case rotateFlip(RotateFlipOptions)
    case perspective(PerspectiveOptions)
    case trim(TrimOptions)
    case canvas(CanvasOptions)
    case colorProfile(ColorProfile)
    case adjust(AdjustOptions)
    case watermark(WatermarkOptions)
    /// If/then/else on the source file's facts; replaced by its chosen branch before anything runs
    /// (`Pipeline.resolved(for:)`).
    case condition(ConditionalStep)

    public var kind: StepKind {
        switch self {
        case .resize: return .resize
        case .crop: return .crop
        case .rotateFlip: return .rotateFlip
        case .perspective: return .perspective
        case .trim: return .trim
        case .canvas: return .canvas
        case .colorProfile: return .colorProfile
        case .adjust: return .adjust
        case .watermark: return .watermark
        case .condition: return .condition
        }
    }
}

public struct PipelineStep: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var operation: ImageOperation

    public init(id: UUID = UUID(), isEnabled: Bool = true, operation: ImageOperation) {
        self.id = id
        self.isEnabled = isEnabled
        self.operation = operation
    }
}

public struct Pipeline: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var steps: [PipelineStep]
    public var output: OutputSettings
    public var metadata: MetadataOptions
    public var rename: RenameOptions
    /// More files written for each image besides `output` (at most `OutputVariant.maxCount`).
    public var extraOutputs: [OutputVariant]
    /// What decoding left out (not saved; never makes pipelines unequal).
    public var loadNotes = PipelineLoadNotes()

    public init(schemaVersion: Int = 1, steps: [PipelineStep] = [], output: OutputSettings = OutputSettings(),
                metadata: MetadataOptions = MetadataOptions(), rename: RenameOptions = RenameOptions(),
                extraOutputs: [OutputVariant] = []) {
        self.schemaVersion = schemaVersion
        self.steps = steps
        self.output = output
        self.metadata = metadata
        self.rename = rename
        self.extraOutputs = extraOutputs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, steps, output, metadata, rename, extraOutputs
    }

    /// Lenient: pipelines saved by older versions lack newer fields, which take their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Element by element: a step this version can't read is skipped, the others are kept in order.
        steps = (try container.decodeIfPresent([LossyStep].self, forKey: .steps) ?? []).compactMap(\.step)
        output = try container.decodeIfPresent(OutputSettings.self, forKey: .output) ?? OutputSettings()
        metadata = try container.decodeIfPresent(MetadataOptions.self, forKey: .metadata) ?? MetadataOptions()
        rename = try container.decodeIfPresent(RenameOptions.self, forKey: .rename) ?? RenameOptions()
        // Element by element too; outputs that can't run (no suffix, a repeated one, too many) are left out.
        let variants = (try? container.decodeIfPresent([LossyVariant].self, forKey: .extraOutputs)) ?? []
        let (kept, notes) = OutputVariant.validated(variants.compactMap(\.variant))
        extraOutputs = kept
        // An output this version can't read (a newer format, broken settings) is left out, and said so.
        let unreadable = variants.filter { $0.variant == nil }.map { OutputVariant.unreadableNote($0.name) }
        loadNotes = PipelineLoadNotes(unreadable + notes)
    }
}

private struct LossyStep: Decodable {
    let step: PipelineStep?

    init(from decoder: Decoder) throws {
        step = try? PipelineStep(from: decoder)
    }
}

extension Pipeline {
    /// Runs the enabled steps in order on `image`.
    public func apply(to image: CGImage, assets: WatermarkAssets = .empty,
                      textContext: WatermarkTextContext? = nil, focus: FocusContext = .system) throws -> CGImage {
        var notes: [String] = []
        return try apply(to: image, assets: assets, textContext: textContext, focus: focus, notes: &notes)
    }

    // One case per step kind keeps the dispatch in one place.
    // swiftlint:disable cyclomatic_complexity
    /// Runs the enabled steps in order on `image`; steps that had nothing to do for a reason the user should
    /// know (e.g. auto perspective found no document) append a short note to `notes`. `textContext` fills a text
    /// watermark's tokens (nil: tokens are drawn as typed). `focus` finds a Crop or Resize step's detected
    /// focus on the image as it arrives at that step (a fallback adds a note).
    public func apply(to image: CGImage, assets: WatermarkAssets = .empty, textContext: WatermarkTextContext? = nil,
                      focus: FocusContext = .system, notes: inout [String]) throws -> CGImage {
        var current = image
        for (index, step) in steps.enumerated() where step.isEnabled {
            switch step.operation {
            case .resize(let options):
                let rect = resizeFocus(options, in: current, step: index, context: focus, notes: &notes)
                current = try ImageOps.resize(current, options, focus: rect)
            case .crop(let options):
                let rect = cropFocus(options, in: current, step: index, context: focus, notes: &notes)
                current = try ImageOps.crop(current, options, focus: rect)
            case .rotateFlip(let options): current = try ImageOps.rotateFlip(current, options)
            case .perspective(let options): current = try Perspective.apply(options, to: current, notes: &notes)
            case .trim(let options): current = try Trim.apply(options, to: current)
            case .canvas(let options): current = try ImageOps.canvas(current, options)
            case .colorProfile(let profile): current = try ImageOps.convertColor(current, to: profile)
            case .adjust(let options): current = try Adjustments.apply(options, to: current)
            case .watermark(let options):
                current = try ImageOps.watermark(current, options, asset: Self.asset(for: options, in: assets),
                                                 context: textContext)
            case .condition:
                // Resolved away before rendering; an unresolved one has no facts to test, so it does nothing.
                continue
            }
        }
        return current
    }
    // swiftlint:enable cyclomatic_complexity

    /// The token context for `source`, or nil when no enabled text watermark uses a token. `properties` is the
    /// header the load already read; the file's creation date is only read when a date token needs it.
    public func watermarkTextContext(source: URL, properties: [String: Any]) -> WatermarkTextContext? {
        let templates = steps.compactMap { step -> String? in
            guard step.isEnabled, case .watermark(let options) = step.operation,
                  case .text(let text) = options.content, WatermarkText.usesTokens(text.text) else { return nil }
            return text.text
        }
        guard !templates.isEmpty else { return nil }
        let created = templates.contains(where: WatermarkText.usesDate)
            ? (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate : nil
        return WatermarkTextContext.make(source: source, properties: properties, metadata: metadata,
                                         fileCreationDate: created)
    }

    /// The loaded image of an image watermark; nil for text.
    private static func asset(for options: WatermarkOptions, in assets: WatermarkAssets) -> CGImage? {
        guard case .image(let watermark) = options.content else { return nil }
        return assets.image(for: watermark.path)
    }
}

extension Pipeline {
    /// The largest pixel count any enabled step produces for a `sourceWidth` x `sourceHeight` image
    /// (the source included). Saturates instead of overflowing.
    public func peakPixels(sourceWidth: Int, sourceHeight: Int) -> Int {
        var peak = 0
        walk(sourceWidth: sourceWidth, sourceHeight: sourceHeight) { size, operation in
            let pixels = Self.pixels(size)
            // Core Image keeps intermediates: count its steps as 3 working copies of the input.
            let copies = operation.map { Self.workingCopies($0) } ?? 1
            if copies > 1 {
                let (product, overflow) = pixels.multipliedReportingOverflow(by: copies)
                peak = max(peak, overflow ? Int.max : product)
            }
            if case .perspective(let options) = operation, options.auto {
                peak = max(peak, Self.autoPerspectiveWorkingPixels(input: size))
            }
            if case .resize(let options) = operation {
                peak = max(peak, Self.resizeWorkingPixels(input: size, options: options))
            }
            peak = max(peak, pixels)
        }
        return peak
    }

    /// The size after all enabled image steps, from `Geometry`.
    public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        var last = CGSize(width: max(1, sourceWidth), height: max(1, sourceHeight))
        walk(sourceWidth: sourceWidth, sourceHeight: sourceHeight) { size, _ in last = size }
        return (Int(Self.clamped(last.width).rounded()), Int(Self.clamped(last.height).rounded()))
    }

    /// Calls `visit` with the source size, then for each enabled step with its input size and operation,
    /// and finally with the output size (operation `nil` for the source and the result).
    private func walk(sourceWidth: Int, sourceHeight: Int, _ visit: (CGSize, ImageOperation?) -> Void) {
        var size = CGSize(width: max(1, sourceWidth), height: max(1, sourceHeight))
        for step in steps where step.isEnabled {
            visit(size, step.operation)
            size = Self.size(after: step.operation, from: size)
        }
        visit(size, nil)
    }

    static func size(after operation: ImageOperation, from size: CGSize) -> CGSize {
        switch operation {
        case .resize(let options):
            return resized(size, options)
        case .crop(let options):
            return Geometry.cropRect(source: size, options: options).size
        case .rotateFlip(let options):
            return Geometry.rotated(source: size, options: options)
        case .perspective(let options):
            // Auto correction depends on the content, and the keystone then runs on the corrected image,
            // so its size is unknown: keep the input size. The manual keystone alone is planned exactly.
            if options.auto { return size }
            return Geometry.perspectiveCrop(source: size, options: options)?.size ?? size
        case .canvas(let options):
            return Geometry.canvas(source: size, options: options).canvas
        case .trim, .colorProfile, .adjust, .watermark, .condition:
            // Trim only ever shrinks, by an amount that depends on the content: the input is an upper bound.
            // It scans in strips, so it needs no input-sized working copy.
            return size
        }
    }

    private static func resized(_ size: CGSize, _ options: ResizeOptions) -> CGSize {
        switch Geometry.resizePlan(source: size, options: options) {
        case .unchanged: return size
        case .scale(let target): return target
        case .fitAndPad(_, let canvas): return canvas
        case .fillAndCrop(_, let crop): return crop
        }
    }

    /// How many input-sized images a step holds at once beyond its output (1 for plain drawing).
    static func workingCopies(_ operation: ImageOperation) -> Int {
        switch operation {
        case .adjust(let options): return options.isNeutral ? 1 : 3
        case .perspective(let options): return Perspective.isNoOp(options) ? 1 : 3
        default: return 1
        }
    }

    /// Auto perspective's corrected image can be larger than its input on one side (its sides are the detected
    /// quad's edges, each at most the diagonal), so count the input copies plus a diagonal-squared result,
    /// capped by the pixel guard that rendering enforces anyway.
    static func autoPerspectiveWorkingPixels(input: CGSize) -> Int {
        let diagonal = (Double(clamped(input.width)) * Double(clamped(input.width))
            + Double(clamped(input.height)) * Double(clamped(input.height))).squareRoot()
        let corrected = Int(min(diagonal * diagonal, Double(ImageOps.maxPixels)))
        let (copies, overflow) = pixels(input).multipliedReportingOverflow(by: 3)
        if overflow { return Int.max }
        let (sum, overflowSum) = copies.addingReportingOverflow(corrected)
        return overflowSum ? Int.max : sum
    }

    /// A dimension limited to 1...Int32.max (1 when not finite), safe to convert to `Int`.
    private static func clamped(_ value: CGFloat) -> Double {
        value.isFinite ? min(max(Double(value), 1), Double(Int32.max)) : 1
    }

    static func pixels(_ size: CGSize) -> Int {
        let wide = clamped(size.width)
        let high = clamped(size.height)
        let (product, overflow) = Int(wide).multipliedReportingOverflow(by: Int(high))
        return overflow ? Int.max : product
    }
}
