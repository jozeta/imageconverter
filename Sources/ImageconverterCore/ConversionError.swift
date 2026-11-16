import Foundation

/// Why a single file couldn't be converted.
public enum ConversionError: Error, Equatable, Sendable {
    case unreadable
    /// The header was read but the pixels couldn't be decoded (a damaged file, or memory ran out).
    case decodeFailed
    case tooLarge(pixels: Int)
    /// One side is longer than `DecodeLimits.maxSide`.
    case sideTooLong(side: Int, limit: Int)
    /// Decoding (with working copies) would need more than `limit` bytes.
    case needsTooMuchMemory(limit: Int)
    /// The file itself is over `DecodeLimits.maxFileBytes`.
    case fileTooLarge(limit: Int)
    /// The header declares far more pixels than a file this small can hold.
    case suspectedDecompressionBomb
    case encodeFailed
    case writeFailed(String)
    /// An image step failed; the value is the step's display name.
    case processingFailed(String)
    /// The watermark image is missing or can't be read.
    case watermarkImageUnreadable
    /// The watermark image's bookmark no longer opens it and its path can't be read (moved, or access gone).
    case watermarkImageNoAccess
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
    /// A Redact step couldn't look for what it hides (Vision failed): writing the image could leak it.
    case redactUnchecked(target: RedactTarget, reason: String)
    /// ML enlarge can't run here: an older macOS, an unsupported Mac, or the model isn't downloaded (the batch,
    /// jobs and the command line never download it).
    /// `inApp`: said in the app's own batch or preview ("Download it in the Resize step").
    case mlEnlargeUnavailable(MLEnlargeAvailability, inApp: Bool = false)
    /// The enlargement model didn't answer for one tile within `MLEnlarge.tileTimeout`; nothing was written.
    case mlEnlargeNoResponse
    /// ML enlarge's result would break the decode limits; the value says which.
    case mlEnlargeTooLarge(String)

    /// True when the new file was written and only trashing the original failed: the item is done (a resumed
    /// run mustn't convert it again).
    public var outputWasCommitted: Bool {
        if case .writeFailed(let detail) = self { return detail.hasPrefix(FileCommitter.trashFailurePrefix) }
        return false
    }

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
        case .sideTooLong(let side, let limit):
            return "Image is too large (\(PixelCount.format(side)) px on one side, limit \(PixelCount.format(limit)) px)"
        case .needsTooMuchMemory(let limit):
            return "Would need more than \(ByteSize.format(limit)) of memory to open"
        case .fileTooLarge(let limit):
            return "File is too large to open (over \(ByteSize.format(limit)))"
        case .suspectedDecompressionBomb:
            return "Image declares far more pixels than its file size can hold (possible decompression bomb)"
        case .encodeFailed:
            return "Couldn't encode the image"
        case .writeFailed(let detail):
            return "Couldn't write the file: \(detail)"
        case .processingFailed(let step):
            return "Couldn't apply the \(step) step"
        case .watermarkImageUnreadable:
            return "Couldn't read the watermark image"
        case .watermarkImageNoAccess:
            return "Couldn't open the watermark image \u{2014} choose it again"
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
        case .redactUnchecked(let target, let reason):
            return "Not written: couldn't check for \(target.displayName.lowercased()) (\(reason))"
        case .mlEnlargeUnavailable(let availability, let inApp):
            return availability.refusal(inApp: inApp)
        case .mlEnlargeNoResponse:
            return "Not enlarged: the enlargement model didn't respond"
        case .mlEnlargeTooLarge(let detail):
            return "Not enlarged: \(detail)"
        }
    }
}

extension ConversionError {
    /// The item failed only because the enlargement model isn't downloaded yet: a job tries it again later
    /// without counting an attempt.
    public var awaitsModelDownload: Bool {
        if case .mlEnlargeUnavailable(let availability, _) = self { return availability.awaitsDownload }
        return false
    }

    /// Failures that can be transient (memory ran out while decoding, processing or encoding), so the batch
    /// tries the file once more at the end. Unreadable files, size limits and watermark problems never change.
    public var isRetryable: Bool {
        switch self {
        // Vision can fail for passing reasons (memory, a busy GPU).
        case .decodeFailed, .encodeFailed, .redactUnchecked: return true
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

/// Pixel counts for messages, e.g. "65,535" (the app is English only).
enum PixelCount {
    static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
