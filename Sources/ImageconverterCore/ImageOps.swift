import CoreGraphics
import Foundation

/// Pixel operations behind the image steps. Inputs from `Geometry` are top-left origin (y down);
/// Core Graphics contexts are y-up, so every placement goes through `draw`.
public enum ImageOps {
    /// Largest target bitmap we will allocate.
    static let maxPixels = 250_000_000

    // MARK: Steps

    /// `focus` (image pixels, top-left origin) is where a detected fill-and-crop focus is; nil uses the
    /// options' anchor.
    public static func resize(_ image: CGImage, _ options: ResizeOptions, focus: CGRect? = nil) throws -> CGImage {
        let step = StepKind.resize.displayName
        // ML enlarge has one path, `Pipeline.apply` (the injected model, its notes); never a plain scale here.
        if options.mode.isMLEnlarge { throw ConversionError.processingFailed(step) }
        let source = CGSize(width: image.width, height: image.height)
        switch Geometry.resizePlan(source: source, options: options) {
        case .unchanged:
            return image
        case .scale(let size):
            return try Resampler.scale(image, to: pixels(size, step: step), method: options.resampling)
        case .fitAndPad(let content, let canvas):
            let scaled = try Resampler.scale(image, to: pixels(content, step: step), method: options.resampling)
            let ctx = try context(canvas, like: image, step: step,
                                  alpha: hasAlpha(image) || options.padColor.alpha < 1, keepFloat: true)
            fill(ctx, color: options.padColor)
            let origin = Anchor.center.origin(content: content, container: canvas)
            draw(scaled, at: origin, size: content, in: ctx)
            return try finish(ctx, step: step)
        case .fillAndCrop(let scaledSize, let crop):
            // Scale only the part that is kept, so the full scaled image is never built.
            let region = Geometry.fillCropSourceRect(source: source, scaled: scaledSize, crop: crop,
                                                     anchor: options.focus.anchor, focus: focus)
            guard let kept = image.cropping(to: region) else { throw ConversionError.processingFailed(step) }
            let target = try pixels(crop, step: step)
            if kept.width == target.0, kept.height == target.1 { return kept }
            return try Resampler.scale(kept, to: target, method: options.resampling)
        }
    }

    /// `focus` (image pixels, top-left origin) is where a detected focus is; nil uses the options' anchor.
    public static func crop(_ image: CGImage, _ options: CropOptions, focus: CGRect? = nil) throws -> CGImage {
        let rect = Geometry.cropRect(source: CGSize(width: image.width, height: image.height), options: options,
                                     focus: focus)
        guard let cropped = image.cropping(to: rect) else {
            throw ConversionError.processingFailed(StepKind.crop.displayName)
        }
        return cropped
    }

    public static func canvas(_ image: CGImage, _ options: CanvasOptions) throws -> CGImage {
        let step = StepKind.canvas.displayName
        let plan = Geometry.canvas(source: CGSize(width: image.width, height: image.height), options: options)
        let ctx = try context(plan.canvas, like: image, step: step,
                              alpha: hasAlpha(image) || options.background.alpha < 1)
        fill(ctx, color: options.background)
        draw(image, at: plan.imageOrigin, size: CGSize(width: image.width, height: image.height), in: ctx)
        return try finish(ctx, step: step)
    }

    /// The Color step: the profile conversion, then re-color, then reduce colors.
    public static func color(_ image: CGImage, _ options: ColorOptions) throws -> CGImage {
        let converted = try convertColor(image, to: options.profile)
        let recolored = try Recolor.apply(options.recolor, to: converted)
        return try ColorReduce.apply(options.reduce, to: recolored)
    }

