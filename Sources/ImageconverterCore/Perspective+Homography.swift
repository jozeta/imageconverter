import CoreGraphics
import Foundation

// Single letters and corner indices follow Heckbert's notation for the mapping.
// swiftlint:disable identifier_name

/// The projective map from the unit square (u, v in 0...1, top-left origin) onto a quad: Heckbert's closed form
/// (TL = (0, 0), TR = (1, 0), BR = (1, 1), BL = (0, 1)), with its inverse from the adjugate.
struct Homography {
    private let a, b, c, d, e, f, g, h: CGFloat

    init?(_ quad: Quad) {
        let (x0, y0, x1, y1) = (quad.topLeft.x, quad.topLeft.y, quad.topRight.x, quad.topRight.y)
        let (x2, y2, x3, y3) = (quad.bottomRight.x, quad.bottomRight.y, quad.bottomLeft.x, quad.bottomLeft.y)
        let sumX = x0 - x1 + x2 - x3
        let sumY = y0 - y1 + y2 - y3
        var g: CGFloat = 0
        var h: CGFloat = 0
        if abs(sumX) > 1e-12 || abs(sumY) > 1e-12 {
            let (dx1, dx2, dy1, dy2) = (x1 - x2, x3 - x2, y1 - y2, y3 - y2)
            let den = dx1 * dy2 - dx2 * dy1
            guard abs(den) > 1e-12 else { return nil }
            g = (sumX * dy2 - dx2 * sumY) / den
            h = (dx1 * sumY - sumX * dy1) / den
        }
        (self.g, self.h) = (g, h)
        (a, b, c) = (x1 - x0 + g * x1, x3 - x0 + h * x3, x0)
        (d, e, f) = (y1 - y0 + g * y1, y3 - y0 + h * y3, y0)
    }

    /// The forward map's denominator at (u, v): where it reaches 0 the square's plane maps to infinity.
    /// Positive inside the square for a convex quad.
    func weight(_ unit: CGPoint) -> CGFloat { g * unit.x + h * unit.y + 1 }

    /// Where the unit-square point `unit` lands.
    func point(for unit: CGPoint) -> CGPoint {
        let weight = weight(unit)
        return CGPoint(x: (a * unit.x + b * unit.y + c) / weight, y: (d * unit.x + e * unit.y + f) / weight)
    }

    /// The unit-square point that maps onto `point`, or nil when `point` lies beyond the map's horizon (no point
    /// of the square's plane in front of it lands there).
    func unit(for point: CGPoint) -> CGPoint? {
        // Adjugate of [[a b c] [d e f] [g h 1]]; its last row's sign tells the two sides of the horizon apart.
        let lastRow: (CGPoint) -> CGFloat = { [self] in
            (d * h - e * g) * $0.x + (b * g - a * h) * $0.y + (a * e - b * d)
        }
        let weight = lastRow(point)
        let inside = lastRow(self.point(for: CGPoint(x: 0.5, y: 0.5)))
        guard abs(weight) > 1e-12, (weight > 0) == (inside > 0) else { return nil }
        let unitX = ((e - f * h) * point.x + (c * h - b) * point.y + (b * f - c * e)) / weight
        let unitY = ((f * g - d) * point.x + (a - c * g) * point.y + (c * d - a * f)) / weight
        return CGPoint(x: unitX, y: unitY)
    }
}

// swiftlint:enable identifier_name
