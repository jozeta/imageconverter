import CoreGraphics
import Foundation

extension Anchor {
    /// Top-left of `content` placed in `container`, in top-left-origin coordinates (y down).
    /// Centred offsets use floor; the result may be negative when the content is larger.
    public func origin(content: CGSize, container: CGSize) -> CGPoint {
        let freeWidth = container.width - content.width
        let freeHeight = container.height - content.height
        let originX: CGFloat
        switch self {
        case .topLeft, .left, .bottomLeft: originX = 0
        case .top, .center, .bottom: originX = (freeWidth / 2).rounded(.down)
        case .topRight, .right, .bottomRight: originX = freeWidth
        }
        let originY: CGFloat
        switch self {
        case .topLeft, .top, .topRight: originY = 0
        case .left, .center, .right: originY = (freeHeight / 2).rounded(.down)
        case .bottomLeft, .bottom, .bottomRight: originY = freeHeight
        }
        return CGPoint(x: originX, y: originY)
    }
}

/// What a resize step has to do to one source image.
public enum ResizePlan: Equatable {
    case unchanged
    case scale(to: CGSize) // swiftlint:disable:this identifier_name
    case fitAndPad(content: CGSize, canvas: CGSize)
    /// Sizes only: the crop is centred in the scaled image.
    case fillAndCrop(scaled: CGSize, crop: CGSize)
}

/// Pure size and position maths for the image steps (top-left origin, y down).
public enum Geometry {
    // MARK: Resize

    public static func resizePlan(source: CGSize, options: ResizeOptions) -> ResizePlan {
        let srcW = max(1, source.width)
        let srcH = max(1, source.height)
        if case .exactSize(let wide, let high, let fill) = options.mode {
            return exactPlan(source: source, target: CGSize(width: dimension(wide), height: dimension(high)),
                             fill: fill, enlarge: options.allowEnlarge)
        }
        guard let factor = scaleFactor(options.mode, width: srcW, height: srcH) else { return .unchanged }
        let ratio: Double
        if case .minimum = options.mode {
            // Only ever enlarges, so "don't enlarge" doesn't apply.
            guard factor > 1 else { return .unchanged }
            ratio = factor
        } else {
            ratio = options.allowEnlarge ? factor : min(factor, 1)
        }
        return scalePlan(CGSize(width: round(srcW * ratio), height: round(srcH * ratio)), source: source)
    }

    /// The uniform scale factor a keep-aspect mode asks for, before the enlarge rule; nil for no change.
    private static func scaleFactor(_ mode: ResizeMode, width srcW: Double, height srcH: Double) -> Double? {
        switch mode {
        case .maxWidth(let wide), .exactWidth(let wide):
            return dimension(wide) / srcW
        case .maxHeight(let high), .exactHeight(let high):
            return dimension(high) / srcH
        case .fitBox(let wide, let high):
            return min(dimension(wide) / srcW, dimension(high) / srcH)
        case .percent(let percent):
            return percent.isFinite ? min(max(percent, 1), 1000) / 100 : nil
        case .longestEdge(let edge):
            return dimension(edge) / max(srcW, srcH)
        case .shortestEdge(let edge):
            return dimension(edge) / min(srcW, srcH)
        case .minimum(let wide, let high):
            return max(dimension(wide) / srcW, dimension(high) / srcH)
        case .physical(let wide, let high, let unit, let dpi):
            // Two sides fit inside; one side keeps the aspect ratio.
            let pixels = { (side: Double?) in side.flatMap { physicalPixels($0, unit: unit, dpi: dpi) } }
            return [pixels(wide).map { Double($0) / srcW }, pixels(high).map { Double($0) / srcH }]
                .compactMap { $0 }.min()
        case .exactSize:
            return nil
        }
    }

