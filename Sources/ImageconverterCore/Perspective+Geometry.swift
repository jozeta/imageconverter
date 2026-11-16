import CoreGraphics
import Foundation

/// Four corners, top-left origin (y down).
struct Quad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// The smallest axis-aligned rectangle holding all four corners.
    var bounds: CGRect {
        let across = corners.map(\.x)
        let down = corners.map(\.y)
        let minX = across.min() ?? 0
        let minY = down.min() ?? 0
        return CGRect(x: minX, y: minY, width: (across.max() ?? 0) - minX, height: (down.max() ?? 0) - minY)
    }

    /// Where the horizontal line at `y` crosses this (convex) quad, or nil when it misses it.
    func span(atY row: CGFloat) -> ClosedRange<CGFloat>? {
        let tolerance: CGFloat = 1e-9
        var crossings: [CGFloat] = []
        let points = corners
        for index in points.indices {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let low = min(start.y, end.y)
            let high = max(start.y, end.y)
            guard row >= low - tolerance, row <= high + tolerance else { continue }
            if high - low < tolerance {
                crossings += [start.x, end.x]
            } else {
                let fraction = min(1, max(0, (row - start.y) / (end.y - start.y)))
                crossings.append(start.x + fraction * (end.x - start.x))
            }
        }
        guard let lower = crossings.min(), let upper = crossings.max() else { return nil }
        return lower...upper
    }

    /// True when `point` is inside or on the edge of this (convex) quad.
    func contains(_ point: CGPoint) -> Bool {
        guard let span = span(atY: point.y) else { return false }
        return point.x >= span.lowerBound - 1e-6 && point.x <= span.upperBound + 1e-6
    }

    /// The largest axis-aligned rectangle inside this convex quad, or nil when it has no area.
    ///
    /// For a convex shape the left edge x(y) is convex and the right edge concave, so a rectangle spanning
    /// `top...bottom` is limited only by the spans at its top and bottom rows; only those two rows are searched.
    /// The corners' rows are tried exactly (the answer for the keystone's single-axis trapezoids), then a coarse
    /// grid refined by a shrinking pattern search finds a better pair when the sides are slanted both ways.
    func largestInnerRectangle() -> CGRect? {
        let box = bounds
        guard box.width > 0, box.height > 0 else { return nil }
        let rows = Set(corners.map(\.y)).sorted()
        var exact: (area: CGFloat, rect: CGRect)?
        for (index, top) in rows.enumerated() {
            for bottom in rows[index...] {
                if let found = rectangle(top: top, bottom: bottom), found.area > (exact?.area ?? 0) { exact = found }
            }
        }
        let searched = searchedRectangle(in: box)
        // The search only wins by a clear margin, so the exact rows (whole pixels before) aren't nudged by noise.
        if let searched, searched.area > (exact?.area ?? 0) * (1 + 1e-6) + 1e-6 { return searched.rect }
        return exact?.rect
    }

    private struct Rows {
        var top: CGFloat
        var bottom: CGFloat
        var area: CGFloat
    }

    private func searchedRectangle(in box: CGRect) -> (area: CGFloat, rect: CGRect)? {
        let steps = 48
        let row: (Int) -> CGFloat = { box.minY + box.height * CGFloat($0) / CGFloat(steps) }
        var best: Rows?
        for first in 0...steps {
            for second in first...steps {
                let area = rectangle(top: row(first), bottom: row(second))?.area ?? 0
                if area > (best?.area ?? 0) { best = Rows(top: row(first), bottom: row(second), area: area) }
            }
        }
        guard var current = best else { return nil }
        var step = box.height / CGFloat(steps)
        var rounds = 0
        while step > 0.001, rounds < 4_000 {
            rounds += 1
            let moves = [(step, 0.0), (-step, 0.0), (0.0, step), (0.0, -step), (step, step), (-step, -step),
                         (step, -step), (-step, step)]
            var moved = false
            for (deltaTop, deltaBottom) in moves {
                let top = min(box.maxY, max(box.minY, current.top + deltaTop))
                let bottom = min(box.maxY, max(top, current.bottom + deltaBottom))
                if let area = rectangle(top: top, bottom: bottom)?.area, area > current.area {
                    current = Rows(top: top, bottom: bottom, area: area)
                    moved = true
                    break
                }
            }
            if !moved { step /= 2 }
        }
        return rectangle(top: current.top, bottom: current.bottom)
    }

    /// The widest rectangle from row `top` to row `bottom`, or nil when there is none.
    private func rectangle(top: CGFloat, bottom: CGFloat) -> (area: CGFloat, rect: CGRect)? {
        guard bottom > top, let upper = span(atY: top), let lower = span(atY: bottom) else { return nil }
        let left = max(upper.lowerBound, lower.lowerBound)
        let right = min(upper.upperBound, lower.upperBound)
        guard right > left else { return nil }
        return ((right - left) * (bottom - top), CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }
}

