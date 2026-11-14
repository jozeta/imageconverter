import Foundation

/// A named target size for the resize step.
public struct SizePreset: Equatable, Sendable, Identifiable {
    public var name: String
    public var width: Int
    public var height: Int
    public var mode: ResizeMode
    public var allowEnlarge: Bool

    public var id: String { name }

    /// `options` with this preset's mode and enlarge rule; resampling, DPI and pad colour are kept.
    public func applied(to options: ResizeOptions) -> ResizeOptions {
        var result = options
        result.mode = mode
        result.allowEnlarge = allowEnlarge
        return result
    }

    /// Exact size, filled and cropped. Enlarges, since platforms want exactly this size.
    static func fillAndCrop(_ name: String, _ width: Int, _ height: Int) -> SizePreset {
        SizePreset(name: name, width: width, height: height,
                   mode: .exactSize(width: width, height: height, fill: .fillAndCrop), allowEnlarge: true)
    }

    /// Fit inside, never enlarging.
    static func fitInside(_ name: String, _ width: Int, _ height: Int) -> SizePreset {
        SizePreset(name: name, width: width, height: height, mode: .fitBox(width: width, height: height),
                   allowEnlarge: false)
    }
}

/// A crop aspect ratio such as 16:9.
public struct AspectRatio: Equatable, Sendable, Identifiable {
    public var width: Double
    public var height: Double

    public var name: String { "\(Int(width)):\(Int(height))" }
    public var id: String { name }
    public var cropMode: CropMode { .aspect(width: width, height: height) }
}

/// Ready-made sizes for the resize and crop editors.
public enum SizePresets {
    public static let aspectRatios: [AspectRatio] = [
        (1, 1), (4, 5), (4, 3), (3, 2), (5, 4), (16, 9), (9, 16), (21, 9), (2, 3), (3, 4)
    ].map { AspectRatio(width: $0.0, height: $0.1) }

    public static let social: [SizePreset] = [
        .fillAndCrop("Instagram square", 1080, 1080),
        .fillAndCrop("Instagram portrait", 1080, 1350),
        .fillAndCrop("Instagram landscape", 1080, 566),
        .fillAndCrop("Instagram/Facebook/TikTok story", 1080, 1920),
        .fillAndCrop("Facebook post", 1200, 630),
        .fillAndCrop("Facebook cover", 851, 315),
        .fillAndCrop("LinkedIn post", 1200, 627),
        .fillAndCrop("LinkedIn cover", 1584, 396),
        .fillAndCrop("X post", 1600, 900),
        .fillAndCrop("X header", 1500, 500),
        .fillAndCrop("YouTube thumbnail", 1280, 720),
        .fillAndCrop("Pinterest pin", 1000, 1500)
    ]

    public static let resolutions: [SizePreset] = [
        .fitInside("720p", 1280, 720),
        .fitInside("1080p", 1920, 1080),
        .fitInside("1440p", 2560, 1440),
        .fitInside("4K", 3840, 2160),
        .fitInside("8K", 7680, 4320)
    ]
}
