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
}

public struct ResizeOptions: Codable, Equatable, Sendable {
    public static let dpiRange: ClosedRange<Double> = 1...10_000

    public var mode: ResizeMode
    public var allowEnlarge: Bool
    public var padColor: RGBAColor
    public var resampling: Resampling
    /// Resolution written to the output file (no resampling); nil keeps the source's.
    public var dpi: Double?

    public init(mode: ResizeMode = .maxWidth(1600), allowEnlarge: Bool = false, padColor: RGBAColor = .white,
                resampling: Resampling = .lanczos, dpi: Double? = nil) {
        self.mode = mode
        self.allowEnlarge = allowEnlarge
        self.padColor = padColor
        self.resampling = resampling
        self.dpi = dpi
    }

    private enum CodingKeys: String, CodingKey {
        case mode, allowEnlarge, padColor, resampling, dpi
    }

    /// Lenient: steps saved before resampling and DPI existed take the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(ResizeMode.self, forKey: .mode)
        allowEnlarge = try container.decodeIfPresent(Bool.self, forKey: .allowEnlarge) ?? false
        padColor = try container.decodeIfPresent(RGBAColor.self, forKey: .padColor) ?? .white
        resampling = (try? container.decodeIfPresent(Resampling.self, forKey: .resampling)) ?? .lanczos
        dpi = try? container.decodeIfPresent(Double.self, forKey: .dpi)
    }

    /// The DPI this step writes: a physical size's own DPI (so the print size holds), else `dpi`.
    /// Nil when unset or outside `dpiRange`.
    public var effectiveDPI: Double? {
        let value: Double?
        if case .physical(_, _, _, let physicalDPI) = mode { value = physicalDPI } else { value = dpi }
        guard let value, value.isFinite, Self.dpiRange.contains(value) else { return nil }
        return value
    }
}
