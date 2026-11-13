import AppKit
import Observation

/// Drives the main window's size so it always fits its panels: the sidebar has a fixed width, the
/// window is exactly as tall as the sidebar's content (up to the screen), and only the preview's
/// width is user-resizable.
///
/// SwiftUI applies `widthRange`/`heightRange` as the root view's min/max size, which
/// `.windowResizability(.contentSize)` turns into the window's content min/max size. A change is
/// animated by first widening the ranges to cover both the current and the new size, then animating
/// the frame with AppKit, and only tightening the ranges (and unmounting a hidden preview) once the
/// animation has finished. SwiftUI therefore never resizes the window on its own mid-animation,
/// which is what made the old toggle jump and flicker.
@MainActor @Observable
final class WindowSizer {
    static let sidebarWidth: CGFloat = 360
    static let previewMinWidth: CGFloat = 420
    static let defaultPreviewWidth: CGFloat = 640
    static let animationDuration: TimeInterval = 0.2
    /// Wait after the last content height change before following it, so typing and quick
    /// expand/collapse sequences give one animation instead of a storm.
    static let heightDebounce = Duration.milliseconds(60)

    /// Allowed window content width and height, applied by the root view.
    private(set) var widthRange: ClosedRange<CGFloat>
    private(set) var heightRange: ClosedRange<CGFloat> = 200...CGFloat.infinity
    /// Whether the preview pane is in the view hierarchy; it stays while the hide animation runs.
    private(set) var previewMounted: Bool
    /// The preview's fixed width while an animation reveals or hides it (the window edge clips it);
    /// nil when the pane follows the window width.
    private(set) var previewFrozenWidth: CGFloat?

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var previewShown: Bool
    @ObservationIgnored private var contentHeight: CGFloat?
    @ObservationIgnored private var rememberedPreviewWidth: CGFloat?
    /// The width the running (or last) resize aims for.
    @ObservationIgnored private var targetWidth: CGFloat?
    /// Bumped by every resize; only the latest one may finish (coalesces rapid toggles).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isResizing = false
    @ObservationIgnored private var didInitialSize = false
    @ObservationIgnored private var heightTask: Task<Void, Never>?

    init(previewShown: Bool) {
        self.previewShown = previewShown
        previewMounted = previewShown
        widthRange = previewShown ? (Self.sidebarWidth + Self.previewMinWidth)...CGFloat.infinity
                                  : Self.sidebarWidth...Self.sidebarWidth
    }

    /// Called with the hosting window once it exists (and again on updates; repeats are ignored).
    func attach(_ newWindow: NSWindow?) {
        guard let newWindow, newWindow !== window else { return }
        window = newWindow
        if contentHeight != nil { resize(animated: false) }
    }

    /// The sidebar's measured content height (panel plus its outer padding).
    func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - (contentHeight ?? -1)) > 0.5 else { return }
        contentHeight = height
        heightTask?.cancel()
        heightTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.heightDebounce) } catch { return }
            guard let self else { return }
            resize(animated: didInitialSize)
        }
    }

    /// Shows or hides the preview with an animated width change. A call during a running animation
    /// retargets it, so the window always ends at the size of the latest state.
    func setPreviewShown(_ shown: Bool) {
        guard shown != previewShown else { return }
        let currentWidth = currentContentSize?.width ?? Self.sidebarWidth
        if shown {
            let previewWidth = max(rememberedPreviewWidth ?? Self.defaultPreviewWidth, Self.previewMinWidth)
            targetWidth = Self.sidebarWidth + previewWidth
            previewMounted = true
            // Inserted at its final width but clipped by the window edge, then revealed by the frame animation.
            previewFrozenWidth = max(previewFrozenWidth ?? 0, previewWidth)
        } else {
            if previewFrozenWidth == nil, currentWidth - Self.sidebarWidth >= Self.previewMinWidth {
                rememberedPreviewWidth = currentWidth - Self.sidebarWidth
            }
            targetWidth = Self.sidebarWidth
            // Keeps its current width while the window edge slides over it.
            previewFrozenWidth = max(previewFrozenWidth ?? 0, currentWidth - Self.sidebarWidth)
        }
        previewShown = shown
        resize(animated: true, width: targetWidth)
    }

    /// The size of the area the root view gets: the window uses a full-size content view, so the
    /// title bar is a safe-area inset and `contentLayoutRect` (not `contentRect`) is what SwiftUI lays out in.
    private var currentContentSize: CGSize? {
        window.map(\.contentLayoutRect.size)
    }

    /// Window frame size minus root view size (the title bar height).
    private static func chrome(of window: NSWindow) -> CGSize {
        CGSize(width: window.frame.width - window.contentLayoutRect.width,
               height: window.frame.height - window.contentLayoutRect.height)
    }

    /// Moves the window to the size the current state needs, keeping its top-left corner in place.
    /// `width` is the wanted content width for a preview toggle; nil keeps the current (or in-flight) width.
    private func resize(animated: Bool, width requestedWidth: CGFloat? = nil) {
        guard let window, let current = currentContentSize else { return }
        generation += 1
        let token = generation
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chrome = Self.chrome(of: window)
        let maxContent = CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)

        var width = Self.sidebarWidth
        if previewShown {
            // A height-only change keeps the width the user chose, or the one a running toggle aims for.
            let wanted = requestedWidth ?? (isResizing ? (targetWidth ?? current.width) : current.width)
            width = min(max(wanted, Self.sidebarWidth + Self.previewMinWidth), maxContent.width)
        }
        targetWidth = width
        let height = min(contentHeight ?? current.height, maxContent.height)
        let finalWidth = previewShown ? width...CGFloat.infinity : width...width
        let finalHeight = height...height

        // Cover both the current and the new size, so SwiftUI's limits never fight the animation.
        widthRange = min(finalWidth.lowerBound, current.width)...max(finalWidth.upperBound, current.width)
        heightRange = min(height, current.height)...max(height, current.height)
        isResizing = true

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Wait a runloop so SwiftUI has applied the widened limits before the frame changes.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, token == generation else { return }
            let frame = targetFrame(for: CGSize(width: width + chrome.width, height: height + chrome.height),
                                    in: window, visible: visible)
            let finish = { [weak self] in
                guard let self, token == generation else { return }
                widthRange = finalWidth
                heightRange = finalHeight
                previewFrozenWidth = nil
                previewMounted = previewShown
                isResizing = false
                didInitialSize = true
            }
            guard shouldAnimate, frame != window.frame else {
                window.setFrame(frame, display: true)
                finish()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: {
                MainActor.assumeIsolated { finish() }
            })
        }
    }

    /// The window frame of `size`, with the top-left corner fixed and kept on screen.
    private func targetFrame(for size: CGSize, in window: NSWindow, visible: CGRect) -> CGRect {
        var frame = CGRect(origin: .zero, size: size)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        return frame
    }
}
