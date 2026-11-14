import CoreGraphics

/// The main window's size rules (pure maths; the app's `WindowSizer` applies them to the window).
///
/// The window is always exactly as tall as the sidebar's content (Johan), preview open or not; only an
/// open preview makes it user-resizable, and only in width (at least sidebar + preview minimum).
/// All sizes are content sizes (the title bar excluded) and are clamped to the screen's visible area.
public enum WindowLayout {
    public static let sidebarWidth: CGFloat = 360
    public static let previewMinWidth: CGFloat = 420
    /// A floor for tiny content only; normally the content is taller.
    public static let minContentHeight: CGFloat = 300
    public static let defaultPreviewWidth: CGFloat = 640

    public struct Limits: Equatable, Sendable {
        public var width: ClosedRange<CGFloat>
        public var height: ClosedRange<CGFloat>

        public init(width: ClosedRange<CGFloat>, height: ClosedRange<CGFloat>) {
            self.width = width
            self.height = height
        }
    }

    /// The window's min/max content size when no animation runs. `fittedHeight` is the content-fitted
    /// height (see `fittingHeight`); the height is fixed to it whether or not the preview is open.
    public static func limits(previewShown: Bool, fittedHeight: CGFloat, maxContent: CGSize) -> Limits {
        let height = fittedHeight...fittedHeight
        if previewShown {
            let minWidth = min(sidebarWidth + previewMinWidth, maxContent.width)
            return Limits(width: minWidth...CGFloat.infinity, height: height)
        }
        return Limits(width: sidebarWidth...sidebarWidth, height: height)
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
                                  requestedWidth: CGFloat?, maxContent: CGSize) -> CGSize {
        let height = fittingHeight(contentHeight: contentHeight, maxContent: maxContent)
        guard previewShown else { return CGSize(width: sidebarWidth, height: height) }
        let minWidth = min(sidebarWidth + previewMinWidth, maxContent.width)
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
