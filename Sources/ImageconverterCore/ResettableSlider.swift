import AppKit

/// An `NSSlider` whose double-click resets it to `resetValue` (the knob does not move on that click).
/// A single click or drag behaves as usual. Lives in Core so tests can drive it with synthetic events.
public final class ResettableSlider: NSSlider {
    public var resetValue: Double = 0

    /// When set, the track fill runs from this value to the knob instead of from the left end, for sliders
    /// whose neutral value is in the middle (Soften ↔ Sharpen). `nil` keeps the standard look.
    public var fillOrigin: Double? {
        didSet { if fillOrigin != oldValue { needsDisplay = true } }
    }

    public override static var cellClass: AnyClass? {
        get { ResettableSliderCell.self }
        set { _ = newValue }
    }

    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        doubleValue = resetValue
        sendAction(action, to: target)
    }

    /// The part of `bar` between `origin` and `value` (both clamped to the range), or `nil` for an empty range.
    public static func fillRect(value: Double, minValue: Double, maxValue: Double, origin: Double,
                                in bar: CGRect) -> CGRect? {
        let span = maxValue - minValue
        guard span > 0, span.isFinite else { return nil }
        func xPosition(_ number: Double) -> CGFloat {
            let fraction = (min(max(number.isFinite ? number : origin, minValue), maxValue) - minValue) / span
            return bar.minX + bar.width * CGFloat(fraction)
        }
        let start = xPosition(origin)
        let end = xPosition(value)
        return CGRect(x: min(start, end), y: bar.minY, width: abs(end - start), height: bar.height)
    }
}

/// Draws the standard bar, or, with a `fillOrigin`, a plain track filled from the origin to the knob.
public final class ResettableSliderCell: NSSliderCell {
    public override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let slider = controlView as? ResettableSlider, let origin = slider.fillOrigin,
              !isVertical else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let radius = rect.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        // A short tick marks the neutral middle.
        if let mark = ResettableSlider.fillRect(value: origin, minValue: minValue, maxValue: maxValue,
                                                origin: minValue, in: rect) {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(rect: CGRect(x: mark.maxX - 0.5, y: rect.minY - 2, width: 1, height: rect.height + 4)).fill()
        }
        guard let fill = ResettableSlider.fillRect(value: doubleValue, minValue: minValue, maxValue: maxValue,
                                                   origin: origin, in: rect), fill.width >= 0.5 else { return }
        (slider.trackFillColor ?? .controlAccentColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