    private static func exactPlan(source: CGSize, target: CGSize, fill: ExactFill, enlarge: Bool) -> ResizePlan {
        let srcW = max(1, source.width)
        let srcH = max(1, source.height)
        switch fill {
        case .stretch:
            return scalePlan(target, source: source)
        case .fitAndPad:
            let ratio = min(target.width / srcW, target.height / srcH)
            let capped = enlarge ? ratio : min(ratio, 1)
            let content = CGSize(width: round(srcW * capped), height: round(srcH * capped))
            if content == target { return scalePlan(content, source: source) }
            return .fitAndPad(content: content, canvas: target)
        case .fillAndCrop:
            let ratio = max(target.width / srcW, target.height / srcH)
            let capped = enlarge ? ratio : min(ratio, 1)
            let scaledSize = CGSize(width: round(srcW * capped), height: round(srcH * capped))
            let crop = CGSize(width: min(target.width, scaledSize.width),
                              height: min(target.height, scaledSize.height))
            if crop == scaledSize { return scalePlan(scaledSize, source: source) }
            return .fillAndCrop(scaled: scaledSize, crop: crop)
        }
    }

    /// Pixels for a print length: `value` in `unit` at `dpi`, rounded. Nil for a non-finite or
    /// non-positive input; capped at `Int32.max` so it always converts.
    public static func physicalPixels(_ value: Double, unit: PhysicalUnit, dpi: Double) -> Int? {
        guard value.isFinite, value > 0, dpi.isFinite, dpi > 0 else { return nil }
        let inches = unit == .centimetre ? value / 2.54 : value
        let pixels = (inches * dpi).rounded()
        guard pixels.isFinite else { return nil }
        return Int(min(max(pixels, 1), Double(Int32.max)))
    }

    // MARK: Crop

    /// The crop rectangle inside the source, top-left origin.
    public static func cropRect(source: CGSize, options: CropOptions) -> CGRect {
        let srcW = max(1, source.width)
        let srcH = max(1, source.height)
        var size: CGSize
        switch options.mode {
        case .size(let wide, let high):
            size = CGSize(width: dimension(wide), height: dimension(high))
        case .aspect(let wide, let high):
            let ratio = aspectPart(wide) / aspectPart(high)
            if srcW / srcH > ratio {
                size = CGSize(width: round(srcH * ratio), height: srcH)
            } else {
                size = CGSize(width: srcW, height: round(srcW / ratio))
            }
        }
        size = CGSize(width: min(max(1, size.width), srcW), height: min(max(1, size.height), srcH))
        let origin = options.anchor.origin(content: size, container: CGSize(width: srcW, height: srcH))
        return CGRect(origin: origin, size: size)
    }

    // MARK: Canvas

    /// The new canvas size and where the source image sits on it (top-left origin).
    /// The origin is negative when a fixed canvas is smaller than the image, which clips it.
    public static func canvas(source: CGSize, options: CanvasOptions) -> (canvas: CGSize, imageOrigin: CGPoint) {
        let srcW = max(1, source.width)
        let srcH = max(1, source.height)
        let content = CGSize(width: srcW, height: srcH)
        switch options.mode {
        case .padding(let pixels):
            return padded(content, by: Double(max(0, pixels)))
        case .paddingPercent(let percent):
            let clean = percent.isFinite ? max(0, percent) : 0
            return padded(content, by: (min(srcW, srcH) * clean / 100).rounded())
        case .size(let wide, let high):
            let canvas = CGSize(width: dimension(wide), height: dimension(high))
            return (canvas, options.anchor.origin(content: content, container: canvas))
        }
    }

    // MARK: Helpers

    private static func padded(_ content: CGSize, by padding: Double) -> (canvas: CGSize, imageOrigin: CGPoint) {
        (CGSize(width: content.width + 2 * padding, height: content.height + 2 * padding),
         CGPoint(x: padding, y: padding))
    }

    /// A requested pixel dimension, at least 1.
    private static func dimension(_ value: Int) -> Double { Double(max(1, value)) }

    /// An aspect-ratio part: NaN, infinite or non-positive becomes 1.
    private static func aspectPart(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    /// Rounds to a whole pixel, at least 1.
    private static func round(_ value: Double) -> Double { max(1, value.rounded()) }

    private static func scalePlan(_ size: CGSize, source: CGSize) -> ResizePlan {
        size == source ? .unchanged : .scale(to: size)
    }
}
