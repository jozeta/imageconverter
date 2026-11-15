import CoreGraphics
import Foundation

/// Whether Apple's image super-resolution model (VideoToolbox, macOS 26 and later) can run on this Mac.
public enum MLEnlargeAvailability: Equatable, Sendable {
    /// Older than macOS 26, or a build made without the macOS 26 SDK.
    case unsupportedOS
    /// macOS 26 or later, but the system reports that this Mac can't run the scaler.
    case unsupportedHardware
    case ready
    /// The model has to be downloaded first; only the Resize editor's Download button starts that.
    case downloadRequired
    /// Downloading; `progress` is 0...1.
    case downloading(progress: Double)

    public var isReady: Bool { self == .ready }

    /// Why an image isn't enlarged here, as the batch, jobs, the command line and the preview report it.
    public var refusal: String {
        switch self {
        case .ready: return ""
        case .unsupportedOS: return "Not enlarged: machine-learning enlargement needs macOS 26 or later."
        case .unsupportedHardware: return "Not enlarged: this Mac can't run Apple's enlargement model."
        case .downloadRequired:
            return "Not enlarged: Apple's enlargement model isn't downloaded. Open imageconverter and download it "
                + "in the Resize step."
        case .downloading:
            return "Not enlarged: Apple's enlargement model is still downloading. Try again when it has finished."
        }
    }

    /// The Resize editor's one-line state (nil when ready).
    public var editorMessage: String? {
        switch self {
        case .ready: return nil
        case .unsupportedOS: return "Needs macOS 26 or later."
        case .unsupportedHardware: return "This Mac can't run Apple's enlargement model."
        case .downloadRequired: return "Apple's enlargement model isn't on this Mac yet."
        case .downloading(let progress):
            return "Downloading Apple's enlargement model\u{2026} \(Int((min(max(progress, 0), 1) * 100).rounded())) %"
        }
    }
}

/// An 8-bit straight (not premultiplied) RGBA tile, rows tightly packed (`4 × width` bytes each).
public struct RGBA8Tile: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// The super-resolution model behind ML enlarge. The app uses `SystemSuperResolution`; tests inject a fake.
/// Nothing here downloads the model: only the app's Resize editor does, after asking.
public protocol SuperResolutionScaler: Sendable {
    /// The model's own scale factor (Apple's image model: 4).
    var factor: Int { get }
    func availability() -> MLEnlargeAvailability
    /// A session for tiles of exactly `width` × `height` in `colorSpace`.
    func makeSession(width: Int, height: Int, colorSpace: CGColorSpace) throws -> any SuperResolutionSession
}

/// Upscales tiles of one size by the scaler's factor; ends its work when released.
public protocol SuperResolutionSession: AnyObject {
    func upscale(_ tile: RGBA8Tile) throws -> RGBA8Tile
}

/// How an image is cut into tiles for the model: at most `maxTile` px per side (Apple's image model takes
/// 1920 × 1920 at most), neighbours overlapping by at least `overlap` px so the seams can be feathered.
public struct MLEnlargeTiling: Equatable, Sendable {
    public static let standard = MLEnlargeTiling(maxTile: 1920, overlap: 64)

    public let maxTile: Int
    public let overlap: Int

    /// `maxTile` is at least 2 and more than twice `overlap`.
    public init(maxTile: Int, overlap: Int) {
        self.maxTile = max(2, maxTile)
        self.overlap = min(max(0, overlap), (self.maxTile - 1) / 2)
    }

    /// One tile's place along an axis.
    public struct Span: Equatable, Sendable {
        public let start: Int
        public let length: Int
        /// How far it overlaps the previous span (0 for the first): the width of the feather.
        public let overlapBefore: Int

        public var end: Int { start + length }
    }

