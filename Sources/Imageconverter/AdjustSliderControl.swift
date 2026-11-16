import SwiftUI
import AppKit
import ImageconverterCore

/// A continuous slider (AppKit `NSSlider`) that resets to `resetValue` on double-click, rounds to whole numbers,
/// and fills its track with the accent colour only while the value is not neutral.
struct AdjustSliderControl: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double = 0
    /// Fill the track from this value to the knob (a centred, bipolar slider); `nil` fills from the left.
    var fillOrigin: Double?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ResettableSlider {
        let slider = ResettableSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                                      target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.resetValue = resetValue
        slider.fillOrigin = fillOrigin
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: ResettableSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.resetValue = resetValue
        slider.fillOrigin = fillOrigin
        if slider.doubleValue != value { slider.doubleValue = value }
        let neutral = abs(value - resetValue) < 0.5
        slider.trackFillColor = NSColor(neutral ? LadaGlass.Colors.muted : LadaGlass.accent.color)
        // The custom bar is drawn by the cell, so a colour change alone needs a redraw.
        if fillOrigin != nil { slider.needsDisplay = true }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResettableSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: AdjustSliderControl
        init(_ parent: AdjustSliderControl) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            parent.value = sender.doubleValue.rounded()
        }
    }
}
