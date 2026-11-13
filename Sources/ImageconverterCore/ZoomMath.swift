import CoreGraphics

/// Zoom and pan of an image in a view, shared by the before and after sides of the preview.
/// `scale` is relative to the fitted size (1 = the whole image fits the view) and `center` is the image
/// point shown in the middle of the view, in unit coordinates (0…1, origin top left) of each image,
/// so two images of different pixel sizes show the same region.
public struct ZoomState: Equatable, Sendable {
    public var scale: CGFloat
    public var center: CGPoint

    public init(scale: CGFloat = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.scale = scale
        self.center = center
    }

    public static let fit = ZoomState()
    public var isZoomed: Bool { scale > 1.0001 }
}

/// Pure zoom maths (no UI). Sizes are in points except `imagePixels`; anchors and pan distances are
/// in view points measured from the view's centre, y down.
public enum ZoomMath {
    /// How many times the fitted size may be enlarged: up to `maxActual` × actual pixels, never below fit.
    public static let maxActual: CGFloat = 8

    /// Points per image pixel when the image fits the view.
    public static func fitPointsPerPixel(imagePixels: CGSize, view: CGSize) -> CGFloat {
        guard imagePixels.width > 0, imagePixels.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(view.width / imagePixels.width, view.height / imagePixels.height)
    }

    /// The zoom scale at which one image pixel covers one screen pixel (`pixelsPerPoint` = backing scale).
    public static func actualPixelsScale(imagePixels: CGSize, view: CGSize, pixelsPerPoint: CGFloat) -> CGFloat {
        1 / (fitPointsPerPixel(imagePixels: imagePixels, view: view) * max(pixelsPerPoint, 0.01))
    }

    /// The largest allowed scale: 8× actual pixels, or fit when a tiny image already fits larger than that.
    public static func maxScale(imagePixels: CGSize, view: CGSize, pixelsPerPoint: CGFloat) -> CGFloat {
        max(1, maxActual * actualPixelsScale(imagePixels: imagePixels, view: view, pixelsPerPoint: pixelsPerPoint))
    }

    public static func clampScale(_ scale: CGFloat, max upper: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, 1), max(upper, 1))
    }

    /// The on-screen size of the whole image at `scale`.
    public static func displayedSize(imagePixels: CGSize, view: CGSize, scale: CGFloat) -> CGSize {
        let pointsPerPixel = fitPointsPerPixel(imagePixels: imagePixels, view: view) * scale
        return CGSize(width: imagePixels.width * pointsPerPixel, height: imagePixels.height * pointsPerPixel)
    }

    /// Keeps the image edges from moving inside the view; an axis that fits is centred.
    public static func clampCenter(_ center: CGPoint, displayed: CGSize, view: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, _ shown: CGFloat, _ available: CGFloat) -> CGFloat {
            guard shown > available, shown > 0 else { return 0.5 }
            let half = available / (2 * shown)
            return min(max(value.isFinite ? value : 0.5, half), 1 - half)
        }
        return CGPoint(x: axis(center.x, displayed.width, view.width),
                       y: axis(center.y, displayed.height, view.height))
    }

    /// Changes the scale while keeping the image point under `anchor` (from the view centre) where it is.
    /// The caller limits `newScale` to the maximum (`clampScale`); here it is only kept at fit or larger.
    public static func zoom(_ state: ZoomState, to newScale: CGFloat, anchor: CGPoint,
                            imagePixels: CGSize, view: CGSize) -> ZoomState {
        let target = newScale.isFinite ? max(newScale, 1) : 1
        let before = displayedSize(imagePixels: imagePixels, view: view, scale: state.scale)
        let after = displayedSize(imagePixels: imagePixels, view: view, scale: target)
        guard before.width > 0, before.height > 0, after.width > 0, after.height > 0 else { return state }
        // The image point under the anchor, before and after, must be the same.
        let pinned = CGPoint(x: state.center.x + anchor.x / before.width, y: state.center.y + anchor.y / before.height)
        let center = CGPoint(x: pinned.x - anchor.x / after.width, y: pinned.y - anchor.y / after.height)
        return ZoomState(scale: target, center: clampCenter(center, displayed: after, view: view))
    }

    /// Moves the image by `delta` points (positive x right, positive y down).
    public static func pan(_ state: ZoomState, by delta: CGSize, imagePixels: CGSize, view: CGSize) -> ZoomState {
        let shown = displayedSize(imagePixels: imagePixels, view: view, scale: state.scale)
        guard shown.width > 0, shown.height > 0 else { return state }
        let center = CGPoint(x: state.center.x - delta.width / shown.width,
                             y: state.center.y - delta.height / shown.height)
        return ZoomState(scale: state.scale, center: clampCenter(center, displayed: shown, view: view))
    }
}