extension Geometry {
    /// Where the source corners go for the manual keystone, or nil when the sliders are at 0.
    static func keystoneQuad(source: CGSize, options: PerspectiveOptions) -> Quad? {
        let vertical = Perspective.effective(options.vertical) / 100
        let horizontal = Perspective.effective(options.horizontal) / 100
        guard vertical != 0 || horizontal != 0 else { return nil }
        let wide = source.width
        let high = source.height
        var quad = Quad(topLeft: .zero, topRight: CGPoint(x: wide, y: 0),
                        bottomRight: CGPoint(x: wide, y: high), bottomLeft: CGPoint(x: 0, y: high))
        let inX = 0.25 * abs(vertical) * wide
        if vertical > 0 {
            quad.topLeft.x += inX
            quad.topRight.x -= inX
        } else {
            quad.bottomLeft.x += inX
            quad.bottomRight.x -= inX
        }
        let inY = 0.25 * abs(horizontal) * high
        if horizontal > 0 {
            quad.topRight.y += inY
            quad.bottomRight.y -= inY
        } else {
            quad.topLeft.y += inY
            quad.bottomLeft.y -= inY
        }
        return quad
    }

    /// The largest axis-aligned rectangle inside the keystoned image, with no empty areas (top-left origin, whole
    /// pixels), or nil when the sliders are at 0. One pixel is kept clear of the antialiased edges.
    public static func perspectiveCrop(source: CGSize, options: PerspectiveOptions) -> CGRect? {
        guard let quad = keystoneQuad(source: source, options: options) else { return nil }
        if options.cropRule == .innerEnds { return innerEndsCrop(quad) }
        guard let inner = quad.largestInnerRectangle() else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let left = (inner.minX + 1).rounded(.up)
        let right = (inner.maxX - 1).rounded(.down)
        let top = (inner.minY + 1).rounded(.up)
        let bottom = (inner.maxY - 1).rounded(.down)
        return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
    }

    /// The crop of the release before the empty-area choices, unchanged: each side at the inner end of its edge
    /// (inside for a quad whose corners only move inwards), one pixel clear, whole pixels.
    static func innerEndsCrop(_ quad: Quad) -> CGRect {
        let left = (max(quad.topLeft.x, quad.bottomLeft.x) + 1).rounded(.up)
        let right = (min(quad.topRight.x, quad.bottomRight.x) - 1).rounded(.down)
        let top = (max(quad.topLeft.y, quad.topRight.y) + 1).rounded(.up)
        let bottom = (min(quad.bottomLeft.y, quad.bottomRight.y) - 1).rounded(.down)
        return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
    }

    /// The part of the keystoned image that is kept (top-left origin, whole pixels): the crop, or for the other
    /// empty-area choices the whole corrected image. Nil when the sliders are at 0.
    static func keystoneBox(source: CGSize, options: PerspectiveOptions) -> CGRect? {
        if options.emptyAreas == .crop { return perspectiveCrop(source: source, options: options) }
        guard let quad = keystoneQuad(source: source, options: options) else { return nil }
        let box = quad.bounds.integral
        return CGRect(x: box.minX, y: box.minY, width: max(1, box.width), height: max(1, box.height))
    }

    /// The size a Perspective step makes from `source`, when it can be known without the image: keep original
    /// size is the source, auto depends on the content (the source as an estimate), else the keystone box.
    public static func perspectiveOutputSize(source: CGSize, options: PerspectiveOptions) -> CGSize {
        if options.size == .keepOriginal || options.auto { return source }
        return keystoneBox(source: source, options: options)?.size ?? source
    }

    /// Where `content` lands when scaled to fit inside `target`: one scale for both axes (the aspect kept exactly),
    /// centred at a whole-pixel origin.
    static func fitPlacement(content: CGSize, target: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: target) }
        let scale = min(target.width / content.width, target.height / content.height)
        let wide = min(target.width, content.width * scale)
        let high = min(target.height, content.height * scale)
        return CGRect(x: ((target.width - wide) / 2).rounded(.down), y: ((target.height - high) / 2).rounded(.down),
                      width: wide, height: high)
    }
}
