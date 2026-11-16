import AppKit
import Observation
import ImageconverterCore

/// Drives the main window's size by the rules in `WindowLayout`. Height: collapsed pipeline → exactly
/// the sidebar's content; expanded → resizable by the user (remembered), at least the content's minimum.
/// Width: preview hidden → exactly the sidebar's width; preview open → resizable, at least 780 wide.
///
/// SwiftUI applies `widthRange`/`heightRange` as the root view's min/max size, which
/// `.windowResizability(.contentSize)` turns into the window's content min/max size.
///
/// Height changes (see `WindowSizer+Height.swift`): the sidebar reports its parts' natural heights, this
/// class works out `targetHeight`, the sidebar animates towards it (`SidebarMotion`) and reports the
/// height of every frame back, and the window is set to that height in the same pass, so the window edge
/// and the content move as one. The height range is loose while that runs and set to the rest range once
/// the window has arrived.
///
/// The metadata panel (inspector) sits right of the preview and only shows with it: opening it widens the window by
/// its width (the preview keeps its own), closing it narrows the window again; its width is the user's (persisted).
///
/// Width (preview shown/hidden): the ranges are first widened to cover both the current and the new size,
/// then the frame is animated with AppKit, and the ranges are tightened (and a hidden preview unmounted)
/// once the animation has finished, so SwiftUI never resizes the window on its own mid-animation.
@MainActor @Observable
final class WindowSizer {
    static let animationDuration: TimeInterval = SidebarMotion.duration

    /// Allowed window content width and height, applied by the root view.
    var widthRange: ClosedRange<CGFloat>
    var heightRange: ClosedRange<CGFloat>
    /// Whether the preview pane is in the view hierarchy; it stays while the hide animation runs.
    private(set) var previewMounted: Bool
    /// The preview's fixed width while an animation reveals or hides it (the window edge clips it);
    /// nil when the pane follows the window width.
    private(set) var previewFrozenWidth: CGFloat?
    /// Whether the metadata panel is in the view hierarchy; it stays while its hide animation runs.
    private(set) var inspectorMounted: Bool
    /// The metadata panel's width (persisted), within `WindowLayout.clampedInspectorWidth`.
    private(set) var inspectorWidth: CGFloat
    /// True while a frame or height animation runs; the sidebar hides its scroller then, so the content
    /// that is briefly taller than the growing window doesn't flash one.
    var isAnimating = false
    /// The window content height the sidebar is heading for; nil until it has been measured.
    var targetHeight: CGFloat?
    /// How much of the expanded pipeline the window shows, 0 (collapsed) … 1 (expanded), following the
    /// window edge frame by frame while the pipeline is collapsed or expanded; the preview's details use it.
    var pipelineReveal: CGFloat = 1

    /// Whether the next change of `targetHeight` should be animated.
    @ObservationIgnored var targetAnimates = false
    @ObservationIgnored var parts: WindowLayout.SidebarParts?
    @ObservationIgnored var pipelineCollapsed: Bool?
    /// The user's chosen expanded height (persisted); nil: the window fits the content.
    @ObservationIgnored var rememberedHeight: CGFloat?
    /// The expanded content height of the last measurement while expanded.
    @ObservationIgnored var previousExpanded: CGFloat?
    /// The collapsed and expanded heights a running collapse/expand animation goes between.
    @ObservationIgnored var toggleSpan: (collapsed: CGFloat, expanded: CGFloat)?
    @ObservationIgnored var isLiveResizing = false
    /// While the Output panel's handle is dragged: the content height the window keeps, so the pipeline steps
    /// give way instead of the window edge moving (see `pinHeight`).
    @ObservationIgnored var pinnedHeight: CGFloat?
    /// The remembered height when the pin was taken, and whether the pin is let go at the next measurement.
    @ObservationIgnored var rememberedBeforePin: CGFloat?
    @ObservationIgnored var releasePending = false
    @ObservationIgnored var releaseToken = 0
    @ObservationIgnored let defaults: UserDefaults
    static let rememberedHeightKey = "expandedWindowHeight"
    static let inspectorWidthKey = "inspectorWidth"

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var behaviorObservation: NSKeyValueObservation?
    @ObservationIgnored var previewShown: Bool
    /// Whether the metadata panel is open (it shows only with the preview).
    @ObservationIgnored private(set) var inspectorShown: Bool
    /// The width the open metadata panel takes in the window: 0 when it is closed or the preview is hidden.
    var openInspectorWidth: CGFloat { previewShown && inspectorShown ? inspectorWidth : 0 }
    @ObservationIgnored private var rememberedPreviewWidth: CGFloat?
    /// The width a running preview toggle aims for.
    @ObservationIgnored private var targetWidth: CGFloat?
    /// Bumped by every resize; only the latest one may finish (coalesces rapid toggles).
    @ObservationIgnored var generation = 0
    @ObservationIgnored var isResizing = false
    @ObservationIgnored var didInitialSize = false

