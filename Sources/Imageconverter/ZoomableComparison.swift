import AppKit
import SwiftUI
import ImageconverterCore

/// One side's zoom geometry: the image's full pixel size, the side's view size and the display's pixels per point.
struct ZoomGeometry: Equatable {
    var imagePixels: CGSize
    var view: CGSize
    var pixelsPerPoint: CGFloat

    var maxScale: CGFloat { ZoomMath.maxScale(imagePixels: imagePixels, view: view, pixelsPerPoint: pixelsPerPoint) }
    var actualScale: CGFloat {
        ZoomMath.actualPixelsScale(imagePixels: imagePixels, view: view, pixelsPerPoint: pixelsPerPoint)
    }
    /// The zoom level as a percentage of actual pixels (100 % = one image pixel per screen pixel).
    func percent(at scale: CGFloat) -> CGFloat { scale / actualScale * 100 }
}

/// The before/after zoom, shared by both sides so they always show the same region. Kept on the model
/// (not in the pane) so the View menu can reach it.
@MainActor @Observable
final class ZoomController {
    private(set) var state = ZoomState.fit
    /// The After side's geometry (the Before side's when there is no After image); the menu, the chip and
    /// the scale range use it. Nil while no preview image is on screen.
    private(set) var reference: ZoomGeometry?
    @ObservationIgnored private var item: URL?
    @ObservationIgnored private var keyMonitor: Any?
    /// DEBUG launch option `-debugZoom <scale>`: applied once the first preview is on screen.
    @ObservationIgnored var pendingScale: CGFloat?

    static let step: CGFloat = 1.5

    var canZoom: Bool { reference != nil }
    var percent: Int? {
        guard let reference, state.isZoomed else { return nil }
        return Int(reference.percent(at: state.scale).rounded())
    }

    /// A new selected image starts at fit; a new render of the same image keeps the zoom.
    func track(item new: URL?) {
        guard new != item else { return }
        item = new
        state = .fit
    }

    func setReference(_ geometry: ZoomGeometry?) {
        reference = geometry
        guard let geometry else { return }
        if let pending = pendingScale {
            pendingScale = nil
            zoom(to: pending, anchor: .zero, in: geometry)
        } else {
            // A resized pane or a changed output size can narrow the range; keep the state inside it.
            zoom(to: state.scale, anchor: .zero, in: geometry)
        }
    }

    func zoom(to scale: CGFloat, anchor: CGPoint, in geometry: ZoomGeometry? = nil) {
        guard let geometry = geometry ?? reference else { return }
        let next = ZoomMath.zoom(state, to: ZoomMath.clampScale(scale, max: geometry.maxScale), anchor: anchor,
                                 imagePixels: geometry.imagePixels, view: geometry.view)
        if next != state { state = next }
    }

    func pan(by delta: CGSize, in geometry: ZoomGeometry) {
        guard state.isZoomed else { return }
        let next = ZoomMath.pan(state, by: delta, imagePixels: geometry.imagePixels, view: geometry.view)
        if next != state { state = next }
    }

    func zoomIn() { zoom(to: state.scale * Self.step, anchor: .zero) }
    func zoomOut() { zoom(to: state.scale / Self.step, anchor: .zero) }
    func zoomToFit() { state = .fit }
    func actualSize() {
        guard let reference else { return }
        zoom(to: reference.actualScale, anchor: .zero)
    }

    /// Double-click: fit when zoomed, otherwise 100 % actual pixels at the click point (or the maximum
    /// for a tiny image that already shows larger than actual pixels at fit).
    func toggleActual(at anchor: CGPoint, in geometry: ZoomGeometry) {
        if state.isZoomed {
            state = .fit
        } else {
            let target = geometry.actualScale > 1.01 ? geometry.actualScale : geometry.maxScale
            zoom(to: target, anchor: anchor, in: geometry)
        }
    }

    /// ⌘+ is the menu shortcut; on most layouts that needs Shift, so plain ⌘= zooms in as well.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
            guard flags == .command, event.charactersIgnoringModifiers == "=",
                  let self, MainActor.assumeIsolated({ self.canZoom }) else { return event }
            MainActor.assumeIsolated { self.zoomIn() }
            return nil
        }
    }
}

