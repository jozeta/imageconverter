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

    /// The part of the image the view shows, in unit coordinates (origin top left). The whole image at fit;
    /// an axis that still fits keeps its full extent.
    public static func visibleRegion(_ state: ZoomState, imagePixels: CGSize, view: CGSize) -> CGRect {
        let shown = displayedSize(imagePixels: imagePixels, view: view, scale: state.scale)
        guard shown.width > 0, shown.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let center = clampCenter(state.center, displayed: shown, view: view)
        let width = min(1, view.width / shown.width)
        let height = min(1, view.height / shown.height)
        return CGRect(x: max(0, center.x - width / 2), y: max(0, center.y - height / 2), width: width, height: height)
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

/// One side's zoom geometry: the image's full pixel size, the side's view size (points) and the display's
/// pixels per point.
public struct ZoomGeometry: Equatable, Sendable {
    public var imagePixels: CGSize
    public var view: CGSize
    public var pixelsPerPoint: CGFloat

    public init(imagePixels: CGSize, view: CGSize, pixelsPerPoint: CGFloat) {
        self.imagePixels = imagePixels
        self.view = view
        self.pixelsPerPoint = pixelsPerPoint
    }

    public var maxScale: CGFloat {
        ZoomMath.maxScale(imagePixels: imagePixels, view: view, pixelsPerPoint: pixelsPerPoint)
    }
    public var actualScale: CGFloat {
        ZoomMath.actualPixelsScale(imagePixels: imagePixels, view: view, pixelsPerPoint: pixelsPerPoint)
    }
    /// The zoom level as a percentage of actual pixels (100 % = one image pixel per screen pixel).
    public func percent(at scale: CGFloat) -> CGFloat { scale / actualScale * 100 }
}

/// Input handling on the shared state. `side` is the geometry of the side the input came from (used to turn
/// anchor and pan points into image coordinates); `reference` (the After side) sets the scale range and what
/// 100 % means, so both sides and the menu behave the same. Without a reference the side's own geometry is used.
public extension ZoomState {
    func zoomed(to scale: CGFloat, anchor: CGPoint, side: ZoomGeometry, reference: ZoomGeometry?) -> ZoomState {
        let limit = (reference ?? side).maxScale
        return ZoomMath.zoom(self, to: ZoomMath.clampScale(scale, max: limit), anchor: anchor,
                             imagePixels: side.imagePixels, view: side.view)
    }

    /// Double-click: fit when zoomed, otherwise 100 % of the reference at the anchor (or the maximum for a
    /// tiny image that already shows larger than actual pixels at fit).
    func toggled(at anchor: CGPoint, side: ZoomGeometry, reference: ZoomGeometry?) -> ZoomState {
        if isZoomed { return .fit }
        let range = reference ?? side
        let target = range.actualScale > 1.01 ? range.actualScale : range.maxScale
        return zoomed(to: target, anchor: anchor, side: side, reference: reference)
    }

    func panned(by delta: CGSize, side: ZoomGeometry) -> ZoomState {
        guard isZoomed else { return self }
        return ZoomMath.pan(self, by: delta, imagePixels: side.imagePixels, view: side.view)
    }
}
