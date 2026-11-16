import CoreGraphics

/// The main window's size rules (pure maths; the app's `WindowSizer` applies them to the window).
///
/// Height (Johan): with the pipeline collapsed the window is exactly as tall as the sidebar's content.
/// With the pipeline expanded the user may resize it vertically, from `SidebarParts.expandedMinimum` to
/// the screen: extra height goes between the last pipeline step and the Output panel, and when it is
/// shorter than the content the steps scroll. Their chosen expanded height is remembered; without one
/// the window fits the content. Width: only an open preview makes it resizable (at least sidebar +
/// preview minimum). All sizes are content sizes (the title bar excluded), clamped to the screen.
public enum WindowLayout {
    public static let sidebarWidth: CGFloat = 360
    public static let previewMinWidth: CGFloat = 420
    /// A floor for tiny content only; normally the content is taller.
    public static let minContentHeight: CGFloat = 300
    public static let defaultPreviewWidth: CGFloat = 640
    /// The metadata panel right of the preview (shown only with the preview): its width range and default.
    /// Opening it widens the window by its width; its edge handle moves the border with the preview.
    public static let inspectorMinWidth: CGFloat = 260
    public static let inspectorMaxWidth: CGFloat = 560
    public static let defaultInspectorWidth: CGFloat = 300

    /// `width` within the panel's range and within what a window `windowWidth` wide leaves after the sidebar and
    /// the preview's minimum (never below the panel's minimum).
    public static func clampedInspectorWidth(_ width: CGFloat, windowWidth: CGFloat? = nil) -> CGFloat {
        var upper = inspectorMaxWidth
        if let windowWidth { upper = min(upper, max(inspectorMinWidth, windowWidth - sidebarWidth - previewMinWidth)) }
        guard width.isFinite else { return defaultInspectorWidth }
        return min(max(width, inspectorMinWidth), upper)
    }

    /// The natural heights of the sidebar's parts, measured by the app; the window heights follow from them.
    public struct SidebarParts: Equatable, Sendable {
        /// Preset bar down to the pipeline header.
        public var top: CGFloat
        /// The pipeline steps list ("+ Add step", the steps, Metadata/Rename), unscrolled.
        public var steps: CGFloat
        /// The Output panel.
        public var output: CGFloat
        /// Run (and the report under it).
        public var bottom: CGFloat
        /// Panel and window paddings, top and bottom together.
        public var chrome: CGFloat
        /// Between the header and the steps list.
        public var stepsGap: CGFloat
        /// Between the steps and Output (at least; extra height widens it) and above the bottom part.
        public var spacing: CGFloat

        /// The steps list keeps at least this much room in a window the user made shorter (it scrolls).
        public static let minimumStepsHeight: CGFloat = 60

        public init(top: CGFloat, steps: CGFloat, output: CGFloat, bottom: CGFloat, chrome: CGFloat,
                    stepsGap: CGFloat, spacing: CGFloat) {
            self.top = top
            self.steps = steps
            self.output = output
            self.bottom = bottom
            self.chrome = chrome
            self.stepsGap = stepsGap
            self.spacing = spacing
        }

        /// The content height with the pipeline collapsed (no steps, no Output).
        public var collapsed: CGFloat { chrome + top + spacing + bottom }
        /// The content height with the pipeline expanded and every step visible.
        public var expanded: CGFloat { collapsed + stepsGap + steps + spacing + output }
        /// The smallest expanded height: the steps list scrolls in a minimal strip, the rest stays visible.
        public var expandedMinimum: CGFloat {
            collapsed + stepsGap + min(steps, Self.minimumStepsHeight) + spacing + output
        }
    }

    /// The expanded window height after a content change, and the remembered (user-chosen) height.
    ///
    /// No remembered height: the window fits the content. With one, the window keeps it (the gap above
    /// Output absorbs shrinking content), except that content growing past a window that showed all of it
    /// grows the window (and the remembered height) with it, up to the screen. `previousContent` is the
    /// expanded content height before this change (nil if unknown).
    public static func expandedHeight(parts: SidebarParts, remembered: CGFloat?, previousContent: CGFloat?,
                                      maxContent: CGSize) -> (height: CGFloat, remembered: CGFloat?) {
        let content = parts.expanded
        var remembered = remembered
        if let chosen = remembered, let previous = previousContent,
           chosen >= previous - 0.5, content > chosen + 0.5 {
            remembered = content
        }
        let range = expandedHeights(parts: parts, maxContent: maxContent)
        let height = min(max(remembered ?? content, range.lowerBound), range.upperBound)
        return (height, remembered)
    }

    /// The remembered height once a pinned height is let go (the Output panel's handle was dragged or stepped while
    /// the window kept its height). Measured with the parts as they are after the change: when the content now fits
    /// in the pinned height (the steps would show empty room, e.g. after collapsing Output), the remembered height from
    /// before the pin comes back (nil: the window fits the content again, so no gap is left); when the content is
    /// taller (the steps scroll), the pinned height is kept, like a window the user resized.
    public static func releasedRememberedHeight(pinned: CGFloat, parts: SidebarParts, rememberedBefore: CGFloat?,
                                                maxContent: CGSize) -> CGFloat? {
        let range = expandedHeights(parts: parts, maxContent: maxContent)
        let height = min(max(pinned, range.lowerBound), range.upperBound)
        return height >= parts.expanded - 1 ? rememberedBefore : height
    }