/// One side of the comparison: the image at the shared zoom, clipped to its box, with the trackpad and
/// mouse handling on top. `pixelSize` is the image's full size; `image` may be a smaller copy.
struct ZoomableImage: View {
    let image: CGImage
    /// The full-size bitmap, drawn instead of `image` while zoomed once it is available.
    let fullImage: CGImage?
    let pixelSize: CGSize
    let label: String
    let isReference: Bool
    let zoom: ZoomController
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let geometry = ZoomGeometry(imagePixels: pixelSize, view: proxy.size, pixelsPerPoint: displayScale)
            let state = zoom.state
            let shown = ZoomMath.displayedSize(imagePixels: pixelSize, view: proxy.size, scale: state.scale)
            let center = ZoomMath.clampCenter(state.center, displayed: shown, view: proxy.size)
            let drawn = state.isZoomed ? (fullImage ?? image) : image
            ZStack {
                Image(drawn, scale: 1, label: Text(label))
                    .resizable()
                    // Past actual pixels every image pixel is a crisp square, so artifacts are easy to see.
                    .interpolation(geometry.percent(at: state.scale) > 100.5 ? .none : .high)
                    .frame(width: shown.width, height: shown.height)
                    .position(x: proxy.size.width / 2 + (0.5 - center.x) * shown.width,
                              y: proxy.size.height / 2 + (0.5 - center.y) * shown.height)
                ZoomEventView(
                    isZoomed: state.isZoomed,
                    onMagnify: { factor, anchor in zoom.zoom(to: zoom.state.scale * factor, anchor: anchor, in: geometry) },
                    onPan: { zoom.pan(by: $0, in: geometry) },
                    onToggle: { zoom.toggleActual(at: $0, in: geometry) })
            }
            .onChange(of: geometry, initial: true) { _, new in
                if isReference { zoom.setReference(new) }
            }
            .onDisappear { if isReference { zoom.setReference(nil) } }
        }
        .clipped()
    }
}

/// Catches pinch, two-finger scroll, drag and double-click for one side. At fit, scroll events go on to
/// the next responder so the window behaves as if this view were not there.
private struct ZoomEventView: NSViewRepresentable {
    let isZoomed: Bool
    let onMagnify: (CGFloat, CGPoint) -> Void
    let onPan: (CGSize) -> Void
    let onToggle: (CGPoint) -> Void

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) {
        view.onMagnify = onMagnify
        view.onPan = onPan
        view.onToggle = onToggle
        view.isZoomed = isZoomed
    }

    final class EventView: NSView {
        var onMagnify: (CGFloat, CGPoint) -> Void = { _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        var onToggle: (CGPoint) -> Void = { _ in }
        var isZoomed = false {
            didSet { if isZoomed != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        /// True between mouse down and up of a drag that pushed the closed hand.
        private var dragging = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// The event's position relative to the view's centre, y down.
        private func anchor(_ event: NSEvent) -> CGPoint {
            let point = convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        }

        override func magnify(with event: NSEvent) {
            onMagnify(1 + event.magnification, anchor(event))
        }

        override func smartMagnify(with event: NSEvent) {
            onToggle(anchor(event))
        }

        override func scrollWheel(with event: NSEvent) {
            guard isZoomed else { return super.scrollWheel(with: event) }
            // Line-based mouse wheels report small deltas; scale them to roughly a line of text.
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            onPan(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onToggle(anchor(event))
            } else if isZoomed, !dragging {
                dragging = true
                NSCursor.closedHand.push()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            onPan(CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func mouseUp(with event: NSEvent) { endDrag() }

        private func endDrag() {
            guard dragging else { return }
            dragging = false
            NSCursor.pop()
        }

        override func resetCursorRects() {
            if isZoomed { addCursorRect(bounds, cursor: .openHand) }
        }

        // A view removed mid-drag must not leave the closed hand on the cursor stack.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endDrag() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