    public static func convertColor(_ image: CGImage, to profile: ColorProfile) throws -> CGImage {
        let step = StepKind.colorProfile.displayName
        let width = image.width
        let height = image.height
        switch profile {
        case .keep:
            return image
        case .sRGB, .displayP3:
            let name = profile == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
            guard let space = CGColorSpace(name: name),
                  let ctx = makeContext(width: width, height: height, like: image, space: space,
                                        alpha: hasAlpha(image)) else {
                throw ConversionError.processingFailed(step)
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return try finish(ctx, step: step)
        case .gray:
            // No alpha: transparent pixels are flattened onto white first.
            guard width >= 1, height >= 1, width <= maxPixels / height,
                  let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw ConversionError.processingFailed(step)
            }
            ctx.interpolationQuality = .high
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(rect)
            ctx.draw(image, in: rect)
            return try finish(ctx, step: step)
        }
    }

    // MARK: Helpers

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// A bitmap context in `space` (default: the image's color space); 16 bpc when the source has more than 8.
    /// Opaque (no alpha channel) unless `alpha` is true, so opaque photos stay opaque through a step.
    static func makeContext(width: Int, height: Int, like image: CGImage, space target: CGColorSpace? = nil,
                            alpha: Bool = true, keepFloat: Bool = false) -> CGContext? {
        guard width >= 1, height >= 1, width <= maxPixels / height else { return nil }
        // (bits per component, extra bitmap info), best first.
        var formats: [(Int, CGBitmapInfo)] = [(image.bitsPerComponent > 8 ? 16 : 8, [])]
        if keepFloat, isFloat(image) { formats.insert((32, [.floatComponents, .byteOrder32Little]), at: 0) }
        var infos = [CGImageAlphaInfo.premultipliedLast.rawValue]
        if !alpha { infos.insert(CGImageAlphaInfo.noneSkipLast.rawValue, at: 0) }
        var spaces: [CGColorSpace] = []
        if let own = target ?? image.colorSpace { spaces.append(own) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
        for (bits, extra) in formats {
            for space in spaces {
                for info in infos {
                    if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                           bytesPerRow: 0, space: space, bitmapInfo: info | extra.rawValue) {
                        ctx.interpolationQuality = .high
                        return ctx
                    }
                }
            }
        }
        return nil
    }

    static func isFloat(_ image: CGImage) -> Bool {
        image.bitsPerComponent == 32 && image.bitmapInfo.contains(.floatComponents)
    }

    /// Whole pixel dimensions of a planned size, or a throw when it can't be a bitmap.
    private static func pixels(_ size: CGSize, step: String) throws -> (Int, Int) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= Double(maxPixels), size.height <= Double(maxPixels) else {
            throw ConversionError.processingFailed(step)
        }
        return (Int(size.width), Int(size.height))
    }

    static func context(_ size: CGSize, like image: CGImage, step: String, alpha: Bool,
                        keepFloat: Bool = false) throws -> CGContext {
        let (width, height) = try pixels(size, step: step)
        guard let ctx = makeContext(width: width, height: height, like: image, alpha: alpha,
                                    keepFloat: keepFloat) else {
            throw ConversionError.processingFailed(step)
        }
        return ctx
    }

    static func finish(_ ctx: CGContext, step: String) throws -> CGImage {
        guard let image = ctx.makeImage() else { throw ConversionError.processingFailed(step) }
        return image
    }

    static func cgColor(_ color: RGBAColor) -> CGColor {
        let clamp: (Double) -> CGFloat = { CGFloat($0.isFinite ? min(1, max(0, $0)) : 0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGColor(colorSpace: space, components: [clamp(color.red), clamp(color.green), clamp(color.blue),
                                                       clamp(color.alpha)]) ?? CGColor(gray: 1, alpha: 1)
    }

    static func fill(_ ctx: CGContext, color: RGBAColor) {
        let cgColor = cgColor(color)
        ctx.setBlendMode(.copy)
        ctx.setFillColor(cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.setBlendMode(.normal)
    }

    /// Draws `image` with its top-left corner at `origin` (top-left coordinates).
    static func draw(_ image: CGImage, at origin: CGPoint, size: CGSize, in ctx: CGContext) {
        let rect = CGRect(x: origin.x, y: CGFloat(ctx.height) - origin.y - size.height,
                          width: size.width, height: size.height)
        ctx.draw(image, in: rect)
    }
}
