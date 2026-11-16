import Foundation

/// An opaque sRGB colour, saved as `"#RRGGBB"`.
public struct HexColor: Codable, Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `"#RRGGBB"` or `"RRGGBB"` (case-insensitive); nil for anything else.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// From components in 0...1 (clamped; NaN → 0).
    public init(unitRed red: Double, green: Double, blue: Double) {
        func byte(_ value: Double) -> UInt8 { value.isFinite ? UInt8((min(max(value, 0), 1) * 255).rounded()) : 0 }
        self.init(red: byte(red), green: byte(green), blue: byte(blue))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Components in 0...1 (sRGB-encoded).
    public var components: (red: Double, green: Double, blue: Double) { // swiftlint:disable:this large_tuple
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = HexColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not #RRGGBB"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public static let black = HexColor(red: 0, green: 0, blue: 0)
    public static let white = HexColor(red: 255, green: 255, blue: 255)
}

/// How the Color step changes the colours after the profile conversion.
public enum RecolorKind: String, Codable, CaseIterable, Sendable {
    case none, tint, duotone, sepia, replace, hueShift

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .tint: return "Tint"
        case .duotone: return "Duotone"
        case .sepia: return "Sepia"
        case .replace: return "Replace colour"
        case .hueShift: return "Hue shift"
        }
    }
}

/// Every re-color setting; only the ones of `kind` are used, the others are kept so switching back restores them.
public struct RecolorOptions: Codable, Equatable, Sendable {
    public var kind: RecolorKind
    /// Tint: the colour the image is toned in (its midtones).
    public var tint: HexColor
    /// Tint, duotone and sepia: 0...100 % mix with the original.
    public var strength: Double
    /// Duotone: the darkest tones become `shadows`, the lightest `highlights`.
    public var shadows: HexColor
    public var highlights: HexColor
    /// Replace colour: pixels whose hue is near `source`'s become `target` (greys are never matched unless
    /// `source` is grey).
    public var source: HexColor
    public var target: HexColor
    /// Replace colour: false (Shading: Keep) keeps each pixel's lightness, chroma and hue relative to `source`;
    /// true (Exact colour) gives matched pixels exactly `target`, blended by the same tolerance and softness.
    public var exact: Bool
    /// Replace colour: 0...100 % of the hue circle (±180°) that still matches; hue only, chroma doesn't narrow it.
    public var tolerance: Double
    /// Replace color: 0...100 % of the tolerance that fades out instead of a hard edge.
    public var softness: Double
    /// Hue shift: −180...180 degrees.
    public var hueShift: Double

    public init(kind: RecolorKind = .none, tint: HexColor = HexColor(red: 0x3D, green: 0x6E, blue: 0xA8),
                strength: Double = 100, shadows: HexColor = HexColor(red: 0x1F, green: 0x1A, blue: 0x4F),
                highlights: HexColor = HexColor(red: 0xF2, green: 0xC1, blue: 0x6B),
                source: HexColor = HexColor(red: 0x1E, green: 0x5A, blue: 0xC8),
                target: HexColor = HexColor(red: 0xC8, green: 0x1E, blue: 0x2D),
                exact: Bool = false, tolerance: Double = 25, softness: Double = 50, hueShift: Double = 0) {
        self.kind = kind
        self.exact = exact
        self.tint = tint
        self.strength = strength
        self.shadows = shadows
        self.highlights = highlights
        self.source = source
        self.target = target
        self.tolerance = tolerance
        self.softness = softness
        self.hueShift = hueShift
    }

    public static let percentRange: ClosedRange<Double> = 0...100
    public static let hueRange: ClosedRange<Double> = -180...180

    /// The settings with every number in range (NaN → its default).
    public var clamped: RecolorOptions {
        var result = self
        result.strength = Self.clamp(strength, to: Self.percentRange, default: 100)
        result.tolerance = Self.clamp(tolerance, to: Self.percentRange, default: 25)
        result.softness = Self.clamp(softness, to: Self.percentRange, default: 50)
        result.hueShift = Self.clamp(hueShift, to: Self.hueRange, default: 0)
        return result
    }

