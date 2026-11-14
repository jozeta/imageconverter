import CoreGraphics
import CoreText
import Foundation

/// Watermark drawing: text or image marks, rotated, tiled, with an optional shadow and outline.
extension ImageOps {
    /// Draws a text or image watermark. `asset` is the already loaded watermark image (image content only);
    /// `context` fills a text watermark's tokens (nil: drawn as typed).
    public static func watermark(_ image: CGImage, _ options: WatermarkOptions, asset: CGImage?,
                                 context: WatermarkTextContext? = nil) throws -> CGImage {
        let step = StepKind.watermark.displayName
        let mark: Mark
        switch options.content {
        case .text(let text):
            let rendered = context.map { WatermarkText.render(text.text, context: $0) } ?? WatermarkText.clean(text.text)
            guard !rendered.isEmpty, let built = textLine(rendered, font: text.fontName) else { return image }
            mark = .text(built, text)
        case .image(let watermark):
            guard let asset else { throw ConversionError.watermarkImageUnreadable }
            mark = .image(asset, watermark.shadow)
        }
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let placement = Geometry.watermarkPlacement(imageSize: imageSize, contentSize: mark.contentSize,
                                                          options: options),
              !placement.centers.isEmpty else { return image }

        let ctx = try ImageOps.context(imageSize, like: image, step: step, alpha: hasAlpha(image))
        draw(image, at: .zero, size: imageSize, in: ctx)
        ctx.setAlpha(CGFloat(options.clampedOpacity))
        for center in placement.centers {
            drawMark(mark, placement: placement, center: center, in: ctx)
        }
        return try finish(ctx, step: step)
    }

    /// What a watermark draws: a measured text line with its style, or an image with its shadow.
    private enum Mark {
        case text(TextLine, TextWatermark)
        case image(CGImage, WatermarkShadow?)

        var contentSize: CGSize {
            switch self {
            case .text(let line, _): return line.size
            case .image(let image, _): return CGSize(width: image.width, height: image.height)
            }
        }

        var shadow: WatermarkShadow? {
            switch self {
            case .text(_, let text): return text.shadow
            case .image(_, let shadow): return shadow
            }
        }
    }

    /// One copy of the mark, rotated about `center` (top-left coordinates). With a shadow or outline the parts
    /// are composed in a transparency layer first, so the opacity and the shadow apply to the mark as a whole.
    private static func drawMark(_ mark: Mark, placement: WatermarkPlacement, center: CGPoint, in ctx: CGContext) {
        let size = placement.markSize
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Core Graphics is y-up, so a clockwise turn is a negative angle.
        ctx.translateBy(x: center.x, y: CGFloat(ctx.height) - center.y)
        ctx.rotate(by: -CGFloat(placement.degrees) * .pi / 180)
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)

        var outlineWidth: CGFloat = 0
        if case .text(_, let text) = mark, let outline = text.outline, outline.clampedWidth > 0 {
            outlineWidth = size.height * CGFloat(outline.clampedWidth) / 100
        }
        let shadow = mark.shadow
        if let shadow {
            // Shadow offsets and blur are in device space, so "down-right" holds whatever the rotation.
            let offset = size.height * CGFloat(shadow.clampedOffset) / 100
            ctx.setShadow(offset: CGSize(width: offset, height: -offset),
                          blur: size.height * CGFloat(shadow.clampedBlur) / 100, color: cgColor(shadow.color))
        }
        let layered = shadow != nil || outlineWidth > 0
        if layered { ctx.beginTransparencyLayer(in: rect.insetBy(dx: -outlineWidth, dy: -outlineWidth), auxiliaryInfo: nil) }
        switch mark {
        case .image(let asset, _):
            ctx.draw(asset, in: rect)
        case .text(let line, let text):
            // The line was measured at `referenceFontSize`; scale it to the rect. `line.origin` is where the
            // measured box starts relative to the baseline origin.
            let scale = size.height / line.size.height
            ctx.translateBy(x: rect.minX - line.origin.x * scale, y: rect.minY - line.origin.y * scale)
            ctx.scaleBy(x: scale, y: scale)
            if outlineWidth > 0, let outline = text.outline {
                // The stroke is centred on the glyph edge and the fill covers its inner half.
                ctx.setTextDrawingMode(.stroke)
                ctx.setLineWidth(2 * outlineWidth / scale)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(cgColor(outline.color))
                ctx.textPosition = .zero
                CTLineDraw(line.line, ctx)
                ctx.setTextDrawingMode(.fill)
            }
            ctx.setFillColor(cgColor(text.color))
            ctx.textPosition = .zero
            CTLineDraw(line.line, ctx)
        }
        if layered { ctx.endTransparencyLayer() }
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
    private static func textLine(_ text: String, font: String) -> TextLine? {
        // The colour comes from the context, so the opacity and colour apply the same way as for images.
        let attributes = [kCTFontAttributeName: watermarkFont(named: font),
                          kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return nil }
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
}
