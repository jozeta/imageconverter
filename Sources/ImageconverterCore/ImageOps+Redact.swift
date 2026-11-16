import CoreGraphics
import CoreImage
import Foundation

/// Redact drawing: blur, pixelate or fill inside whole-pixel rects; every pixel outside them is copied unchanged.
extension ImageOps {
    /// `rects` are whole-pixel, top-left-origin rects inside `image` (`Redaction.pixelRects`). No rects: the image
    /// itself. Each rect is processed from its own pixels only (edges clamped), so nothing outside it changes.
    public static func redact(_ image: CGImage, _ options: RedactOptions, rects: [CGRect]) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let regions = rects.map { $0.integral.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        guard !regions.isEmpty else { return image }
        let step = StepKind.redact.displayName
        let ctx = try context(bounds.size, like: image, step: step, alpha: hasAlpha(image), keepFloat: true)
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        draw(image, at: .zero, size: bounds.size, in: ctx)
        for region in regions {
            let flipped = CGRect(x: region.minX, y: CGFloat(ctx.height) - region.maxY,
                                 width: region.width, height: region.height)
            switch options.style {
            case .fill:
                var color = options.fillColor
                color.alpha = 1
                ctx.setFillColor(cgColor(color))
                ctx.fill(flipped)
            case .blur, .pixelate:
                guard let patch = image.cropping(to: region),
                      let processed = try? filtered(patch, options, region: region, like: ctx) else {
                    throw ConversionError.processingFailed(step)
                }
                ctx.draw(processed, in: flipped)
            }
        }
        return try finish(ctx, step: step)
    }

    /// The blurred or pixelated patch, rendered in the output's colour space and depth.
    private static func filtered(_ patch: CGImage, _ options: RedactOptions, region: CGRect,
                                 like ctx: CGContext) throws -> CGImage {
        let style = options.style
        let extent = CGRect(x: 0, y: 0, width: patch.width, height: patch.height)
        // Clamped so the blur and the edge blocks only see the patch's own pixels, never transparent black.
        let input = CIImage(cgImage: patch).clampedToExtent()
        let output: CIImage?
        switch style {
        case .blur:
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(input, forKey: kCIInputImageKey)
            filter?.setValue(options.blurRadius(for: region), forKey: kCIInputRadiusKey)
            output = filter?.outputImage
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate")
            filter?.setValue(input, forKey: kCIInputImageKey)
            filter?.setValue(options.blockSize(for: region), forKey: kCIInputScaleKey)
            filter?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            output = filter?.outputImage
        case .fill:
            output = input
        }
        let format: CIFormat = ctx.bitsPerComponent > 16 ? .RGBAf : (ctx.bitsPerComponent > 8 ? .RGBA16 : .RGBA8)
        guard let output, let space = ctx.colorSpace, space.model == .rgb,
              let rendered = SharedCIContext.context.createCGImage(output.cropped(to: extent), from: extent,
                                                                   format: format, colorSpace: space) else {
            return try fallbackFiltered(patch, options, region: region)
        }
        return rendered
    }

    /// Without Core Image's RGB output (a gray image): pixelate or blur by scaling the patch down and back up
    /// with Core Graphics.
    private static func fallbackFiltered(_ patch: CGImage, _ options: RedactOptions, region: CGRect) throws -> CGImage {
        let step = StepKind.redact.displayName
        let style = options.style
        let factor = style == .pixelate ? options.blockSize(for: region) : options.blurRadius(for: region)
        let small = CGSize(width: max(1, (Double(patch.width) / factor).rounded()),
                           height: max(1, (Double(patch.height) / factor).rounded()))
        let shrink = try context(small, like: patch, step: step, alpha: hasAlpha(patch))
        shrink.interpolationQuality = .high
        shrink.draw(patch, in: CGRect(origin: .zero, size: small))
        let reduced = try finish(shrink, step: step)
        let grow = try context(CGSize(width: patch.width, height: patch.height), like: patch, step: step,
                               alpha: hasAlpha(patch))
        grow.interpolationQuality = style == .pixelate ? .none : .high
        grow.draw(reduced, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
        return try finish(grow, step: step)
    }
}
