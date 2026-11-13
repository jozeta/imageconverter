import Foundation

extension ImageOperation {
    /// One-line description of the step for the pipeline list.
    public var summary: String {
        switch self {
        case .resize(let options): return Self.summary(of: options.mode)
        case .crop(let options): return Self.summary(of: options.mode) + " · " + options.anchor.displayName
        case .rotateFlip(let options): return Self.summary(of: options)
        case .canvas(let options): return Self.summary(of: options.mode)
        case .colorProfile(let profile): return profile.displayName
        }
    }

    private static func summary(of mode: ResizeMode) -> String {
        switch mode {
        case .maxWidth(let width): return "max width \(width) px"
        case .maxHeight(let height): return "max height \(height) px"
        case .fitBox(let width, let height): return "fit \(width) × \(height)"
        case .exactWidth(let width): return "width \(width) px"
        case .exactHeight(let height): return "height \(height) px"
        case .exactSize(let width, let height, let fill):
            let fillName: String
            switch fill {
            case .stretch: fillName = "stretch"
            case .fitAndPad: fillName = "pad"
            case .fillAndCrop: fillName = "crop"
            }
            return "\(width) × \(height) · \(fillName)"
        }
    }

    private static func summary(of mode: CropMode) -> String {
        switch mode {
        case .size(let width, let height): return "\(width) × \(height) px"
        case .aspect(let width, let height): return "\(number(width)):\(number(height))"
        }
    }

    private static func summary(of options: RotateFlipOptions) -> String {
        var parts: [String] = []
        if options.rotation != .none { parts.append("\(options.rotation.rawValue)°") }
        switch (options.flipHorizontal, options.flipVertical) {
        case (true, true): parts.append("flip H+V")
        case (true, false): parts.append("flip H")
        case (false, true): parts.append("flip V")
        case (false, false): break
        }
        return parts.isEmpty ? "no change" : parts.joined(separator: " · ")
    }

    private static func summary(of mode: CanvasMode) -> String {
        switch mode {
        case .padding(let pixels): return "+\(pixels) px"
        case .paddingPercent(let percent): return "+\(number(percent)) %"
        case .size(let width, let height): return "\(width) × \(height)"
        }
    }

    /// Whole numbers without decimals, others with the minimal decimals.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