    /// Spans covering 0..<`length`: one when it fits, else the fewest equal spans no longer than `maxTile` that
    /// overlap by at least `overlap`, spread evenly from 0 to the end. Every span lies inside the image, so no
    /// tile is ever padded.
    public func spans(length: Int) -> [Span] {
        let total = max(1, length)
        guard total > maxTile else { return [Span(start: 0, length: total, overlapBefore: 0)] }
        let step = maxTile - overlap
        let count = (total - overlap + step - 1) / step
        // Equal spans just long enough for `count` of them to cover the length with the overlap.
        let size = (total + (count - 1) * overlap + count - 1) / count
        let room = total - size
        var spans: [Span] = []
        for index in 0..<count {
            let start = index == count - 1 ? room : index * room / (count - 1)
            let before = spans.last.map { $0.end - start } ?? 0
            spans.append(Span(start: start, length: size, overlapBefore: before))
        }
        return spans
    }
}

/// Enlarging with Apple's super-resolution model: the Resize step's `.mlEnlarge` mode.
public enum MLEnlarge {
    /// The factors the Resize editor offers.
    public static let factors = [2, 3, 4]

    /// A saved factor brought into 2...4.
    public static func clampedFactor(_ factor: Int) -> Int { min(max(factor, 2), 4) }

    /// The note for a source with more than 8 bits per channel.
    public static let eightBitNote = "ML enlarge works in 8 bits per channel"

    /// The output size: each side times the factor.
    public static func outputSize(of input: CGSize, factor: Int) -> CGSize {
        let scale = Double(clampedFactor(factor))
        return CGSize(width: max(1, input.width.rounded()) * scale, height: max(1, input.height.rounded()) * scale)
    }

    /// Pixels held at once while enlarging an `input`-sized image (for `WorkWindow`, as RGBA8 pixels): the input's
    /// RGBA copy, the output buffer (the result image uses it without a copy), one row strip of the output, one tile
    /// with its half-float
    /// model buffers and its 4× result (and its downsampled copy for 2× and 3×), plus the alpha planes.
    public static func workingPixels(input: CGSize, factor: Int, tiling: MLEnlargeTiling = .standard) -> Int {
        let scale = clampedFactor(factor)
        let width = Int(min(max(1, input.width.rounded()), Double(Int32.max)))
        let height = Int(min(max(1, input.height.rounded()), Double(Int32.max)))
        let tileWidth = tiling.spans(length: width).first?.length ?? width
        let tileHeight = tiling.spans(length: height).first?.length ?? height
        let model = Double(tileWidth) * Double(tileHeight)
        let source = Double(width) * Double(height)
        let output = source * Double(scale * scale)
        let strip = Double(width * scale) * Double(tileHeight * scale)
        // Tile: its RGBA copy (1), half-float source (2), half-float 4× result (32), RGBA 4× result (16),
        // the downsampled tile (scale²; none at 4×).
        let tile = model * (1 + 2 + 32 + 16 + (scale < 4 ? Double(scale * scale) : 0))
        let alpha = (source + output) / 4
        let total = source + output + strip + tile + alpha
        return total >= Double(Int.max) ? Int.max : Int(total.rounded(.up))
    }

    /// Refuses, before any work, an enlargement whose output breaks `limits`: its pixels, its longest side, or the
    /// memory `workingPixels` needs (4 bytes each).
    public static func checkLimits(input: CGSize, factor: Int, limits: DecodeLimits = .standard,
                                   tiling: MLEnlargeTiling = .standard) throws {
        let output = outputSize(of: input, factor: factor)
        let side = Int(min(max(output.width, output.height), Double(Int.max / 2)))
        if side > limits.maxSide {
            throw ConversionError.mlEnlargeTooLarge(
                "the result would be \(PixelCount.format(side)) px on one side (limit \(PixelCount.format(limits.maxSide)) px)")
        }
        let pixels = output.width * output.height
        if pixels > Double(limits.maxPixels) {
            throw ConversionError.mlEnlargeTooLarge(
                "the result would be \(megapixels(pixels)) MP (limit \(megapixels(Double(limits.maxPixels))) MP)")
        }
        let bytes = Double(workingPixels(input: input, factor: factor, tiling: tiling)) * 4
        if bytes > Double(limits.maxDecodedBytes) {
            throw ConversionError.mlEnlargeTooLarge("it would need more than \(ByteSize.format(limits.maxDecodedBytes)) of memory")
        }
    }

    private static func megapixels(_ pixels: Double) -> String {
        PixelCount.format(Int((pixels / 1_000_000).rounded()))
    }
}
