import Foundation

/// A named target size for the resize step. Its `kind` says which resize mode it fills in.
public struct SizePreset: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Exact pixel size, fill and crop.
        case fill(width: Int, height: Int)
        /// Fit inside a pixel box, keeping the aspect ratio.
        case fit(width: Int, height: Int, enlarge: Bool)
        /// Longest edge in pixels, keeping the aspect ratio.
        case longestEdge(Int, enlarge: Bool)
        /// A print sheet (long and short side) at a DPI; the image's orientation picks which way round.
        case print(long: Double, short: Double, unit: PhysicalUnit, dpi: Double)
    }

    public var name: String
    public var kind: Kind

    public var id: String { name }

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Pixel width; for a print preset the long side in pixels, for a longest edge the edge.
    public var width: Int {
        switch kind {
        case .fill(let wide, _), .fit(let wide, _, _): return wide
        case .longestEdge(let edge, _): return edge
        case .print(let long, _, let unit, let dpi): return Geometry.physicalPixels(long, unit: unit, dpi: dpi) ?? 0
        }
    }

    /// Pixel height; for a print preset the short side in pixels, for a longest edge the edge.
    public var height: Int {
        switch kind {
        case .fill(_, let high), .fit(_, let high, _): return high
        case .longestEdge(let edge, _): return edge
        case .print(_, let short, let unit, let dpi): return Geometry.physicalPixels(short, unit: unit, dpi: dpi) ?? 0
        }
    }

    public var mode: ResizeMode {
        switch kind {
        case .fill(let wide, let high): return .exactSize(width: wide, height: high, fill: .fillAndCrop)
        case .fit(let wide, let high, _): return .fitBox(width: wide, height: high)
        case .longestEdge(let edge, _): return .longestEdge(edge)
        case .print(let long, let short, let unit, let dpi):
            return .printSheet(long: long, short: short, unit: unit, dpi: dpi)
        }
    }

    public var allowEnlarge: Bool {
        switch kind {
        case .fill: return true
        case .fit(_, _, let enlarge), .longestEdge(_, let enlarge): return enlarge
        case .print: return true
        }
    }

    /// The size as shown in a menu: "1080 × 1350", "1280 px" or "10 × 15 cm".
    public var sizeLabel: String {
        switch kind {
        case .fill(let wide, let high), .fit(let wide, let high, _): return "\(wide) × \(high)"
        case .longestEdge(let edge, _): return "\(edge) px"
        case .print(let long, let short, let unit, _):
            return "\(Self.number(short)) × \(Self.number(long)) \(unit.displayName)"
        }
    }

    /// Menu text: the name and its size, or just the name when it already is the size.
    public var menuTitle: String { name == sizeLabel ? name : "\(name) (\(sizeLabel))" }

    private static func number(_ value: Double) -> String { String(format: "%g", value) }

    /// `options` with this preset's mode and enlarge rule; resampling, DPI and pad colour are kept.
    /// Print presets carry their own 300 DPI inside the mode.
    public func applied(to options: ResizeOptions) -> ResizeOptions {
        var result = options
        result.mode = mode
        result.allowEnlarge = allowEnlarge
        return result
    }

    /// Exact size, filled and cropped. Enlarges, since platforms want exactly this size.
    static func fillAndCrop(_ name: String, _ width: Int, _ height: Int) -> SizePreset {
        SizePreset(name: name, kind: .fill(width: width, height: height))
    }

    /// Fit inside, never enlarging.
    static func fitInside(_ name: String, _ width: Int, _ height: Int) -> SizePreset {
        SizePreset(name: name, kind: .fit(width: width, height: height, enlarge: false))
    }

    /// Longest edge, never enlarging.
    static func longest(_ name: String, _ edge: Int) -> SizePreset {
        SizePreset(name: name, kind: .longestEdge(edge, enlarge: false))
    }

    /// A print sheet at 300 DPI, named by its size ("10 × 15 cm"): `short` × `long`.
    static func sheet(_ short: Double, _ long: Double, _ unit: PhysicalUnit, name: String? = nil) -> SizePreset {
        let label = "\(number(short)) × \(number(long)) \(unit.displayName)"
        return SizePreset(name: name ?? label, kind: .print(long: long, short: short, unit: unit, dpi: 300))
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
        .fillAndCrop("Pinterest pin", 1000, 1500),
        .fillAndCrop("YouTube banner", 2560, 1440),
        .fillAndCrop("Threads", 1080, 1350),
        .fillAndCrop("Bluesky post", 1000, 1000),
        .fillAndCrop("Bluesky banner", 3000, 1000),
        .fillAndCrop("Mastodon header", 1500, 500),
        .fillAndCrop("Discord banner", 960, 540),
        .fillAndCrop("WhatsApp status", 1080, 1920),
        .fillAndCrop("Snapchat", 1080, 1920),
        .fillAndCrop("Twitch banner", 1200, 480),
        .fillAndCrop("LinkedIn square", 1080, 1080)
    ]

    public static let resolutions: [SizePreset] = [
        .fitInside("720p", 1280, 720),
        .fitInside("1080p", 1920, 1080),
        .fitInside("1440p", 2560, 1440),
        .fitInside("4K", 3840, 2160),
        .fitInside("8K", 7680, 4320)
    ]

    // Print sizes are short side × long side; the image's own orientation decides which way round.

    public static let printPhotoCentimetres: [SizePreset] = [
        .sheet(9, 13, .centimetre), .sheet(10, 15, .centimetre), .sheet(13, 18, .centimetre),
        .sheet(15, 20, .centimetre), .sheet(20, 30, .centimetre), .sheet(30, 40, .centimetre),
        .sheet(30, 45, .centimetre), .sheet(40, 60, .centimetre), .sheet(50, 70, .centimetre)
    ]

    public static let printPhotoInches: [SizePreset] = [
        .sheet(4, 6, .inch), .sheet(5, 7, .inch), .sheet(8, 10, .inch), .sheet(11, 14, .inch), .sheet(16, 20, .inch)
    ]

    public static let printPaper: [SizePreset] = [
        .sheet(10.5, 14.8, .centimetre, name: "A6"), .sheet(14.8, 21, .centimetre, name: "A5"),
        .sheet(21, 29.7, .centimetre, name: "A4"), .sheet(29.7, 42, .centimetre, name: "A3"),
        .sheet(42, 59.4, .centimetre, name: "A2"), .sheet(8.5, 11, .inch, name: "Letter"),
        .sheet(8.5, 14, .inch, name: "Legal"), .sheet(11, 17, .inch, name: "Tabloid")
    ]

    public static let web: [SizePreset] = [
        .longest("Thumbnail", 150), .longest("Small", 640), .longest("Medium", 1280), .longest("Large", 1920),
        .longest("Extra large", 2560), .longest("Email", 1024), .longest("Email large", 1600)
    ]

    public static let devices: [SizePreset] = [
        .fillAndCrop("iPhone 6.1″", 1179, 2556), .fillAndCrop("iPhone Pro Max", 1290, 2796),
        .fillAndCrop("iPad 11″", 1668, 2388), .fillAndCrop("iPad 13″", 2064, 2752),
        .fillAndCrop("MacBook Air 13″", 2560, 1664), .fillAndCrop("MacBook Pro 14″", 3024, 1964),
        .fillAndCrop("MacBook Pro 16″", 3456, 2234), .fillAndCrop("Full HD", 1920, 1080),
        .fillAndCrop("4K UHD", 3840, 2160), .fillAndCrop("5K", 5120, 2880), .fillAndCrop("Ultrawide", 3440, 1440)
    ]

    public static let assets: [SizePreset] = [
        .fillAndCrop("Avatar", 400, 400), .fillAndCrop("Profile", 1000, 1000),
        .fillAndCrop("Favicon 32", 32, 32), .fillAndCrop("Favicon Apple touch 180", 180, 180),
        .fillAndCrop("Favicon 512", 512, 512), .fillAndCrop("Open Graph", 1200, 630),
        .fillAndCrop("Blog header", 1600, 900)
    ]

    /// Every preset, for checks that span the groups.
    public static let all: [SizePreset] = printPhotoCentimetres + printPhotoInches + printPaper + web + devices
        + assets + social + resolutions
}
