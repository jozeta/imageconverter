import CoreGraphics

/// The main window's size rules (pure maths; the app's `WindowSizer` applies them to the window).
///
/// Preview hidden: the window is exactly the sidebar (fixed width) and exactly as tall as its content.
/// Preview open: at least sidebar + preview minimum wide and `previewMinHeight` tall, user-resizable
/// beyond that; the sidebar panel stretches to the window height.
/// All sizes are content sizes (the title bar excluded) and are clamped to the screen's visible area.
public enum WindowLayout {
    public static let sidebarWidth: CGFloat = 360
    public static let previewMinWidth: CGFloat = 420
    public static let previewMinHeight: CGFloat = 560
    public static let defaultPreviewWidth: CGFloat = 640

    public struct Limits: Equatable, Sendable {
        public var width: ClosedRange<CGFloat>
        public var height: ClosedRange<CGFloat>

        public init(width: ClosedRange<CGFloat>, height: ClosedRange<CGFloat>) {
            self.width = width
            self.height = height
        }
    }

    /// The window's min/max content size when no animation runs. `fittedHeight` is the hidden-preview
    /// height (see `targetSize`); it is ignored while the preview is open.
    public static func limits(previewShown: Bool, fittedHeight: CGFloat, maxContent: CGSize) -> Limits {
        if previewShown {
            let minWidth = min(sidebarWidth + previewMinWidth, maxContent.width)
            let minHeight = min(previewMinHeight, maxContent.height)
            return Limits(width: minWidth...CGFloat.infinity, height: minHeight...CGFloat.infinity)
        }
        return Limits(width: sidebarWidth...sidebarWidth, height: fittedHeight...fittedHeight)
    }

    /// Limits that allow both the current and the target size, used while an animation runs.
    public static func transitional(_ final: Limits, current: CGSize, target: CGSize) -> Limits {
        Limits(width: min(final.width.lowerBound, current.width, target.width)
                   ... max(final.width.upperBound, current.width, target.width),
               height: min(final.height.lowerBound, current.height, target.height)
                   ... max(final.height.upperBound, current.height, target.height))
    }

    /// The height that fits the sidebar content (at least `previewMinHeight` with the preview open).
    public static func fittingHeight(previewShown: Bool, contentHeight: CGFloat, maxContent: CGSize) -> CGFloat {
        min(previewShown ? max(previewMinHeight, contentHeight) : contentHeight, maxContent.height)
    }

    /// Why the window is being sized.
    public enum Reason: Equatable, Sendable {
        /// A preview toggle aiming for this content width; the height then fits the content.
        case toggle(width: CGFloat)
        /// The content or the screen changed. `previous` is the content height the window was last sized
        /// for: with the preview open, a window that was snug around it follows the content, one the user
        /// made taller keeps its height and only grows when the content needs more room (nil: not snug).
        case contentChanged(previous: CGFloat?)
    }

    /// The content size the window should have.
    public static func targetSize(previewShown: Bool, current: CGSize, contentHeight: CGFloat,
                                  reason: Reason, maxContent: CGSize) -> CGSize {
        var requestedWidth: CGFloat?
        var previousContentHeight: CGFloat?
        switch reason {
        case .toggle(let width): requestedWidth = width
        case .contentChanged(let previous): previousContentHeight = previous
        }
        let fit = fittingHeight(previewShown: previewShown, contentHeight: contentHeight, maxContent: maxContent)
        guard previewShown else { return CGSize(width: sidebarWidth, height: fit) }
        let minWidth = min(sidebarWidth + previewMinWidth, maxContent.width)
        let width = min(max(requestedWidth ?? current.width, minWidth), maxContent.width)
        var height = fit
        if requestedWidth == nil {
            let wasSnug = previousContentHeight.map {
                abs(current.height - fittingHeight(previewShown: true, contentHeight: $0, maxContent: maxContent)) < 1
            } ?? false
            if !wasSnug { height = min(max(current.height, fit), maxContent.height) }
        }
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
