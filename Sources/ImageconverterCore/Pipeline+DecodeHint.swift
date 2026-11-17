import CoreGraphics
import Foundation

/// How the batch may decode a source smaller than its full size without changing the result.
public struct DecodeHint: Equatable, Sendable {
    /// The longest side to decode at (`kCGImageSourceThumbnailMaxPixelSize`): source / 2^k, the smallest such size
    /// at least twice the resize's target (else source / 2), so the resize still does the real filtering with its
    /// own resampler and a JPEG decodes at a size its DCT scaling makes cheaply.
    public let maxLongSide: Int
    /// The pipeline to run on the smaller image: the first resize becomes an exact scale to the size it would
    /// have produced from the full-size image (a percentage or a fit would otherwise be measured on the smaller
    /// image). Metadata and DPI still come from the original pipeline and source.
    public let pipeline: Pipeline

    /// The size ImageIO decodes a `sourceWidth` x `sourceHeight` source at with this hint (longest side
    /// `maxLongSide`, aspect kept), for memory scheduling.
    public func decodedSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let scale = Double(maxLongSide) / Double(max(1, sourceWidth, sourceHeight))
        return (max(1, Int((Double(sourceWidth) * scale).rounded())), max(1, Int((Double(sourceHeight) * scale).rounded())))
    }
}

extension Pipeline {
    /// A decode hint for a `sourceWidth` x `sourceHeight` (upright) source, or nil to decode at full size.
    ///
    /// Eligible only when the first enabled step that changes the geometry or reads pixels is a resize that
    /// shrinks both sides with a plain scale (no padding or cropping fill), with a filtering resampler (not
    /// nearest neighbour), to less than half the source's longest side. The only steps allowed before it are
    /// 90° turns and flips without an angle: they move pixels without reading them, so they commute with the
    /// scale. Anything else first (crop, rotate by an angle, perspective, trim, canvas, colour profile, adjust,
    /// watermark, or an unresolved condition) needs the full-size pixels, so there is no hint. Conditions are
    /// resolved before the batch asks, so steps a branch adds count like any other.
    public func decodeHint(sourceWidth: Int, sourceHeight: Int) -> DecodeHint? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let longSide = max(sourceWidth, sourceHeight)
        var size = CGSize(width: sourceWidth, height: sourceHeight)
        for (index, step) in steps.enumerated() where step.isEnabled {
            switch step.operation {
            case .rotateFlip(let options) where options.effectiveAngle == 0:
                size = Self.size(after: step.operation, from: size)
            case .resize(let options):
                return Self.hint(for: options, at: index, input: size, longSide: longSide, in: self)
            default:
                return nil
            }
        }
        return nil
    }

    private static func hint(for options: ResizeOptions, at index: Int, input: CGSize, longSide: Int,
                             in pipeline: Pipeline) -> DecodeHint? {
        guard options.resampling != .nearest,
              case .scale(let target) = Geometry.resizePlan(source: input, options: options),
              target.width < input.width, target.height < input.height,
              target.width >= 1, target.height >= 1 else { return nil }
        let twice = 2 * Int(max(target.width, target.height).rounded(.up))
        guard twice < longSide else { return nil }
        // A JPEG decodes cheaply only at source / 2^k (DCT scaling); any other size decodes larger and resamples,
        // which made 2 × target slower than a full decode. The smallest such size at least twice the target, or
        // source / 2 when only the full size is (never between source / 2 and the source).
        let decodeLongSide = PreviewProxy.decodeLongSide(sourceLongSide: longSide, target: twice, jpeg: true)
            ?? (longSide + 1) / 2
        var exact = options
        exact.mode = .exactSize(width: Int(target.width), height: Int(target.height), fill: .stretch)
        // The decoded image is at least twice the target, so this always shrinks; enlarging is allowed only so
        // the exact size can never be refused.
        exact.allowEnlarge = true
        var replaced = pipeline
        replaced.steps[index].operation = .resize(exact)
        return DecodeHint(maxLongSide: decodeLongSide, pipeline: replaced)
    }
}
