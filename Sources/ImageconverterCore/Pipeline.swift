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

public struct CropOptions: Codable, Equatable, Sendable {
    public var mode: CropMode
    public var anchor: Anchor

    public init(mode: CropMode = .aspect(width: 1, height: 1), anchor: Anchor = .center) {
        self.mode = mode
        self.anchor = anchor
    }
}

public enum Rotation: Int, Codable, CaseIterable, Sendable {
    case none = 0, cw90 = 90, cw180 = 180, cw270 = 270
}

public struct RotateFlipOptions: Codable, Equatable, Sendable {
    public var rotation: Rotation
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(rotation: Rotation = .cw90, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

public enum CanvasMode: Codable, Equatable, Sendable {
    case padding(pixels: Int)
    case paddingPercent(Double)
    case size(width: Int, height: Int)
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
    case resize, crop, rotateFlip, canvas, colorProfile, adjust, watermark

    public var displayName: String {
        switch self {
        case .resize: return "Resize"
        case .crop: return "Crop"
        case .rotateFlip: return "Rotate / flip"
        case .canvas: return "Canvas / padding"
        case .colorProfile: return "Color profile"
        case .adjust: return "Adjust"
        case .watermark: return "Watermark"
        }
    }

    public var defaultOperation: ImageOperation {
        switch self {
        case .resize: return .resize(ResizeOptions())
        case .crop: return .crop(CropOptions())
        case .rotateFlip: return .rotateFlip(RotateFlipOptions())
        case .canvas: return .canvas(CanvasOptions())
        case .colorProfile: return .colorProfile(.sRGB)
        case .adjust: return .adjust(AdjustOptions())
        case .watermark: return .watermark(WatermarkOptions())
        }
    }
}

public enum ImageOperation: Codable, Equatable, Sendable {
    case resize(ResizeOptions)
    case crop(CropOptions)
    case rotateFlip(RotateFlipOptions)
    case canvas(CanvasOptions)
    case colorProfile(ColorProfile)
    case adjust(AdjustOptions)
    case watermark(WatermarkOptions)

    public var kind: StepKind {
        switch self {
        case .resize: return .resize
        case .crop: return .crop
        case .rotateFlip: return .rotateFlip
        case .canvas: return .canvas
        case .colorProfile: return .colorProfile
        case .adjust: return .adjust
        case .watermark: return .watermark
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

    public init(schemaVersion: Int = 1, steps: [PipelineStep] = [], output: OutputSettings = OutputSettings(),
                metadata: MetadataOptions = MetadataOptions(), rename: RenameOptions = RenameOptions()) {
        self.schemaVersion = schemaVersion
        self.steps = steps
        self.output = output
        self.metadata = metadata
        self.rename = rename
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, steps, output, metadata, rename
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
    public func apply(to image: CGImage, assets: WatermarkAssets = .empty) throws -> CGImage {
        var current = image
        for step in steps where step.isEnabled {
            switch step.operation {
            case .resize(let options): current = try ImageOps.resize(current, options)
            case .crop(let options): current = try ImageOps.crop(current, options)
            case .rotateFlip(let options): current = try ImageOps.rotateFlip(current, options)
            case .canvas(let options): current = try ImageOps.canvas(current, options)
            case .colorProfile(let profile): current = try ImageOps.convertColor(current, to: profile)
            case .adjust(let options): current = try Adjustments.apply(options, to: current)
            case .watermark(let options):
                var asset: CGImage?
                if case .image(let watermark) = options.content { asset = assets.image(for: watermark.path) }
                current = try ImageOps.watermark(current, options, asset: asset)
            }
        }
        return current
    }
}

extension Pipeline {
    /// The largest pixel count any enabled step produces for a `sourceWidth` x `sourceHeight` image
    /// (the source included). Saturates instead of overflowing.
    public func peakPixels(sourceWidth: Int, sourceHeight: Int) -> Int {
        var peak = 0
        walk(sourceWidth: sourceWidth, sourceHeight: sourceHeight) { size, operation in
            let pixels = Self.pixels(size)
            // Core Image keeps intermediates: count an adjust step as 3 working copies of its input.
            if case .adjust(let options) = operation, !options.isNeutral {
                let (tripled, overflow) = pixels.multipliedReportingOverflow(by: 3)
                peak = max(peak, overflow ? Int.max : tripled)
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
            switch Geometry.resizePlan(source: size, options: options) {
            case .unchanged: return size
            case .scale(let target): return target
            case .fitAndPad(_, let canvas): return canvas
            case .fillAndCrop(_, let crop): return crop
            }
        case .crop(let options):
            return Geometry.cropRect(source: size, options: options).size
        case .rotateFlip(let options):
            let swapped = options.rotation == .cw90 || options.rotation == .cw270
            return swapped ? CGSize(width: size.height, height: size.width) : size
        case .canvas(let options):
            return Geometry.canvas(source: size, options: options).canvas
        case .colorProfile, .adjust, .watermark:
            return size
        }
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
