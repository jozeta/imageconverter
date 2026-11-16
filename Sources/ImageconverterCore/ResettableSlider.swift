import AppKit

/// An `NSSlider` whose double-click resets it to `resetValue` (the knob does not move on that click).
/// A single click or drag behaves as usual. Lives in Core so tests can drive it with synthetic events.
public final class ResettableSlider: NSSlider {
    public var resetValue: Double = 0

    /// When set, the track fill runs from this value to the knob instead of from the left end, for sliders
    /// whose neutral value is in the middle (every −100…100 Adjust slider). `nil` keeps the standard look.
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
        // Delivered straight to the target when there is one: `sendAction` goes through `NSApp`, which a slider
        // outside a running app (tests, macOS 15) doesn't reach.
        if let action, let target = target as AnyObject? {
            _ = target.perform(action, with: self)
        } else {
            sendAction(action, to: target)
        }
    }

    /// The part of `bar` between `origin` and `value` (both clamped to the range), or `nil` for an empty range.
    /// `inset`: the knob's centre travels from `bar.minX + inset` to `bar.maxX - inset` (half the knob's width).
    public static func fillRect(value: Double, minValue: Double, maxValue: Double, origin: Double,
                                in bar: CGRect, inset: CGFloat = 0) -> CGRect? {
        let span = maxValue - minValue
        guard span > 0, span.isFinite else { return nil }
        let inset = min(max(0, inset), bar.width / 2)
        func xPosition(_ number: Double) -> CGFloat {
            let fraction = (min(max(number.isFinite ? number : origin, minValue), maxValue) - minValue) / span
            return bar.minX + inset + (bar.width - 2 * inset) * CGFloat(fraction)
        }
        let start = xPosition(origin)
        let end = xPosition(value)
        return CGRect(x: min(start, end), y: bar.minY, width: abs(end - start), height: bar.height)
    }
}

/// Draws the standard bar, or, with a `fillOrigin`, a plain track filled from the origin to the knob's centre, with a
/// tick at the origin drawn over the fill.
public final class ResettableSliderCell: NSSliderCell {
    /// The knob's centre for `value`, as AppKit lays it out (its inset travel differs between macOS versions), found
    /// with a copy of this cell so the real knob doesn't move.
    func knobCentre(for value: Double, flipped: Bool) -> CGFloat {
        guard let probe = copy() as? NSSliderCell else { return knobRect(flipped: flipped).midX }
        probe.controlView = controlView
        probe.doubleValue = value
        let centre = probe.knobRect(flipped: flipped).midX
        probe.controlView = nil
        return centre
    }

    /// The filled part of `bar` for the current value — from the knob's centre at the origin to its centre now —
    /// or `nil` without a `fillOrigin`.
    func fillRect(in bar: CGRect, flipped: Bool) -> CGRect? {
        guard let origin = (controlView as? ResettableSlider)?.fillOrigin, maxValue > minValue else { return nil }
        let start = knobCentre(for: min(max(origin, minValue), maxValue), flipped: flipped)
        let end = knobRect(flipped: flipped).midX
        return CGRect(x: min(start, end), y: bar.minY, width: abs(end - start), height: bar.height)
    }

    /// Where the knob's centre is at the `fillOrigin` (the neutral tick).
    func neutralX(in bar: CGRect, flipped: Bool) -> CGFloat? {
        guard let origin = (controlView as? ResettableSlider)?.fillOrigin, maxValue > minValue else { return nil }
        return knobCentre(for: min(max(origin, minValue), maxValue), flipped: flipped)
    }

    public override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let slider = controlView as? ResettableSlider, slider.fillOrigin != nil, !isVertical else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let radius = rect.height / 2
        // Tertiary rather than quaternary: the track stays visible on the glass background.
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let fill = fillRect(in: rect, flipped: flipped), fill.width >= 0.5 {
            (slider.trackFillColor ?? .controlAccentColor).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
        // A short tick marks the neutral middle, on top of the fill so it stays visible.
        if let middle = neutralX(in: rect, flipped: flipped) {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(rect: CGRect(x: middle - 0.5, y: rect.minY - 2, width: 1, height: rect.height + 4)).fill()
        }
    }
}