    init(previewShown: Bool, inspectorShown: Bool = false, defaults: UserDefaults = .standard) {
        self.previewShown = previewShown
        self.inspectorShown = inspectorShown
        self.defaults = defaults
        let width = defaults.double(forKey: Self.inspectorWidthKey)
        let panelWidth = WindowLayout.clampedInspectorWidth(width > 0 ? CGFloat(width) : WindowLayout.defaultInspectorWidth)
        inspectorWidth = panelWidth
        inspectorMounted = previewShown && inspectorShown
        let remembered = defaults.double(forKey: Self.rememberedHeightKey)
        rememberedHeight = remembered > 0 ? CGFloat(remembered) : nil
        previewMounted = previewShown
        let limits = WindowLayout.limits(previewShown: previewShown, fittedHeight: WindowLayout.minContentHeight,
                                         maxContent: CGSize(width: CGFloat.infinity, height: CGFloat.infinity),
                                         inspectorWidth: previewShown && inspectorShown ? panelWidth : 0)
        widthRange = limits.width
        // The height is unknown until the sidebar has been measured.
        heightRange = WindowLayout.minContentHeight...CGFloat.infinity
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
        let resizeStarted: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveResizing = true }
        }
        let resizeEnded: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.liveResizeEnded() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: newWindow, queue: .main,
                               using: reclamp),
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
                               using: reclamp),
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: newWindow, queue: .main,
                               using: resizeStarted),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: newWindow, queue: .main,
                               using: resizeEnded)
        ]
        if targetHeight != nil { resize(animated: false) }
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
            targetWidth = sidebar + previewWidth + openInspectorWidth
            previewMounted = true
            inspectorMounted = inspectorShown
            // Inserted at its final width but clipped by the window edge, then revealed by the frame animation.
            previewFrozenWidth = max(previewFrozenWidth ?? 0, previewWidth)
        } else {
            let panel = inspectorMounted ? inspectorWidth : 0
            if previewFrozenWidth == nil, currentWidth - sidebar - panel >= WindowLayout.previewMinWidth {
                rememberedPreviewWidth = currentWidth - sidebar - panel
            }
            targetWidth = sidebar
            // Keeps its current width while the window edge slides over it.
            previewFrozenWidth = max(previewFrozenWidth ?? 0, currentWidth - sidebar - panel)
        }
        resize(animated: true, width: targetWidth)
    }

    /// Opens or closes the metadata panel: with the preview shown, the window grows or shrinks by the panel's width
    /// (animated) while the preview keeps its width; with the preview hidden only the state is recorded.
    func setInspectorShown(_ shown: Bool) {
        guard shown != inspectorShown else { return }
        let panelBefore = inspectorMounted ? inspectorWidth : 0
        inspectorShown = shown
        guard previewShown, let currentWidth = currentContentSize?.width else {
            inspectorMounted = previewShown && shown
            return
        }
        let previewWidth = max(previewFrozenWidth ?? (currentWidth - WindowLayout.sidebarWidth - panelBefore),
                               WindowLayout.previewMinWidth)
        previewFrozenWidth = previewWidth
        if shown { inspectorMounted = true }
        targetWidth = WindowLayout.sidebarWidth + previewWidth + (shown ? inspectorWidth : 0)
        resize(animated: true, width: targetWidth)
    }

    /// Sets the metadata panel's width (its edge handle): the border moves, the window keeps its width and the
    /// preview gives way down to its minimum.
    func setInspectorWidth(_ width: CGFloat) {
        let clamped = WindowLayout.clampedInspectorWidth(width, windowWidth: currentContentSize?.width)
        guard abs(clamped - inspectorWidth) > 0.5 else { return }
        inspectorWidth = clamped
        defaults.set(Double(clamped), forKey: Self.inspectorWidthKey)
        applyRestLimits()
    }

    /// The size of the area the root view gets: the window uses a full-size content view, so the
    /// title bar is a safe-area inset and `contentLayoutRect` (not `contentRect`) is what SwiftUI lays out in.
    var currentContentSize: CGSize? {
        window.map(\.contentLayoutRect.size)
    }

    /// A window that always fits its panels has no use for full screen; the green button zooms
    /// instead, which the size limits keep within the rules.
    private static func disableFullScreen(_ window: NSWindow) {
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
    }

    /// Window frame size minus root view size (the title bar height).
    static func chrome(of window: NSWindow) -> CGSize {
        CGSize(width: window.frame.width - window.contentLayoutRect.width,
               height: window.frame.height - window.contentLayoutRect.height)
    }

    /// Moves the window to the size the current state needs, keeping its top-left corner in place.
    /// `width` is the wanted content width for a preview toggle; nil keeps the current (or in-flight) width.
    func resize(animated: Bool, width requestedWidth: CGFloat? = nil) {
        guard let window, let current = currentContentSize else { return }
        generation += 1
        let token = generation
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chrome = Self.chrome(of: window)
        let maxContent = CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)
        let content = targetHeight ?? current.height
        // A height change during a running preview toggle keeps aiming for that toggle's width.
        let width = requestedWidth ?? (isResizing && previewShown ? targetWidth : nil)
        let target = WindowLayout.targetSize(previewShown: previewShown, current: current, contentHeight: content,
                                             requestedWidth: width, maxContent: maxContent,
                                             inspectorWidth: openInspectorWidth)
        targetWidth = target.width
        let final = restLimits(height: target.height, maxContent: maxContent)
        let during = WindowLayout.transitional(final, current: current, target: target)
        widthRange = during.width
        heightRange = during.height
        isResizing = true

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate { isAnimating = true }
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
                inspectorMounted = previewShown && inspectorShown
                isResizing = false
                isAnimating = false
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
