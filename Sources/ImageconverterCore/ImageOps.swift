import CoreGraphics
import Foundation

/// Pixel operations behind the image steps. Inputs from `Geometry` are top-left origin (y down);
/// Core Graphics contexts are y-up, so every placement goes through `draw`.
public enum ImageOps {
    /// Largest target bitmap we will allocate.
    static let maxPixels = 250_000_000

    // MARK: Steps

    public static func resize(_ image: CGImage, _ options: ResizeOptions) throws -> CGImage {
        let step = StepKind.resize.displayName
        let source = CGSize(width: image.width, height: image.height)
        switch Geometry.resizePlan(source: source, options: options) {
        case .unchanged:
            return image
        case .scale(let size):
            let ctx = try context(size, like: image, step: step)
            draw(image, at: .zero, size: size, in: ctx)
            return try finish(ctx, step: step)
        case .fitAndPad(let content, let canvas):
            let ctx = try context(canvas, like: image, step: step)
            fill(ctx, color: options.padColor)
            let origin = Anchor.center.origin(content: content, container: canvas)
            draw(image, at: origin, size: content, in: ctx)
            return try finish(ctx, step: step)
        case .fillAndCrop(let scaled, let crop):
            let ctx = try context(crop, like: image, step: step)
            let origin = Anchor.center.origin(content: scaled, container: crop)
            draw(image, at: origin, size: scaled, in: ctx)
            return try finish(ctx, step: step)
        }
    }

    public static func crop(_ image: CGImage, _ options: CropOptions) throws -> CGImage {
        let rect = Geometry.cropRect(source: CGSize(width: image.width, height: image.height), options: options)
        guard let cropped = image.cropping(to: rect) else {
            throw ConversionError.processingFailed(StepKind.crop.displayName)
        }
        return cropped
    }

    public static func rotateFlip(_ image: CGImage, _ options: RotateFlipOptions) throws -> CGImage {
        if options.rotation == .none && !options.flipHorizontal && !options.flipVertical { return image }
        let step = StepKind.rotateFlip.displayName
        let wide = CGFloat(image.width)
        let high = CGFloat(image.height)
        let swapped = options.rotation == .cw90 || options.rotation == .cw270
        let out = swapped ? CGSize(width: high, height: wide) : CGSize(width: wide, height: high)
        let ctx = try context(out, like: image, step: step)
        // Flips act on the rotated result, so they are applied to the CTM first.
        if options.flipHorizontal {
            ctx.translateBy(x: out.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        if options.flipVertical {
            ctx.translateBy(x: 0, y: out.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        switch options.rotation {
        case .none:
            break
        case .cw90:
            ctx.translateBy(x: 0, y: wide)
            ctx.rotate(by: -.pi / 2)
        case .cw180:
            ctx.translateBy(x: wide, y: high)
            ctx.rotate(by: .pi)
        case .cw270:
            ctx.translateBy(x: high, y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: high))
        return try finish(ctx, step: step)
    }

    public static func canvas(_ image: CGImage, _ options: CanvasOptions) throws -> CGImage {
        let step = StepKind.canvas.displayName
        let plan = Geometry.canvas(source: CGSize(width: image.width, height: image.height), options: options)
        let ctx = try context(plan.canvas, like: image, step: step)
        fill(ctx, color: options.background)
        draw(image, at: plan.imageOrigin, size: CGSize(width: image.width, height: image.height), in: ctx)
        return try finish(ctx, step: step)
    }

    // MARK: Helpers

    /// A bitmap context in the image's color space; 16 bpc when the source has more than 8.
    static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        guard width >= 1, height >= 1, width <= maxPixels / height else { return nil }
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace { spaces.append(own) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
        for space in spaces {
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                   bytesPerRow: 0, space: space, bitmapInfo: info) {
                ctx.interpolationQuality = .high
                return ctx
            }
        }
        return nil
    }

    private static func context(_ size: CGSize, like image: CGImage, step: String) throws -> CGContext {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= Double(maxPixels), size.height <= Double(maxPixels),
              let ctx = makeContext(width: Int(size.width), height: Int(size.height), like: image) else {
            throw ConversionError.processingFailed(step)
        }
        return ctx
    }

    private static func finish(_ ctx: CGContext, step: String) throws -> CGImage {
        guard let image = ctx.makeImage() else { throw ConversionError.processingFailed(step) }
        return image
    }

    private static func fill(_ ctx: CGContext, color: RGBAColor) {
        let clamp: (Double) -> CGFloat = { CGFloat($0.isFinite ? min(1, max(0, $0)) : 0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let components = [clamp(color.red), clamp(color.green), clamp(color.blue), clamp(color.alpha)]
        guard let cgColor = CGColor(colorSpace: space, components: components) else { return }
        ctx.setBlendMode(.copy)
        ctx.setFillColor(cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.setBlendMode(.normal)
    }

    /// Draws `image` with its top-left corner at `origin` (top-left coordinates).
    private static func draw(_ image: CGImage, at origin: CGPoint, size: CGSize, in ctx: CGContext) {
        let rect = CGRect(x: origin.x, y: CGFloat(ctx.height) - origin.y - size.height,
                          width: size.width, height: size.height)
        ctx.draw(image, in: rect)
    }
}
