import CoreGraphics
import CoreImage
import Foundation

/// Tone, colour and detail adjustments. Every field is 0 when neutral.
public struct AdjustOptions: Codable, Equatable, Sendable {
    public var exposure: Double
    public var brilliance: Double
    public var highlights: Double
    public var shadows: Double
    public var contrast: Double
    public var brightness: Double
    public var blackPoint: Double
    public var saturation: Double
    public var vibrance: Double
    public var warmth: Double
    public var tint: Double
    /// Degrees.
    public var hue: Double
    public var sharpness: Double
    public var definition: Double
    public var noiseReduction: Double

    public init(exposure: Double = 0, brilliance: Double = 0, highlights: Double = 0, shadows: Double = 0,
                contrast: Double = 0, brightness: Double = 0, blackPoint: Double = 0, saturation: Double = 0,
                vibrance: Double = 0, warmth: Double = 0, tint: Double = 0, hue: Double = 0,
                sharpness: Double = 0, definition: Double = 0, noiseReduction: Double = 0) {
        self.exposure = exposure
        self.brilliance = brilliance
        self.highlights = highlights
        self.shadows = shadows
        self.contrast = contrast
        self.brightness = brightness
        self.blackPoint = blackPoint
        self.saturation = saturation
        self.vibrance = vibrance
        self.warmth = warmth
        self.tint = tint
        self.hue = hue
        self.sharpness = sharpness
        self.definition = definition
        self.noiseReduction = noiseReduction
    }

    /// The adjustable fields in editor order; the raw value is the JSON key.
    public enum Field: String, CaseIterable, Sendable, CodingKey {
        case exposure, brilliance, highlights, shadows, contrast, brightness, blackPoint
        case saturation, vibrance, warmth, tint, hue
        case sharpness, definition, noiseReduction

        public var range: ClosedRange<Double> {
            switch self {
            case .hue: return -180...180
            case .sharpness, .definition, .noiseReduction: return 0...100
            default: return -100...100
            }
        }

        public var displayName: String {
            switch self {
            case .blackPoint: return "Black point"
            case .noiseReduction: return "Noise reduction"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }

        var keyPath: WritableKeyPath<AdjustOptions, Double> {
            switch self {
            case .exposure: return \.exposure
            case .brilliance: return \.brilliance
            case .highlights: return \.highlights
            case .shadows: return \.shadows
            case .contrast: return \.contrast
            case .brightness: return \.brightness
            case .blackPoint: return \.blackPoint
            case .saturation: return \.saturation
            case .vibrance: return \.vibrance
            case .warmth: return \.warmth
            case .tint: return \.tint
            case .hue: return \.hue
            case .sharpness: return \.sharpness
            case .definition: return \.definition
            case .noiseReduction: return \.noiseReduction
            }
        }
    }

    public static let ranges: [Field: ClosedRange<Double>] =
        Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0, $0.range) })

    public subscript(field: Field) -> Double {
        get { self[keyPath: field.keyPath] }
        set { self[keyPath: field.keyPath] = newValue }
    }

    /// The value limited to the field's range; non-finite values become 0.
    public static func clamped(_ value: Double, to field: Field) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, field.range.lowerBound), field.range.upperBound)
    }

    public var isNeutral: Bool { Field.allCases.allSatisfy { self[$0] == 0 } }

    /// Lenient: missing keys are 0, out-of-range values are clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Field.self)
        self.init()
        for field in Field.allCases {
            let raw = try container.decodeIfPresent(Double.self, forKey: field) ?? 0
            self[field] = Self.clamped(raw, to: field)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Field.self)
        for field in Field.allCases { try container.encode(self[field], forKey: field) }
    }
}

/// Renders `AdjustOptions` with Core Image.
public enum Adjustments {
    public static func apply(_ raw: AdjustOptions, to image: CGImage) throws -> CGImage {
        // Callers may build options directly: clamp (NaN → 0) before anything reaches Core Image.
        var options = raw
        for field in AdjustOptions.Field.allCases { options[field] = AdjustOptions.clamped(raw[field], to: field) }
        if options.isNeutral { return image }
        let step = StepKind.adjust.displayName
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Clamped so blur-based filters see edge pixels instead of transparent black outside the image.
        let source = CIImage(cgImage: image).clampedToExtent()
        let output = filtered(source, options, shortSide: Double(min(image.width, image.height))).cropped(to: extent)
        return try render(output, from: extent, like: image, step: step)
    }