    /// True when it changes no pixel.
    public var isNeutral: Bool {
        let options = clamped
        switch options.kind {
        case .none: return true
        case .tint, .duotone, .sepia: return options.strength == 0
        case .replace: return options.tolerance == 0 || (!options.exact && options.source == options.target)
        case .hueShift: return options.hueShift == 0
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case kind, tint, strength, shadows, highlights, source, target, exact, tolerance, softness, hueShift
    }

    /// Lenient: missing or unreadable fields take their defaults; numbers are clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = RecolorOptions()
        func color(_ key: CodingKeys, _ fallback: HexColor) -> HexColor {
            ((try? container.decodeIfPresent(HexColor.self, forKey: key)) ?? nil) ?? fallback
        }
        func number(_ key: CodingKeys, _ fallback: Double) -> Double {
            ((try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(kind: ((try? container.decodeIfPresent(RecolorKind.self, forKey: .kind)) ?? nil) ?? .none,
                  tint: color(.tint, base.tint), strength: number(.strength, base.strength),
                  shadows: color(.shadows, base.shadows), highlights: color(.highlights, base.highlights),
                  source: color(.source, base.source), target: color(.target, base.target),
                  exact: ((try? container.decodeIfPresent(Bool.self, forKey: .exact)) ?? nil) ?? false,
                  tolerance: number(.tolerance, base.tolerance), softness: number(.softness, base.softness),
                  hueShift: number(.hueShift, base.hueShift))
        self = clamped
    }
}

/// Reduce colors: at most `count` colours (2...256), optionally Floyd–Steinberg dithered.
public struct ColorReduction: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var count: Int
    public var dither: Bool

    public init(isEnabled: Bool = false, count: Int = 16, dither: Bool = true) {
        self.isEnabled = isEnabled
        self.count = count
        self.dither = dither
    }

    public static let countRange: ClosedRange<Int> = 2...256

    public var clampedCount: Int { min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound) }

    private enum CodingKeys: String, CodingKey { case isEnabled, count, dither }

    /// Lenient: missing fields take their defaults; the count is clamped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = ColorReduction()
        isEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil) ?? base.isEnabled
        count = ((try? container.decodeIfPresent(Int.self, forKey: .count)) ?? nil) ?? base.count
        dither = ((try? container.decodeIfPresent(Bool.self, forKey: .dither)) ?? nil) ?? base.dither
        count = clampedCount
    }
}

/// The Color step: profile conversion first, then re-color, then reduce colors.
///
/// Saved as the plain profile string (`"sRGB"`, the format before re-color existed) while the re-color and
/// reduce settings are all defaults, so older versions still read it; otherwise as an object. Both forms decode.
public struct ColorOptions: Codable, Equatable, Sendable {
    public var profile: ColorProfile
    public var recolor: RecolorOptions
    public var reduce: ColorReduction

    public init(profile: ColorProfile = .sRGB, recolor: RecolorOptions = RecolorOptions(),
                reduce: ColorReduction = ColorReduction()) {
        self.profile = profile
        self.recolor = recolor
        self.reduce = reduce
    }

    /// Profile-only settings, so `.colorProfile(.sRGB)` reads as before.
    public static let keep = ColorOptions(profile: .keep)
    public static let sRGB = ColorOptions(profile: .sRGB)
    public static let displayP3 = ColorOptions(profile: .displayP3)
    public static let gray = ColorOptions(profile: .gray)

    /// True when only the profile changes pixels.
    public var isProfileOnly: Bool { recolor.kind == .none && !reduce.isEnabled }

    /// Saved as the old plain profile string only when nothing else differs from the defaults, so every
    /// setting round-trips exactly.
    var encodesAsProfileString: Bool { recolor == RecolorOptions() && reduce == ColorReduction() }

    private enum CodingKeys: String, CodingKey { case profile, recolor, reduce }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let profile = try? single.decode(ColorProfile.self) {
            self.init(profile: profile)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown profile fails the step, as it always did; the newer parts are lenient.
        let profile = try container.decodeIfPresent(ColorProfile.self, forKey: .profile) ?? .sRGB
        let recolor = ((try? container.decodeIfPresent(RecolorOptions.self, forKey: .recolor)) ?? nil)
            ?? RecolorOptions()
        let reduce = ((try? container.decodeIfPresent(ColorReduction.self, forKey: .reduce)) ?? nil)
            ?? ColorReduction()
        self.init(profile: profile, recolor: recolor, reduce: reduce)
    }

    public func encode(to encoder: Encoder) throws {
        if encodesAsProfileString {
            var single = encoder.singleValueContainer()
            try single.encode(profile)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile, forKey: .profile)
        try container.encode(recolor, forKey: .recolor)
        try container.encode(reduce, forKey: .reduce)
    }
}

extension ColorOptions {
    /// One line for the pipeline list, e.g. "sRGB · tint · 16 colours, dithered".
    public var summary: String {
        var parts = [profile == .keep ? "keep profile" : profile.displayName]
        let options = recolor.clamped
        switch options.kind {
        case .none: break
        case .tint, .duotone, .sepia:
            let name = options.kind.displayName.lowercased()
            parts.append(options.strength == 100 ? name : "\(name) \(Int(options.strength.rounded())) %")
        case .replace: parts.append("replace \(options.source.hex) → \(options.target.hex)")
        case .hueShift:
            let degrees = Int(options.hueShift.rounded())
            parts.append("hue \(degrees > 0 ? "+" : "")\(degrees)°")
        }
        if reduce.isEnabled {
            parts.append("\(reduce.clampedCount) colours" + (reduce.dither ? ", dithered" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

extension ColorOptions {
    /// Input-sized copies held at once (`Pipeline.peakPixels`). The parts run one after another and free their
    /// buffers: re-color holds a 16-byte float copy (4 RGBA copies) and its result; reduce holds its input and one
    /// 8-bit buffer that becomes the result (no further copy), plus a quarter-size gray result or, at encode time,
    /// the palette indices.
    var workingCopies: Int { max(recolor.isNeutral ? 1 : 5, reduce.isEnabled ? 2 : 1) }
}

extension Pipeline {
    /// True when an enabled Color step reduces the colours, so a PNG is written with a palette where possible.
    public var reducesColors: Bool {
        steps.contains { step in
            guard step.isEnabled, case .colorProfile(let options) = step.operation else { return false }
            return options.reduce.isEnabled
        }
    }
}
