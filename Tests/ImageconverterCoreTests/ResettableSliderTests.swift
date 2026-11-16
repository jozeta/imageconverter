import AppKit
import XCTest
@testable import ImageconverterCore

final class ResettableSliderTests: XCTestCase {
    private final class Sink: NSObject {
        var calls = 0
        @objc func fire(_ sender: Any?) { calls += 1 }
    }

    private func click(_ count: Int, on slider: ResettableSlider) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: count, pressure: 1)!
    }

    func testDoubleClickResetsAndNotifies() {
        let sink = Sink()
        let slider = ResettableSlider(value: 40, minValue: -100, maxValue: 100, target: sink, action: #selector(Sink.fire))
        slider.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        slider.mouseDown(with: click(2, on: slider))
        XCTAssertEqual(slider.doubleValue, 0)
        XCTAssertEqual(sink.calls, 1)
    }

    func testResetValueIsUsed() {
        let slider = ResettableSlider(value: 10, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.resetValue = 50
        slider.mouseDown(with: click(2, on: slider))
        XCTAssertEqual(slider.doubleValue, 50)
    }

    func testCentreFillRunsFromTheOriginToTheValue() {
        let bar = CGRect(x: 10, y: 0, width: 200, height: 4)
        // Right of the centre: from the middle to the value.
        XCTAssertEqual(ResettableSlider.fillRect(value: 50, minValue: -100, maxValue: 100, origin: 0, in: bar),
                       CGRect(x: 110, y: 0, width: 50, height: 4))
        // Left of the centre: from the value to the middle.
        XCTAssertEqual(ResettableSlider.fillRect(value: -100, minValue: -100, maxValue: 100, origin: 0, in: bar),
                       CGRect(x: 10, y: 0, width: 100, height: 4))
        // At the origin: nothing.
        XCTAssertEqual(ResettableSlider.fillRect(value: 0, minValue: -100, maxValue: 100, origin: 0, in: bar)?.width ?? 0,
                       0)
        // Out of range values are clamped; an empty range draws nothing.
        XCTAssertEqual(ResettableSlider.fillRect(value: 500, minValue: -100, maxValue: 100, origin: 0, in: bar),
                       CGRect(x: 110, y: 0, width: 100, height: 4))
        XCTAssertNil(ResettableSlider.fillRect(value: 1, minValue: 5, maxValue: 5, origin: 5, in: bar))
    }

    func testCentreFillIsOptIn() {
        let slider = ResettableSlider(value: 10, minValue: -100, maxValue: 100, target: nil, action: nil)
        XCTAssertNil(slider.fillOrigin)
        XCTAssertTrue(slider.cell is ResettableSliderCell)
        slider.fillOrigin = 0
        XCTAssertEqual(slider.fillOrigin, 0)
    }
}
