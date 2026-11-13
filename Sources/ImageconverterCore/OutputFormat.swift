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
        case .jpeg2000: return UTType("public.jpeg-2000")!
        case .avif: return UTType("public.avif")!
        }
    }

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

    /// Formats the system can write, in `allCases` order.
    public static func available(writableTypeIdentifiers: [String] = systemWritableTypes()) -> [OutputFormat] {
        allCases.filter { writableTypeIdentifiers.contains($0.utType.identifier) }
    }

    public static func systemWritableTypes() -> [String] {
        (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
    }
}

public enum TIFFCompression: String, Codable, Sendable {
    case none, lzw
}

public struct OutputSettings: Codable, Equatable, Sendable {
    public var format: OutputFormat
    public var quality: Double
    public var tiffCompression: TIFFCompression
    /// JPEG only: write a progressive file.
    public var progressive: Bool
    /// PNG only: try every ImageIO PNG filter and keep the smallest (lossless, slower).
    public var optimizePNG: Bool

    public init(format: OutputFormat = .jpeg, quality: Double = 0.82, tiffCompression: TIFFCompression = .lzw,
                progressive: Bool = false, optimizePNG: Bool = true) {
        self.format = format
        self.quality = quality
        self.tiffCompression = tiffCompression
        self.progressive = progressive
        self.optimizePNG = optimizePNG
    }

    private enum CodingKeys: String, CodingKey {
        case format, quality, tiffCompression, progressive, optimizePNG
    }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(OutputFormat.self, forKey: .format) ?? .jpeg
        quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? 0.82
        tiffCompression = try container.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression) ?? .lzw
        progressive = try container.decodeIfPresent(Bool.self, forKey: .progressive) ?? false
        optimizePNG = try container.decodeIfPresent(Bool.self, forKey: .optimizePNG) ?? true
    }
}
