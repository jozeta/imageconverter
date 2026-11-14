import AppKit
import Observation
import ImageconverterCore

/// Drives the main window's size by the rules in `WindowLayout`: preview hidden → exactly the sidebar
/// and its content; preview open → resizable, at least 780 × 560, the sidebar panel stretching to the
/// window height.
///
/// SwiftUI applies `widthRange`/`heightRange` as the root view's min/max size, which
/// `.windowResizability(.contentSize)` turns into the window's content min/max size. A change is
/// animated by first widening the ranges to cover both the current and the new size, then animating
/// the frame with AppKit, and only tightening the ranges (and unmounting a hidden preview) once the
/// animation has finished. SwiftUI therefore never resizes the window on its own mid-animation,
/// which is what made the old toggle jump and flicker.
@MainActor @Observable
final class WindowSizer {
    static let animationDuration: TimeInterval = 0.2
    /// Wait after the last incidental content height change before following it, so typing and quick
    /// expand/collapse sequences give one animation instead of a storm.
    static let heightDebounce = Duration.milliseconds(60)
    /// A content height change this soon after a pipeline toggle is that toggle's, and is followed at once.
    static let toggleWindow: TimeInterval = 0.5

    /// Allowed window content width and height, applied by the root view.
    private(set) var widthRange: ClosedRange<CGFloat>
    private(set) var heightRange: ClosedRange<CGFloat>
    /// Whether the preview pane is in the view hierarchy; it stays while the hide animation runs.
    private(set) var previewMounted: Bool
    /// The preview's fixed width while an animation reveals or hides it (the window edge clips it);
    /// nil when the pane follows the window width.
    private(set) var previewFrozenWidth: CGFloat?

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var behaviorObservation: NSKeyValueObservation?
    @ObservationIgnored private var previewShown: Bool
    @ObservationIgnored private var contentHeight: CGFloat?
    /// The content height the window was last sized for (to tell whether it was snug).
    @ObservationIgnored private var sizedContentHeight: CGFloat?
    @ObservationIgnored private var rememberedPreviewWidth: CGFloat?
    /// The width a running preview toggle aims for.
    @ObservationIgnored private var targetWidth: CGFloat?
    /// Bumped by every resize; only the latest one may finish (coalesces rapid toggles).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isResizing = false
    @ObservationIgnored private var didInitialSize = false
    @ObservationIgnored private var heightTask: Task<Void, Never>?
    @ObservationIgnored private var pipelineToggledAt: Date?

    init(previewShown: Bool) {
        self.previewShown = previewShown
        previewMounted = previewShown
        let limits = WindowLayout.limits(previewShown: previewShown, fittedHeight: 200,
                                         maxContent: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        widthRange = limits.width
        // The height is unknown until the sidebar has been measured.
        heightRange = previewShown ? limits.height : 200...CGFloat.infinity
    }

    /// Called with the hosting window once it exists (and again on updates; repeats are ignored).
    func attach(_ newWindow: NSWindow?) {
        guard let newWindow, newWindow !== window else { return }
        window = newWindow
        Self.disableFullScreen(newWindow)
        // SwiftUI turns full screen back on whenever it applies new size limits; switch it off again.
        behaviorObservation = newWindow.observe(\.collectionBehavior) { window, _ in
            guard !window.collectionBehavior.contains(.fullScreenNone) else { return }
            DispatchQueue.main.async { Self.disableFullScreen(window) }
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        let reclamp: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.resize(animated: false) }
        }
        observers = [
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: newWindow, queue: .main,
                               using: reclamp),
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
                               using: reclamp)
        ]
        if contentHeight != nil { resize(animated: false) }
    }

    /// Call right before the pipeline is collapsed or expanded, so the resulting height change is
    /// followed at once instead of after the debounce.
    func pipelineWillToggle() {
        pipelineToggledAt = Date()
    }

    /// The sidebar's natural content height (panel plus its outer padding).
    func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - (contentHeight ?? -1)) > 0.5 else { return }
        contentHeight = height
        heightTask?.cancel()
        if let toggled = pipelineToggledAt, Date().timeIntervalSince(toggled) < Self.toggleWindow {
            pipelineToggledAt = nil
            resize(animated: didInitialSize)
            return
        }
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
        previewShown = shown
        guard let currentWidth = currentContentSize?.width else {
            // No window (closed): just record the state; `attach` sizes the next one.
            previewMounted = shown
            previewFrozenWidth = nil
            return
        }
        let sidebar = WindowLayout.sidebarWidth
        if shown {
            let previewWidth = max(rememberedPreviewWidth ?? WindowLayout.defaultPreviewWidth,
                                   WindowLayout.previewMinWidth)
            targetWidth = sidebar + previewWidth
            previewMounted = true
            // Inserted at its final width but clipped by the window edge, then revealed by the frame animation.
            previewFrozenWidth = max(previewFrozenWidth ?? 0, previewWidth)
        } else {
            if previewFrozenWidth == nil, currentWidth - sidebar >= WindowLayout.previewMinWidth {
                rememberedPreviewWidth = currentWidth - sidebar
            }
            targetWidth = sidebar
            // Keeps its current width while the window edge slides over it.
            previewFrozenWidth = max(previewFrozenWidth ?? 0, currentWidth - sidebar)
        }
        resize(animated: true, width: targetWidth)
    }

    /// The size of the area the root view gets: the window uses a full-size content view, so the
    /// title bar is a safe-area inset and `contentLayoutRect` (not `contentRect`) is what SwiftUI lays out in.
    private var currentContentSize: CGSize? {
        window.map(\.contentLayoutRect.size)
    }

    /// A window that always fits its panels has no use for full screen; the green button zooms
    /// instead, which the size limits keep within the rules.
    private static func disableFullScreen(_ window: NSWindow) {
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
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
        let content = contentHeight ?? current.height
        // A height change during a running preview toggle keeps aiming for that toggle's width.
        let width = requestedWidth ?? (isResizing && previewShown ? targetWidth : nil)
        let target = WindowLayout.targetSize(
            previewShown: previewShown, current: current, contentHeight: content,
            reason: width.map { .toggle(width: $0) } ?? .contentChanged(previous: isResizing ? nil : sizedContentHeight),
            maxContent: maxContent)
        targetWidth = target.width
        sizedContentHeight = content
        let final = WindowLayout.limits(previewShown: previewShown, fittedHeight: target.height, maxContent: maxContent)
        let during = WindowLayout.transitional(final, current: current, target: target)
        widthRange = during.width
        heightRange = during.height
        isResizing = true

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Wait a runloop so SwiftUI has applied the widened limits before the frame changes.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, token == generation else { return }
            let frame = WindowLayout.frame(contentSize: target, chrome: chrome, currentFrame: window.frame,
                                           visible: visible)
            let finish = { [weak self] in
                guard let self, token == generation else { return }
                widthRange = final.width
                heightRange = final.height
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
}
