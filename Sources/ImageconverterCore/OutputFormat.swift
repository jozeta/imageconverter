import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image formats the app can write.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, gif, bmp, jpeg2000

    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        case .jpeg2000: return UTType("public.jpeg-2000")!
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
        }
    }

    public var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .jpeg2000: return true
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

    public init(format: OutputFormat = .jpeg, quality: Double = 0.82, tiffCompression: TIFFCompression = .lzw) {
        self.format = format
        self.quality = quality
        self.tiffCompression = tiffCompression
    }
}
