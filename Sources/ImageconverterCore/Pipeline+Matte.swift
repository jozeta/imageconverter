import CoreGraphics
import Foundation

extension Pipeline {
    /// The colour (opaque) that outputs without alpha are flattened onto instead of white: the fill colour of the
    /// last enabled Perspective step that leaves transparency (Transparent, or a translucent fill colour) and does
    /// something. Nil keeps the encoder's white.
    public var transparencyMatte: RGBAColor? {
        var matte: RGBAColor?
        for step in steps where step.isEnabled {
            guard case .perspective(let options) = step.operation, !Perspective.isNoOp(options) else { continue }
            let leavesAlpha = options.emptyAreas == .transparent
                || (options.emptyAreas == .color && options.fillColor.alpha < 1)
            if leavesAlpha {
                var color = options.fillColor
                color.alpha = 1
                matte = color
            }
        }
        return matte
    }

    /// `image` as an output in `format` gets it: flattened onto `transparencyMatte` when the format has no alpha
    /// and the image has some, with the note saying so; otherwise unchanged (the encoder's own rules apply).
    /// Each output (the main one and every extra) calls this with its own format.
    public func matted(_ image: CGImage, for format: OutputFormat) -> (image: CGImage, note: String?) {
        guard !format.supportsAlpha, let matte = transparencyMatte, ImageOps.hasAlpha(image),
              let flat = ImageEncoder.flattened(image, onto: matte) else { return (image, nil) }
        return (flat, Perspective.noTransparencyNote(format, color: matte))
    }

    /// `image` as `format` stores it, for showing: `matted`, then, for a format without alpha, flattened onto white
    /// the way `ImageEncoder.encode` flattens it, so the preview never shows transparency a JPEG can't keep.
    public func asWritten(_ image: CGImage, for format: OutputFormat) -> CGImage {
        let shown = matted(image, for: format).image
        guard !format.supportsAlpha, ImageOps.hasAlpha(shown),
              let flat = ImageEncoder.flattened(shown, onto: .white) else { return shown }
        return flat
    }
}