    /// Renders the `rect` part of `output` into a bitmap like `image`'s, so the bit depth, colour space and
    /// alpha match it. Shared by every Core Image step.
    static func render(_ output: CIImage, from rect: CGRect, like image: CGImage, step: String) throws -> CGImage {
        let alpha = ImageOps.hasAlpha(image)
        // Core Image renders RGBA only: non-RGB sources (gray, CMYK, indexed) come out in sRGB.
        let space = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        let width = Int(rect.width)
        let height = Int(rect.height)
        guard let ctx = ImageOps.makeContext(width: width, height: height, like: image, space: space, alpha: alpha),
              let target = ctx.colorSpace,
              let rendered = SharedCIContext.context.createCGImage(
                output, from: rect, format: ctx.bitsPerComponent > 8 ? .RGBA16 : .RGBA8, colorSpace: target) else {
            throw ConversionError.processingFailed(step)
        }
        ctx.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw ConversionError.processingFailed(step) }
        return result
    }

    // MARK: Filter chain (fixed order)

    private static func filtered(_ input: CIImage, _ opts: AdjustOptions, shortSide: Double) -> CIImage {
        detail(colour(tone(input, opts), opts), opts, shortSide: shortSide)
    }

    /// Steps 1-5. Exposure works on linear light. Highlights/shadows and contrast/brightness/saturation run on
    /// gamma-encoded sRGB, so amounts, the contrast pivot (mid-gray) and the brightness offset are perceptual.
    /// `CIToneCurve` converts linear to sRGB itself (measured), so the curves run on the linear image.
    private static func tone(_ input: CIImage, _ opts: AdjustOptions) -> CIImage {
        var image = input
        if opts.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: opts.exposure / 50])
        }
        if opts.highlights < 0 || opts.shadows != 0 {
            image = inGamma(image) {
                $0.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 1 + min(0, opts.highlights) / 100,
                    "inputShadowAmount": opts.shadows / 100
                ])
            }
        }
        if opts.highlights > 0 {
            let lift = opts.highlights / 100 * 0.1
            image = toneCurve(image, [(0, 0), (0.25, 0.25), (0.5, 0.5), (0.75, 0.75 + lift), (1, 1)])
        }
        if opts.brilliance != 0 {
            // Positive: shadows up, highlights down (a flatter, brighter-looking midtone).
            let shift = opts.brilliance / 200 * 0.25
            image = toneCurve(image, [(0, 0), (0.25, 0.25 + shift), (0.5, 0.5), (0.75, 0.75 - shift), (1, 1)])
        }
        if opts.blackPoint != 0 { image = toneCurve(image, blackPointCurve(opts.blackPoint)) }
        if opts.contrast != 0 || opts.brightness != 0 || opts.saturation != 0 {
            image = inGamma(image) {
                $0.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1 + opts.contrast / 100 * 0.5,
                    kCIInputBrightnessKey: opts.brightness / 100 * 0.25,
                    kCIInputSaturationKey: 1 + opts.saturation / 100
                ])
            }
        }
        return image
    }

    /// Runs `filter` on the gamma-encoded (sRGB curve) version of the linear `image` and decodes the result.
    private static func inGamma(_ image: CIImage, _ filter: (CIImage) -> CIImage) -> CIImage {
        filter(image.applyingFilter("CILinearToSRGBToneCurve")).applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Steps 6-8: vibrance, warmth/tint, hue.
    private static func colour(_ input: CIImage, _ opts: AdjustOptions) -> CIImage {
        var image = input
        if opts.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": opts.vibrance / 100])
        }
        if opts.warmth != 0 || opts.tint != 0 {
            // CI conventions (verified by tests): a target neutral below the source's warms the image, and a
            // positive target tint turns it green, so tint is negated to make + magenta as in Photos/Lightroom.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - opts.warmth * 20, y: -opts.tint)
            ])
        }
        if opts.hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: opts.hue * .pi / 180])
        }
        return image
    }

    /// Steps 9-11: noise reduction, definition, sharpness.
    private static func detail(_ input: CIImage, _ opts: AdjustOptions, shortSide: Double) -> CIImage {
        var image = input
        if opts.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": opts.noiseReduction / 100 * 0.04, kCIInputSharpnessKey: 0.4
            ])
        }
        if opts.definition > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(1, 0.02 * shortSide), kCIInputIntensityKey: opts.definition / 100 * 0.6
            ])
        }
        if opts.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: opts.sharpness / 100 * 1.5, kCIInputRadiusKey: 1.5
            ])
        }
        return image
    }

    /// v > 0 crushes the darkest tones to black, v < 0 lifts black to grey.
    private static func blackPointCurve(_ value: Double) -> [(Double, Double)] {
        let start = value > 0 ? (value / 100 * 0.15, 0.0) : (0.0, -value / 100 * 0.15)
        return (0...4).map { index in
            let fraction = Double(index) / 4
            return (start.0 + (1 - start.0) * fraction, start.1 + (1 - start.1) * fraction)
        }
    }

    /// A five-point curve. Points are sRGB-encoded tones: the filter encodes the linear input itself.
    private static func toneCurve(_ image: CIImage, _ points: [(Double, Double)]) -> CIImage {
        var parameters: [String: Any] = [:]
        for (index, point) in points.prefix(5).enumerated() {
            parameters["inputPoint\(index)"] = CIVector(x: point.0, y: point.1)
        }
        return image.applyingFilter("CIToneCurve", parameters: parameters)
    }
}
