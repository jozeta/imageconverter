import Foundation

/// Units for a print size.
public enum PhysicalUnit: String, Codable, CaseIterable, Sendable {
    case inch, centimetre

    public var displayName: String {
        switch self {
        case .inch: return "in"
        case .centimetre: return "cm"
        }
    }
}

/// How pixels are interpolated when an image is scaled.
public enum Resampling: String, Codable, CaseIterable, Sendable {
    case lanczos, bicubic, bilinear, nearest

    public var displayName: String {
        switch self {
        case .lanczos: return "Lanczos"
        case .bicubic: return "Bicubic"
        case .bilinear: return "Bilinear"
        case .nearest: return "Nearest neighbour"
        }
    }
}

public enum ResizeMode: Codable, Equatable, Sendable {
    case maxWidth(Int)
    case maxHeight(Int)
    /// Fit inside the box, keeping the aspect ratio.
    case fitBox(width: Int, height: Int)
    case exactWidth(Int)
    case exactHeight(Int)
    case exactSize(width: Int, height: Int, fill: ExactFill)
    /// Scale both sides by a percentage (1...1000).
    case percent(Double)
    case longestEdge(Int)
    case shortestEdge(Int)
    /// Scale up so both sides are at least this big, keeping the aspect ratio; never shrinks.
    case minimum(width: Int, height: Int)
    /// A print size at `dpi`; a nil side follows the aspect ratio, two sides fit inside.
    case physical(width: Double?, height: Double?, unit: PhysicalUnit, dpi: Double)
    /// A print sheet of `short` × `long` at `dpi`; the image fits inside it turned the way round its own
    /// orientation needs (landscape into long × short, portrait into short × long).
    case printSheet(long: Double, short: Double, unit: PhysicalUnit, dpi: Double)
    /// Enlarge 2×, 3× or 4× with Apple's super-resolution model (macOS 26 and later; `MLEnlarge`). A saved factor
    /// outside 2...4 is brought into it.
    case mlEnlarge(factor: Int)
}

public struct ResizeOptions: Codable, Equatable, Sendable {
    public static let dpiRange: ClosedRange<Double> = 1...10_000

    public var mode: ResizeMode
    public var allowEnlarge: Bool
    public var padColor: RGBAColor
    public var resampling: Resampling
    /// Resolution written to the output file (no resampling); nil keeps the source's.
    public var dpi: Double?
    /// Which part an exact size's "Fill, crop edges" keeps (the centre by default).
    public var focus: CropFocus

    public init(mode: ResizeMode = .maxWidth(1600), allowEnlarge: Bool = false, padColor: RGBAColor = .white,
                resampling: Resampling = .lanczos, dpi: Double? = nil, focus: CropFocus = .default) {
        self.mode = mode
        self.allowEnlarge = allowEnlarge
        self.padColor = padColor
        self.resampling = resampling
        self.dpi = dpi
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case mode, allowEnlarge, padColor, resampling, dpi, focus
    }

    /// True when the mode is an exact size filled and cropped, the only mode that uses `focus`.
    public var cropsToFill: Bool {
        if case .exactSize(_, _, .fillAndCrop) = mode { return true }
        return false
    }

    /// Lenient: steps saved before resampling, DPI and focus existed take the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(ResizeMode.self, forKey: .mode)
        allowEnlarge = try container.decodeIfPresent(Bool.self, forKey: .allowEnlarge) ?? false
        padColor = try container.decodeIfPresent(RGBAColor.self, forKey: .padColor) ?? .white
        resampling = (try? container.decodeIfPresent(Resampling.self, forKey: .resampling)) ?? .lanczos
        dpi = try? container.decodeIfPresent(Double.self, forKey: .dpi)
        focus = (try? container.decodeIfPresent(CropFocus.self, forKey: .focus)) ?? .default
    }

    /// The DPI this step writes: a physical size's own DPI (so the print size holds), else `dpi`.
    /// Nil when unset or outside `dpiRange`.
    public var effectiveDPI: Double? {
        let value: Double?
        switch mode {
        case .physical(_, _, _, let physicalDPI), .printSheet(_, _, _, let physicalDPI): value = physicalDPI
        default: value = dpi
        }
        guard let value, value.isFinite, Self.dpiRange.contains(value) else { return nil }
        return value
    }
}