    /// The heights an expanded window may be resized to: the minimum that keeps everything but most of
    /// the steps visible, up to the screen.
    public static func expandedHeights(parts: SidebarParts, maxContent: CGSize) -> ClosedRange<CGFloat> {
        let top = max(maxContent.height, minContentHeight)
        let bottom = min(max(parts.expandedMinimum, minContentHeight), top)
        return bottom...top
    }

    /// The window's height range at rest: fixed to the fitted height when collapsed, resizable when expanded.
    public static func restHeights(collapsed: Bool, parts: SidebarParts, height: CGFloat,
                                   maxContent: CGSize) -> ClosedRange<CGFloat> {
        if collapsed { return height...height }
        let range = expandedHeights(parts: parts, maxContent: maxContent)
        return min(range.lowerBound, height)...max(range.upperBound, height)
    }

    public struct Limits: Equatable, Sendable {
        public var width: ClosedRange<CGFloat>
        public var height: ClosedRange<CGFloat>

        public init(width: ClosedRange<CGFloat>, height: ClosedRange<CGFloat>) {
            self.width = width
            self.height = height
        }
    }

    /// The window's min/max content size for a height range (see `restHeights`).
    public static func limits(previewShown: Bool, heights: ClosedRange<CGFloat>, maxContent: CGSize,
                              inspectorWidth: CGFloat = 0) -> Limits {
        var limits = limits(previewShown: previewShown, fittedHeight: heights.lowerBound, maxContent: maxContent,
                            inspectorWidth: inspectorWidth)
        limits.height = heights
        return limits
    }

    /// The window's min/max content size when no animation runs. `fittedHeight` is the content-fitted
    /// height (see `fittingHeight`); the height is fixed to it whether or not the preview is open.
    /// `inspectorWidth`: the open metadata panel's width (0 when closed), added to the open preview's minimum.
    public static func limits(previewShown: Bool, fittedHeight: CGFloat, maxContent: CGSize,
                              inspectorWidth: CGFloat = 0) -> Limits {
        let height = fittedHeight...fittedHeight
        if previewShown {
            let minWidth = min(sidebarWidth + previewMinWidth + inspectorWidth, maxContent.width)
            return Limits(width: minWidth...CGFloat.infinity, height: height)
        }
        return Limits(width: sidebarWidth...sidebarWidth, height: height)
    }

    /// The height range while the window follows an animating sidebar frame by frame: anything from the
    /// minimum to the screen, so SwiftUI never pulls the window back to a stale fixed height mid-animation.
    public static func followingHeights(maxContent: CGSize) -> ClosedRange<CGFloat> {
        let top = max(maxContent.height, minContentHeight)
        return minContentHeight...top
    }

    /// Limits that allow both the current and the target size, used while an animation runs.
    public static func transitional(_ final: Limits, current: CGSize, target: CGSize) -> Limits {
        Limits(width: min(final.width.lowerBound, current.width, target.width)
                   ... max(final.width.upperBound, current.width, target.width),
               height: min(final.height.lowerBound, current.height, target.height)
                   ... max(final.height.upperBound, current.height, target.height))
    }

    /// The window height: the sidebar's content height (at least `minContentHeight`), clamped to the
    /// screen. Content taller than the screen scrolls in the sidebar.
    public static func fittingHeight(contentHeight: CGFloat, maxContent: CGSize) -> CGFloat {
        min(max(contentHeight, minContentHeight), maxContent.height)
    }

    /// The content size the window should have. `requestedWidth` is the width a preview toggle aims
    /// for; nil keeps the current width (within the open-preview minimum and the screen).
    public static func targetSize(previewShown: Bool, current: CGSize, contentHeight: CGFloat,
                                  requestedWidth: CGFloat?, maxContent: CGSize, inspectorWidth: CGFloat = 0) -> CGSize {
        let height = fittingHeight(contentHeight: contentHeight, maxContent: maxContent)
        guard previewShown else { return CGSize(width: sidebarWidth, height: height) }
        let minWidth = min(sidebarWidth + previewMinWidth + inspectorWidth, maxContent.width)
        let width = min(max(requestedWidth ?? current.width, minWidth), maxContent.width)
        return CGSize(width: width, height: height)
    }

    /// The window frame for a content size: the top-left corner stays where it is, and the frame is
    /// moved (not shrunk) only as far as needed to stay inside `visible`.
    public static func frame(contentSize: CGSize, chrome: CGSize, currentFrame: CGRect, visible: CGRect) -> CGRect {
        var frame = CGRect(x: currentFrame.minX, y: 0,
                           width: contentSize.width + chrome.width, height: contentSize.height + chrome.height)
        frame.origin.y = currentFrame.maxY - frame.height
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        return frame
    }
}
