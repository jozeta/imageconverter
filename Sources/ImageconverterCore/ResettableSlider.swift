import AppKit

/// An `NSSlider` whose double-click resets it to `resetValue` (the knob does not move on that click).
/// A single click or drag behaves as usual. Lives in Core so tests can drive it with synthetic events.
public final class ResettableSlider: NSSlider {
    public var resetValue: Double = 0

    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        doubleValue = resetValue
        sendAction(action, to: target)
    }
}
