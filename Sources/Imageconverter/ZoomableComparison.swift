import AppKit
import SwiftUI
import ImageconverterCore

/// Which preview side an input or a geometry comes from.
enum ZoomSide { case before, after }

/// The before/after zoom, shared by both sides so they always show the same region. Kept on the model
/// (not in the pane) so the View menu can reach it.
@MainActor @Observable
final class ZoomController {
    private(set) var state = ZoomState.fit
    /// The After side's geometry (the Before side's when there is no After image); the menu, the chip and
    /// the scale range use it. Nil while no preview image is on screen.
    private(set) var reference: ZoomGeometry?
    @ObservationIgnored private var referenceSide: ZoomSide?
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

    /// Called by the side that is the reference (After, or Before when there is no After image).
    func setReference(_ geometry: ZoomGeometry, from side: ZoomSide) {
        reference = geometry
        referenceSide = side
        if let pending = pendingScale {
            pendingScale = nil
            zoom(to: pending, anchor: .zero, in: geometry)
        } else {
            // A resized pane or a changed output size can narrow the range; keep the state inside it.
            zoom(to: state.scale, anchor: .zero, in: geometry)
        }
    }

    /// Only the side that set the reference clears it, so a disappearing After cannot wipe the reference
    /// Before has just taken over.
    func clearReference(from side: ZoomSide) {
        guard referenceSide == side else { return }
        reference = nil
        referenceSide = nil
    }

    /// `geometry` is the side the input came from; the range and 100 % always come from the reference.
    func zoom(to scale: CGFloat, anchor: CGPoint, in geometry: ZoomGeometry? = nil) {
        guard let side = geometry ?? reference else { return }
        update(state.zoomed(to: scale, anchor: anchor, side: side, reference: reference))
    }

    func pan(by delta: CGSize, in geometry: ZoomGeometry) {
        update(state.panned(by: delta, side: geometry))
    }

    func zoomIn() { zoom(to: state.scale * Self.step, anchor: .zero) }
    func zoomOut() { zoom(to: state.scale / Self.step, anchor: .zero) }
    func zoomToFit() { update(.fit) }
    func actualSize() {
        guard let reference else { return }
        zoom(to: reference.actualScale, anchor: .zero)
    }

    /// Double-click: fit when zoomed, otherwise 100 % actual pixels at the click point.
    func toggleActual(at anchor: CGPoint, in geometry: ZoomGeometry) {
        update(state.toggled(at: anchor, side: geometry, reference: reference))
    }

    private func update(_ next: ZoomState) {
        if next != state { state = next }
    }

    /// ⌘+ is the menu shortcut; on most layouts that needs Shift, so plain ⌘= zooms in as well.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
            guard flags == .command, event.charactersIgnoringModifiers == "=",
                  let self, MainActor.assumeIsolated({ self.canZoom }),
                  // Only in the main window (not a sheet) and not while a text field is being edited.
                  let window = event.window, window === NSApp.mainWindow, window.isKeyWindow,
                  !(window.firstResponder is NSText) else { return event }
            MainActor.assumeIsolated { self.zoomIn() }
            return nil
        }
    }
}

