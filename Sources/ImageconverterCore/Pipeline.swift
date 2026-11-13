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

public enum ResizeMode: Codable, Equatable, Sendable {
    case maxWidth(Int)
    case maxHeight(Int)
    case fitBox(width: Int, height: Int)
    case exactWidth(Int)
    case exactHeight(Int)
    case exactSize(width: Int, height: Int, fill: ExactFill)
}

public struct ResizeOptions: Codable, Equatable, Sendable {
    public var mode: ResizeMode
    public var allowEnlarge: Bool
    public var padColor: RGBAColor

    public init(mode: ResizeMode = .maxWidth(1600), allowEnlarge: Bool = false, padColor: RGBAColor = .white) {
        self.mode = mode
        self.allowEnlarge = allowEnlarge
        self.padColor = padColor
    }
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
    case resize, crop, rotateFlip, canvas, colorProfile

    public var displayName: String {
        switch self {
        case .resize: return "Resize"
        case .crop: return "Crop"
        case .rotateFlip: return "Rotate / flip"
        case .canvas: return "Canvas / padding"
        case .colorProfile: return "Color profile"
        }
    }

    public var defaultOperation: ImageOperation {
        switch self {
        case .resize: return .resize(ResizeOptions())
        case .crop: return .crop(CropOptions())
        case .rotateFlip: return .rotateFlip(RotateFlipOptions())
        case .canvas: return .canvas(CanvasOptions())
        case .colorProfile: return .colorProfile(.sRGB)
        }
    }
}

public enum ImageOperation: Codable, Equatable, Sendable {
    case resize(ResizeOptions)
    case crop(CropOptions)
    case rotateFlip(RotateFlipOptions)
    case canvas(CanvasOptions)
    case colorProfile(ColorProfile)

    public var kind: StepKind {
        switch self {
        case .resize: return .resize
        case .crop: return .crop
        case .rotateFlip: return .rotateFlip
        case .canvas: return .canvas
        case .colorProfile: return .colorProfile
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

    public init(schemaVersion: Int = 1, steps: [PipelineStep] = [], output: OutputSettings = OutputSettings()) {
        self.schemaVersion = schemaVersion
        self.steps = steps
        self.output = output
    }
}
