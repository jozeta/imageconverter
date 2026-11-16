import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image formats the app can write.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, gif, bmp, jpeg2000, avif

    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        // Not every system knows these; an imported placeholder can't crash and `available()` skips it.
        case .jpeg2000: return UTType("public.jpeg-2000") ?? UTType(importedAs: "public.jpeg-2000")
        case .avif: return UTType("public.avif") ?? UTType(importedAs: "public.avif")
        }
    }

    /// False when the system has no type for this format's identifier.
    var isKnownType: Bool { UTType(utType.identifier) != nil }

    /// File extensions, the preferred one first.
    public var fileExtensions: [String] {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .png: return ["png"]
        case .heic: return ["heic"]
        case .tiff: return ["tif", "tiff"]
        case .gif: return ["gif"]
        case .bmp: return ["bmp"]
        case .jpeg2000: return ["jp2"]
        case .avif: return ["avif"]
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .jpeg2000: return "JPEG 2000"
        case .avif: return "AVIF"
        }
    }

    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .jpeg2000, .avif: return true
        case .png, .tiff, .gif, .bmp: return false
        }
    }

    /// False for formats that can't store transparency (the encoder flattens those onto white).
    public var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: return false
        case .png, .heic, .tiff, .gif, .jpeg2000, .avif: return true
        }
    }

    /// Formats the system can write, in `allCases` order.
    public static func available(writableTypeIdentifiers: [String] = systemWritableTypes()) -> [OutputFormat] {
        allCases.filter { $0.isKnownType && writableTypeIdentifiers.contains($0.utType.identifier) }
    }

    public static func systemWritableTypes() -> [String] {
        (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    }
}

public enum TIFFCompression: String, Codable, Sendable {
    case none, lzw
}

/// How a lossy format picks its quality. Formats without a quality setting ignore it.
public enum CompressionMode: Codable, Equatable, Sendable {
    /// One encode at `OutputSettings.quality`.
    case quality
    /// The highest quality whose file is at most `bytes` (quality 0 with a note if none is).
    case targetSize(bytes: Int)
    /// `OutputSettings.quality`, lowered only as far as needed to stay at most `bytes`; fails if impossible.
    case maxSize(bytes: Int)
    /// The lowest quality that still looks the same (SSIM against the unencoded image).
    case smart

    /// False for size modes with a nonsensical byte count (e.g. from a hand-edited preset).
    var isValid: Bool {
        switch self {
        case .quality, .smart: return true
        case .targetSize(let bytes), .maxSize(let bytes): return bytes > 0
        }
    }
}

public struct OutputSettings: Codable, Equatable, Sendable {
    public var format: OutputFormat
    public var quality: Double
    public var tiffCompression: TIFFCompression
    /// JPEG only: write a progressive file.
    public var progressive: Bool
    /// PNG only: try every ImageIO PNG filter and keep the smallest (lossless, slower).
    public var optimizePNG: Bool
    /// Formats with `supportsQuality` only.
    public var compression: CompressionMode

    public static let defaultQuality = 0.82

    /// `quality` limited to 0…1 (NaN takes the default).
    public var clampedQuality: Double { Self.clampQuality(quality) }

    static func clampQuality(_ quality: Double) -> Double {
        quality.isNaN ? defaultQuality : min(1, max(0, quality))
    }

    public init(format: OutputFormat = .jpeg, quality: Double = OutputSettings.defaultQuality,
                tiffCompression: TIFFCompression = .lzw,
                progressive: Bool = false, optimizePNG: Bool = true, compression: CompressionMode = .quality) {
        self.format = format
        self.quality = quality
        self.tiffCompression = tiffCompression
        self.progressive = progressive
        self.optimizePNG = optimizePNG
        self.compression = compression
    }

    private enum CodingKeys: String, CodingKey {
        case format, quality, tiffCompression, progressive, optimizePNG, compression
    }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(OutputFormat.self, forKey: .format) ?? .jpeg
        quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? Self.defaultQuality
        tiffCompression = try container.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression) ?? .lzw
        progressive = try container.decodeIfPresent(Bool.self, forKey: .progressive) ?? false
        optimizePNG = try container.decodeIfPresent(Bool.self, forKey: .optimizePNG) ?? true
        // An unknown or invalid mode (newer or edited preset) falls back to plain quality.
        let mode = (try? container.decodeIfPresent(CompressionMode.self, forKey: .compression)) ?? .quality
        compression = mode.isValid ? mode : .quality
    }
}