/// One side of the comparison: the image at the shared zoom, clipped to its box, on a checkerboard, with the
/// trackpad and mouse handling on top. `pixelSize` is the image's full size; `image` may be a smaller copy.
/// `visible` is the horizontal part of the box (fractions of its width) that is drawn: the split view shows
/// Before left of the divider and After right of it, and Single mode hides one side while it keeps its geometry.
struct ZoomableImage: View {
    let image: CGImage
    /// The full-size bitmap, drawn instead of `image` while zoomed once it is available.
    let fullImage: CGImage?
    let pixelSize: CGSize
    let label: String
    let side: ZoomSide
    let isReference: Bool
    let zoom: ZoomController
    var interactive = true
    var visible: ClosedRange<CGFloat> = 0...1
    /// The split divider (fraction of the width) and what dragging it does; nil outside the split view.
    var divider: CGFloat?
    var onDivider: ((CGFloat) -> Void)?
    var onDividerEnd: (() -> Void)?
    /// The unit region of the full image that `image` covers (a crop); the whole image when nil.
    var region: CGRect?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let geometry = ZoomGeometry(imagePixels: pixelSize, view: proxy.size, pixelsPerPoint: displayScale)
            let state = zoom.state
            let shown = ZoomMath.displayedSize(imagePixels: pixelSize, view: proxy.size, scale: state.scale)
            let center = ZoomMath.clampCenter(state.center, displayed: shown, view: proxy.size)
            let drawn = state.isZoomed ? (fullImage ?? image) : image
            let cover = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let frame = CGRect(x: proxy.size.width / 2 + (0.5 - center.x) * shown.width - shown.width / 2,
                               y: proxy.size.height / 2 + (0.5 - center.y) * shown.height - shown.height / 2,
                               width: shown.width, height: shown.height)
            ZStack {
                ZStack {
                    checkerboard(behind: frame, in: proxy.size)
                    Image(drawn, scale: 1, label: Text(label))
                        .resizable()
                        // Past actual pixels every image pixel is a crisp square, so artifacts are easy to see.
                        .interpolation(geometry.percent(at: state.scale) > 100.5 ? .none : .high)
                        .frame(width: shown.width * cover.width, height: shown.height * cover.height)
                        .position(x: frame.minX + shown.width * cover.midX, y: frame.minY + shown.height * cover.midY)
                }
                // The enlarged image reaches far outside the clipped box; only the event view takes input.
                .allowsHitTesting(false)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: proxy.size.width * (visible.upperBound - visible.lowerBound))
                        .offset(x: proxy.size.width * visible.lowerBound)
                }
                .accessibilityHidden(visible.upperBound <= visible.lowerBound)
                if interactive {
                    ZoomEventView(
                        isZoomed: state.isZoomed,
                        divider: divider,
                        onDivider: onDivider ?? { _ in },
                        onDividerEnd: onDividerEnd ?? {},
                        onMagnify: { factor, anchor in zoom.zoom(to: zoom.state.scale * factor, anchor: anchor, in: geometry) },
                        onPan: { zoom.pan(by: $0, in: geometry) },
                        onToggle: { zoom.toggleActual(at: $0, in: geometry) })
                }
            }
            .onChange(of: ReferenceKey(geometry: geometry, isReference: isReference), initial: true) { _, key in
                if key.isReference { zoom.setReference(key.geometry, from: side) } else { zoom.clearReference(from: side) }
            }
            .onDisappear { zoom.clearReference(from: side) }
        }
        .clipped()
        .contentShape(Rectangle())
    }

    /// Only the on-screen part of the image gets squares (a zoomed image can be many times the box), shifted
    /// so the pattern stays fixed to the image while it pans.
    private func checkerboard(behind frame: CGRect, in size: CGSize) -> some View {
        let box = CGRect(origin: .zero, size: size).intersection(frame)
        return Group {
            if !box.isNull, box.width > 0, box.height > 0 {
                Checkerboard(phase: CGPoint(x: frame.minX - box.minX, y: frame.minY - box.minY))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
            }
        }
    }
}

/// Changes when the side's size changes or it becomes (or stops being) the reference.
private struct ReferenceKey: Equatable {
    let geometry: ZoomGeometry
    let isReference: Bool
}

/// Catches pinch, two-finger scroll, drag and double-click for one side. At fit, scroll events go on to
/// the next responder so the window behaves as if this view were not there.
private struct ZoomEventView: NSViewRepresentable {
    let isZoomed: Bool
    let divider: CGFloat?
    let onDivider: (CGFloat) -> Void
    let onDividerEnd: () -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void
    let onPan: (CGSize) -> Void
    let onToggle: (CGPoint) -> Void

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) {
        view.onMagnify = onMagnify
        view.onPan = onPan
        view.onToggle = onToggle
        view.onDivider = onDivider
        view.onDividerEnd = onDividerEnd
        view.isZoomed = isZoomed
        view.divider = divider
    }

    final class EventView: NSView {
        var onMagnify: (CGFloat, CGPoint) -> Void = { _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        var onToggle: (CGPoint) -> Void = { _ in }
        var onDivider: (CGFloat) -> Void = { _ in }
        var onDividerEnd: () -> Void = {}
        var isZoomed = false {
            didSet { if isZoomed != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        var divider: CGFloat? {
            didSet { if divider != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        /// True between mouse down and up of a drag that pushed the closed hand.
        private var dragging = false
        /// True while the split divider is being dragged (the drag moves it instead of panning).
        private var draggingDivider = false
        /// How far from the divider line a click still grabs it.
        private static let dividerGrab: CGFloat = 8

        /// The divider's hit area, when there is one.
        private var dividerRect: CGRect? {
            guard let divider else { return nil }
            let line = bounds.width * divider
            return CGRect(x: line - Self.dividerGrab, y: 0, width: 2 * Self.dividerGrab, height: bounds.height)
        }

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
            if let rect = dividerRect, rect.contains(convert(event.locationInWindow, from: nil)) {
                draggingDivider = true
                return
            }
            if event.clickCount == 2 {
                onToggle(anchor(event))
            } else if isZoomed, !dragging {
                dragging = true
                NSCursor.closedHand.push()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if draggingDivider, bounds.width > 0 {
                onDivider(convert(event.locationInWindow, from: nil).x / bounds.width)
                return
            }
            guard dragging else { return }
            onPan(CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func mouseUp(with event: NSEvent) {
            if draggingDivider { onDividerEnd() }
            draggingDivider = false
            endDrag()
        }

        private func endDrag() {
            guard dragging else { return }
            dragging = false
            NSCursor.pop()
        }

        override func resetCursorRects() {
            if isZoomed { addCursorRect(bounds, cursor: .openHand) }
            if let rect = dividerRect { addCursorRect(rect, cursor: .resizeLeftRight) }
        }

        // A view removed mid-drag must not leave the closed hand on the cursor stack.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endDrag() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
