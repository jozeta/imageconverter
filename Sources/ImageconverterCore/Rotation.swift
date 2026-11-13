import CoreGraphics
import Foundation

public enum Rotation: Int, Codable, CaseIterable, Sendable {
    case none = 0, cw90 = 90, cw180 = 180, cw270 = 270
}

/// What fills the corners an arbitrary rotation leaves empty.
public enum AngleFill: Codable, Equatable, Sendable {
    /// The canvas grows to hold the whole rotated image; the corners get `background`
    /// (a transparent background stays transparent when the output format has alpha).
    case expand(background: RGBAColor)
    /// The largest centred rectangle with the original aspect ratio that lies inside the rotated image.
    case cropToFit
}

public struct RotateFlipOptions: Codable, Equatable, Sendable {
    public var rotation: Rotation
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Degrees, clockwise positive, applied after the 90° rotation and the flips (−180...180).
    public var angle: Double
    public var angleFill: AngleFill

    public static let angleRange: ClosedRange<Double> = -180...180

    public init(rotation: Rotation = .cw90, flipHorizontal: Bool = false, flipVertical: Bool = false,
                angle: Double = 0, angleFill: AngleFill = .expand(background: .white)) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.angle = angle
        self.angleFill = angleFill
    }

    private enum CodingKeys: String, CodingKey {
        case rotation, flipHorizontal, flipVertical, angle, angleFill
    }

    /// Lenient: options saved before the angle existed decode with no extra rotation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rotation: try container.decodeIfPresent(Rotation.self, forKey: .rotation) ?? .none,
                  flipHorizontal: try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false,
                  flipVertical: try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false,
                  angle: Self.clampedAngle(try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0),
                  angleFill: (try? container.decodeIfPresent(AngleFill.self, forKey: .angleFill))
                    ?? .expand(background: .white))
    }

    /// The angle limited to −180...180; non-finite values become 0.
    public static func clampedAngle(_ value: Double) -> Double {
        value.isFinite ? min(max(value, angleRange.lowerBound), angleRange.upperBound) : 0
    }

    /// The angle actually applied: clamped, and 0 when it makes no visible difference.
    var effectiveAngle: Double {
        let clean = Self.clampedAngle(angle)
        return abs(clean) < 1e-6 ? 0 : clean
    }
}

extension Geometry {
    /// The size after the 90° rotation, the flips and the arbitrary angle.
    public static func rotated(source: CGSize, options: RotateFlipOptions) -> CGSize {
        let swapped = options.rotation == .cw90 || options.rotation == .cw270
        let upright = swapped ? CGSize(width: source.height, height: source.width) : source
        let angle = options.effectiveAngle
        guard angle != 0 else { return upright }
        switch options.angleFill {
        case .expand: return angledBounds(upright, degrees: angle)
        case .cropToFit: return angledCrop(upright, degrees: angle)
        }
    }

    /// The pixel size of the bounding box of `size` rotated by `degrees` (rounded up, so nothing is clipped).
    static func angledBounds(_ size: CGSize, degrees: Double) -> CGSize {
        let (cosine, sine) = trig(degrees)
        // Tolerance so float noise (141.42000001) doesn't add a pixel to an exact size.
        let wide = (size.width * cosine + size.height * sine - 1e-6).rounded(.up)
        let high = (size.width * sine + size.height * cosine - 1e-6).rounded(.up)
        return CGSize(width: max(1, wide), height: max(1, high))
    }

    /// The largest centred rectangle with the aspect ratio of `size` that lies inside `size` rotated by
    /// `degrees`, rounded down. Away from right angles it is computed for a source one pixel smaller on
    /// each side, so the antialiased edge of the rotated image never shows in the corners.
    static func angledCrop(_ size: CGSize, degrees: Double) -> CGSize {
        let (cosine, sine) = trig(degrees)
        let wide = max(1, size.width)
        let high = max(1, size.height)
        // A centred w·s × h·s rectangle, turned back into the source's frame, must fit inside it:
        // its bounding box there is (w·s·cos + h·s·sin) × (w·s·sin + h·s·cos).
        let margin: CGFloat = cosine * sine > 1e-9 ? 2 : 0
        let scale = min(max(1, wide - margin) / (wide * cosine + high * sine),
                        max(1, high - margin) / (wide * sine + high * cosine))
        return CGSize(width: max(1, (wide * scale).rounded(.down)), height: max(1, (high * scale).rounded(.down)))
    }

    /// |cos| and |sin| of `degrees`.
    private static func trig(_ degrees: Double) -> (CGFloat, CGFloat) {
        let radians = degrees * .pi / 180
        return (CGFloat(abs(cos(radians))), CGFloat(abs(sin(radians))))
    }
}

extension ImageOps {
    public static func rotateFlip(_ image: CGImage, _ options: RotateFlipOptions) throws -> CGImage {
        let upright = try rightAngle(image, options)
        let angle = options.effectiveAngle
        return angle == 0 ? upright : try rotate(upright, degrees: angle, fill: options.angleFill)
    }

    /// The 90° rotation and the flips.
    private static func rightAngle(_ image: CGImage, _ options: RotateFlipOptions) throws -> CGImage {
        if options.rotation == .none && !options.flipHorizontal && !options.flipVertical { return image }
        let step = StepKind.rotateFlip.displayName
        let wide = CGFloat(image.width)
        let high = CGFloat(image.height)
        let swapped = options.rotation == .cw90 || options.rotation == .cw270
        let out = swapped ? CGSize(width: high, height: wide) : CGSize(width: wide, height: high)
        let ctx = try context(out, like: image, step: step, alpha: hasAlpha(image))
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

    /// Rotates by `degrees` clockwise around the centre, onto an expanded canvas or cropped to fit.
    private static func rotate(_ image: CGImage, degrees: Double, fill angleFill: AngleFill) throws -> CGImage {
        let step = StepKind.rotateFlip.displayName
        let source = CGSize(width: image.width, height: image.height)
        let ctx: CGContext
        switch angleFill {
        case .expand(let background):
            ctx = try context(Geometry.angledBounds(source, degrees: degrees), like: image, step: step,
                              alpha: hasAlpha(image) || background.alpha < 1)
            fill(ctx, color: background)
        case .cropToFit:
            ctx = try context(Geometry.angledCrop(source, degrees: degrees), like: image, step: step,
                              alpha: hasAlpha(image))
        }
        // Core Graphics is y-up, so a clockwise turn is a negative angle.
        ctx.translateBy(x: CGFloat(ctx.width) / 2, y: CGFloat(ctx.height) / 2)
        ctx.rotate(by: -CGFloat(degrees * .pi / 180))
        ctx.draw(image, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                                   width: source.width, height: source.height))
        return try finish(ctx, step: step)
    }
}
