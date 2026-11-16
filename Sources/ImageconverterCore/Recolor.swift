import CoreGraphics
import Foundation

/// OKLab (Björn Ottosson, 2020): a perceptual space where L is lightness and (a, b) the colour; chroma is the
/// length of (a, b) and hue its angle. Inputs and outputs are linear sRGB (extended: values outside 0...1 pass).
struct OKLab: Equatable {
    var lightness: Float
    var greenRed: Float
    var blueYellow: Float

    var chroma: Float { (greenRed * greenRed + blueYellow * blueYellow).squareRoot() }
    var hue: Float { atan2(blueYellow, greenRed) }

    init(lightness: Float, greenRed: Float, blueYellow: Float) {
        self.lightness = lightness
        self.greenRed = greenRed
        self.blueYellow = blueYellow
    }

    init(lightness: Float, chroma: Float, hue: Float) {
        self.init(lightness: lightness, greenRed: chroma * cos(hue), blueYellow: chroma * sin(hue))
    }

    init(linearRed red: Float, green: Float, blue: Float) {
        let long = cbrtf(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let medium = cbrtf(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let short = cbrtf(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
        greenRed = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
        blueYellow = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
    }

    /// An sRGB-encoded colour.
    init(_ color: HexColor) {
        let (red, green, blue) = color.components
        self.init(linearRed: Self.linear(Float(red)), green: Self.linear(Float(green)), blue: Self.linear(Float(blue)))
    }

    var linearRGB: (red: Float, green: Float, blue: Float) { // swiftlint:disable:this large_tuple
        let long = lightness + 0.3963377774 * greenRed + 0.2158037573 * blueYellow
        let medium = lightness - 0.1055613458 * greenRed - 0.0638541728 * blueYellow
        let short = lightness - 0.0894841775 * greenRed - 1.2914855480 * blueYellow
        let (cubeL, cubeM, cubeS) = (long * long * long, medium * medium * medium, short * short * short)
        return (4.0767416621 * cubeL - 3.3077115913 * cubeM + 0.2309699292 * cubeS,
                -1.2684380046 * cubeL + 2.6097574011 * cubeM - 0.3413193965 * cubeS,
                -0.0041960863 * cubeL - 0.7034186147 * cubeM + 1.7076147010 * cubeS)
    }

    /// The same lightness and hue with the chroma lowered (bisection) until it fits linear sRGB 0...1.
    var inSRGBGamut: OKLab {
        func fits(_ lab: OKLab) -> Bool {
            let rgb = lab.linearRGB
            let limit: ClosedRange<Float> = -0.0005...1.0005
            return limit.contains(rgb.red) && limit.contains(rgb.green) && limit.contains(rgb.blue)
        }
        let clampedL = OKLab(lightness: min(max(lightness, 0), 1), greenRed: greenRed, blueYellow: blueYellow)
        if fits(clampedL) { return clampedL }
        var (low, high): (Float, Float) = (0, 1)
        for _ in 0..<16 {
            let middle = (low + high) / 2
            let candidate = OKLab(lightness: clampedL.lightness, greenRed: greenRed * middle, blueYellow: blueYellow * middle)
            if fits(candidate) { low = middle } else { high = middle }
        }
        return OKLab(lightness: clampedL.lightness, greenRed: greenRed * low, blueYellow: blueYellow * low)
    }

    func mixed(with other: OKLab, _ amount: Float) -> OKLab {
        OKLab(lightness: lightness + (other.lightness - lightness) * amount,
              greenRed: greenRed + (other.greenRed - greenRed) * amount,
              blueYellow: blueYellow + (other.blueYellow - blueYellow) * amount)
    }

    /// The sRGB transfer curve, decoded.
    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    static let black = OKLab(lightness: 0, greenRed: 0, blueYellow: 0)
    static let white = OKLab(lightness: 1, greenRed: 0, blueYellow: 0)
}

/// The Color step's re-color: tint, duotone, sepia, replace a colour, or shift every hue. Works per pixel in
/// OKLab on a linear extended-sRGB float copy; the result is drawn back in the input's colour space and depth.
public enum Recolor {
    /// The fixed midtone of Sepia: a warm brown.
    static let sepiaTone = HexColor(red: 0xA2, green: 0x82, blue: 0x5A)
    /// Below this OKLab chroma a colour counts as grey: never matched by Replace color unless the source is grey.
    static let neutralChroma: Float = 0.03

    public static func apply(_ raw: RecolorOptions, to image: CGImage) throws -> CGImage {
        let options = raw.clamped
        if options.isNeutral { return image }
        let transform = PixelTransform(options)
        return try LinearBuffer.map(image, step: StepKind.colorProfile.displayName) { lab in transform.apply(lab) }
    }

    /// One re-color as a pure OKLab → OKLab function (nil leaves the pixel exactly as it was).
    struct PixelTransform {
        let options: RecolorOptions
        private let tint: OKLab
        private let shadows: OKLab
        private let highlights: OKLab
        private let source: OKLab
        private let target: OKLab
        private let strength: Float
        private let angle: Float

        init(_ options: RecolorOptions) {
            self.options = options
            tint = OKLab(options.kind == .sepia ? Recolor.sepiaTone : options.tint)
            shadows = OKLab(options.shadows)
            highlights = OKLab(options.highlights)
            source = OKLab(options.source)
            target = OKLab(options.target)
            strength = Float(options.strength / 100)
            angle = Float(options.hueShift * .pi / 180)
        }

        func apply(_ lab: OKLab) -> OKLab? {
            switch options.kind {
            case .none: return nil
            case .tint, .sepia: return lab.mixed(with: toned(lab.lightness), strength)
            case .duotone:
                let amount = min(max(lab.lightness, 0), 1)
                return lab.mixed(with: shadows.mixed(with: highlights, amount), strength)
            case .hueShift:
                let (cosine, sine) = (cos(angle), sin(angle))
                return OKLab(lightness: lab.lightness, greenRed: lab.greenRed * cosine - lab.blueYellow * sine,
                             blueYellow: lab.greenRed * sine + lab.blueYellow * cosine)
            case .replace: return replaced(lab)
            }
        }

        /// Black → the tint (at its own lightness) → white, by lightness.
        private func toned(_ lightness: Float) -> OKLab {
            let level = min(max(lightness, 0), 1)
            let middle = min(max(tint.lightness, 0.05), 0.95)
            if level <= middle { return OKLab.black.mixed(with: tint, level / middle) }
            return tint.mixed(with: OKLab.white, (level - middle) / (1 - middle))
        }

        /// How much `lab` matches the source colour, 0...1.
        func weight(_ lab: OKLab) -> Float {
            let tolerance = Float(options.tolerance / 100)
            let outer = tolerance
            let inner = tolerance * (1 - Float(options.softness / 100))
            if source.chroma < Recolor.neutralChroma {
                // A grey source: match greys of a similar lightness only.
                let distance = (pow(lab.lightness - source.lightness, 2) + pow(lab.chroma * 4, 2)).squareRoot()
                return 1 - smoothstep(inner * 0.5, outer * 0.5, distance)
            }
            // A colour: match by hue only (chroma doesn't narrow it); greys and near-greys are never matched.
            var difference = abs(lab.hue - source.hue)
            if difference > .pi { difference = 2 * .pi - difference }
            let gate = smoothstep(Recolor.neutralChroma * 0.5, Recolor.neutralChroma * 1.5, lab.chroma)
            return (1 - smoothstep(inner, outer, difference / .pi)) * gate
        }

        /// Moves the pixel from the source colour to the target. Shading: Keep moves its lightness, chroma and hue
        /// relative to the source (so shading survives); Exact colour makes it the target itself. Either way the
        /// result is brought into the sRGB gamut by lowering its chroma.
        private func replaced(_ lab: OKLab) -> OKLab? {
            let amount = weight(lab)
            guard amount > 0 else { return nil }
            let moved: OKLab
            if options.exact {
                moved = target
            } else if source.chroma < Recolor.neutralChroma {
                let lightness = min(max(lab.lightness + target.lightness - source.lightness, 0), 1)
                moved = OKLab(lightness: lightness, greenRed: target.greenRed, blueYellow: target.blueYellow)
            } else {
                let lightness = min(max(lab.lightness + target.lightness - source.lightness, 0), 1)
                let chroma = min(lab.chroma * target.chroma / source.chroma, 0.4)
                moved = OKLab(lightness: lightness, chroma: chroma, hue: target.hue + (lab.hue - source.hue))
            }
            return lab.mixed(with: moved.inSRGBGamut, amount)
        }

        private func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
            guard high > low else { return value < low ? 0 : 1 }
            let fraction = min(max((value - low) / (high - low), 0), 1)
            return fraction * fraction * (3 - 2 * fraction)
        }
    }
}

/// A linear extended-sRGB float copy of an image, changed per pixel and drawn back like the input.
enum LinearBuffer {
    static func map(_ image: CGImage, step: String, _ transform: (OKLab) -> OKLab?) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width >= 1, height >= 1, width <= ImageOps.maxPixels / height,
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                                  bytesPerRow: width * 16, space: linear,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else {
            throw ConversionError.processingFailed(step)
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(image, in: rect)
        let pixels = data.bindMemory(to: Float.self, capacity: width * height * 4)
        let rowFloats = ctx.bytesPerRow / 4
        let bands = min(height, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let first = height * band / bands
            let last = height * (band + 1) / bands
            for row in first..<last {
                let line = pixels + row * rowFloats
                for column in 0..<width {
                    let pixel = line + column * 4
                    let alpha = pixel[3]
                    guard alpha > 0 else { continue }
                    let lab = OKLab(linearRed: pixel[0] / alpha, green: pixel[1] / alpha, blue: pixel[2] / alpha)
                    guard let changed = transform(lab) else { continue }
                    let rgb = changed.linearRGB
                    pixel[0] = rgb.red * alpha
                    pixel[1] = rgb.green * alpha
                    pixel[2] = rgb.blue * alpha
                }
            }
        }
        guard let changed = ctx.makeImage() else { throw ConversionError.processingFailed(step) }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard let out = ImageOps.makeContext(width: width, height: height, like: image, space: space,
                                             alpha: ImageOps.hasAlpha(image), keepFloat: true) else {
            throw ConversionError.processingFailed(step)
        }
        out.draw(changed, in: rect)
        guard let result = out.makeImage() else { throw ConversionError.processingFailed(step) }
        return result
    }
}
