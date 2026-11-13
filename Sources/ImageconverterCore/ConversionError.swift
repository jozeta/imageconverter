import Foundation

/// Why a single file couldn't be converted.
public enum ConversionError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge(pixels: Int)
    case encodeFailed
    case writeFailed(String)
    /// An image step failed; the value is the step's display name.
    case processingFailed(String)

    /// A user-facing English explanation.
    public var reason: String {
        switch self {
        case .unreadable:
            return "Couldn't read this file as an image"
        case .tooLarge(let pixels):
            let megapixels = Int((Double(pixels) / 1_000_000).rounded())
            let limit = ImageLoader.defaultMaxPixels / 1_000_000
            return "Image is too large (\(megapixels) MP, limit \(limit) MP)"
        case .encodeFailed:
            return "Couldn't encode the image"
        case .writeFailed(let detail):
            return "Couldn't write the file: \(detail)"
        case .processingFailed(let step):
            return "Couldn't apply the \(step) step"
        }
    }
}
