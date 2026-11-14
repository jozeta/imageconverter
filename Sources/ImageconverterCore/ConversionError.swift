import Foundation

/// Why a single file couldn't be converted.
public enum ConversionError: Error, Equatable, Sendable {
    case unreadable
    /// The header was read but the pixels couldn't be decoded (a damaged file, or memory ran out).
    case decodeFailed
    case tooLarge(pixels: Int)
    case encodeFailed
    case writeFailed(String)
    /// An image step failed; the value is the step's display name.
    case processingFailed(String)
    /// The watermark image is missing or can't be read.
    case watermarkImageUnreadable
    /// The SVG watermark uses something outside the allowlist: scripts, animation, entities, advanced CSS, ...
    case watermarkSVGUnsafe
    /// The SVG watermark embeds images or links to other files (`<image>`, `data:`, non-local `href`/`url()`,
    /// `@import`, `xml:base`, style sheet instructions).
    case watermarkSVGExternal
    /// The file isn't well-formed UTF-8 SVG.
    case watermarkSVGInvalid
    /// The SVG watermark file is over the size limit.
    case watermarkSVGTooLarge
    /// This macOS can't render SVG.
    case watermarkSVGUnsupported
    /// Maximum-size compression: even the lowest quality is larger than `limit` bytes.
    case sizeUnreachable(limit: Int, smallest: Int)
    /// A condition skips this file, so there is nothing to estimate (never a batch failure).
    case skippedByCondition

    /// A user-facing English explanation.
    public var reason: String {
        switch self {
        case .unreadable:
            return "Couldn't read this file as an image"
        case .decodeFailed:
            return "Couldn't decode the image (it may be damaged, or memory ran low)"
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
        case .watermarkImageUnreadable:
            return "Couldn't read the watermark image"
        case .watermarkSVGUnsafe:
            return "This SVG uses features that aren't supported (scripts, animation or advanced styling). "
                + "Export it as plain SVG or PNG."
        case .watermarkSVGExternal:
            return "This SVG uses embedded images or links to other files, which aren't allowed. "
                + "Export the logo as plain SVG or PNG."
        case .watermarkSVGInvalid:
            return "This file isn't a valid SVG."
        case .watermarkSVGTooLarge:
            return "This SVG is too large (over \(ByteSize.format(SVGRasterizer.maxFileSize)))."
        case .watermarkSVGUnsupported:
            return "SVG watermarks aren't supported on this version of macOS"
        case .sizeUnreachable(let limit, let smallest):
            return "Can't get under \(ByteSize.format(limit)) (smallest is \(ByteSize.format(smallest)))"
        case .skippedByCondition:
            return ConditionalStep.skippedReason
        }
    }
}

extension ConversionError {
    /// Failures that can be transient (memory ran out while decoding, processing or encoding), so the batch
    /// tries the file once more at the end. Unreadable files, size limits and watermark problems never change.
    public var isRetryable: Bool {
        switch self {
        case .decodeFailed, .encodeFailed: return true
        // A watermark that can't be drawn fails the same way every time.
        case .processingFailed(let step): return step != StepKind.watermark.displayName
        default: return false
        }
    }
}

/// File sizes for messages, e.g. "1.2 MB".
enum ByteSize {
    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
