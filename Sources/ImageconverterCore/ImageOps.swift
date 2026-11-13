import CoreGraphics
import CoreText
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
            let region = Geometry.fillCropSourceRect(source: source, scaled: scaledSize, crop: crop)
            guard let kept = image.cropping(to: region) else { throw ConversionError.processingFailed(step) }
            let target = try pixels(crop, step: step)
            if kept.width == target.0, kept.height == target.1 { return kept }
            return try Resampler.scale(kept, to: target, method: options.resampling)
        }
    }

    public static func crop(_ image: CGImage, _ options: CropOptions) throws -> CGImage {
        let rect = Geometry.cropRect(source: CGSize(width: image.width, height: image.height), options: options)
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

    /// Draws a text or image watermark. `asset` is the already loaded watermark image (image content only).
    public static func watermark(_ image: CGImage, _ options: WatermarkOptions, asset: CGImage?) throws -> CGImage {
        let step = StepKind.watermark.displayName
        var line: CTLine?
        var origin = CGPoint.zero
        let contentSize: CGSize
        switch options.content {
        case .text(let text):
            guard !text.text.isEmpty else { return image }
            guard let built = textLine(text) else { return image }
            line = built.line
            origin = built.origin
            contentSize = built.size
        case .image:
            guard let asset else { throw ConversionError.watermarkImageUnreadable }
            contentSize = CGSize(width: asset.width, height: asset.height)
        }
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let rect = Geometry.watermarkRect(imageSize: imageSize, contentSize: contentSize, options: options)
        else { return image }

        let ctx = try context(imageSize, like: image, step: step, alpha: hasAlpha(image))
        draw(image, at: .zero, size: imageSize, in: ctx)
        ctx.setAlpha(CGFloat(options.clampedOpacity))
        if let line, case .text(let text) = options.content {
            ctx.saveGState()
            ctx.setFillColor(cgColor(text.color))
            // The line was measured at `referenceFontSize`; scale it to the rect. `origin` is where the
            // measured box starts relative to the baseline origin.
            let scale = rect.height / contentSize.height
            ctx.translateBy(x: rect.minX - origin.x * scale, y: CGFloat(ctx.height) - rect.maxY - origin.y * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        } else if let asset {
            draw(asset, at: rect.origin, size: rect.size, in: ctx)
        }
        return try finish(ctx, step: step)
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

    private static let referenceFontSize: CGFloat = 100

    private struct TextLine {
        var line: CTLine
        /// The measured box's bottom-left corner relative to the line's origin (baseline start).
        var origin: CGPoint
        var size: CGSize
    }

    /// A line for `text` at the reference size, measured as the union of its typographic box and its
    /// glyph outlines, so tall glyphs (stacked combining marks, emoji) stay inside the rect.
    private static func textLine(_ text: TextWatermark) -> TextLine? {
        // The colour comes from the context, so the opacity and colour apply the same way as for images.
        let attributes = [kCTFontAttributeName: watermarkFont(named: text.fontName),
                          kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, TextWatermark.singleLine(text.text) as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let typographic = CGRect(x: 0, y: -descent, width: CGFloat(width), height: ascent + descent)
        let box = typographic.union(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        return TextLine(line: line, origin: box.origin, size: box.size)
    }

    /// The named font, or the system bold font when it doesn't exist (CoreText substitutes silently).
    private static func watermarkFont(named name: String) -> CTFont {
        let systemBold = CTFontCreateUIFontForLanguage(.emphasizedSystem, referenceFontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, referenceFontSize, nil)
        if name == ".SystemBold" { return systemBold }
        let font = CTFontCreateWithName(name as CFString, referenceFontSize, nil)
        return CTFontCopyPostScriptName(font) as String == name ? font : systemBold
    }

    private static func cgColor(_ color: RGBAColor) -> CGColor {
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
    private static func draw(_ image: CGImage, at origin: CGPoint, size: CGSize, in ctx: CGContext) {
        let rect = CGRect(x: origin.x, y: CGFloat(ctx.height) - origin.y - size.height,
                          width: size.width, height: size.height)
        ctx.draw(image, in: rect)
    }
}
