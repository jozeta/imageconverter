import SwiftUI

/// 8 pt grey squares drawn behind images so transparent pixels are visible. The two greys follow the
/// colour scheme; `phase` shifts the pattern so it moves with a panned image.
struct Checkerboard: View {
    var phase: CGPoint = .zero
    @Environment(\.colorScheme) private var colorScheme
    static let square: CGFloat = 8

    var body: some View {
        let colors = colorScheme == .dark
            ? (Color(white: 0.20), Color(white: 0.28))
            : (Color(white: 0.86), Color(white: 0.97))
        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.0))
            let side = Self.square
            // Start one square before the edge so a phase shift never leaves a gap.
            let startX = Self.offset(phase.x)
            let startY = Self.offset(phase.y)
            var path = Path()
            var row = 0
            var top = startY
            while top < size.height {
                var column = 0
                var left = startX
                while left < size.width {
                    if (row + column).isMultiple(of: 2) { path.addRect(CGRect(x: left, y: top, width: side, height: side)) }
                    left += side
                    column += 1
                }
                top += side
                row += 1
            }
            context.fill(path, with: .color(colors.1))
        }
        .accessibilityHidden(true)
    }

    /// The first square's start (≤ 0) for a pattern shifted by `phase`; two squares make one period.
    private static func offset(_ phase: CGFloat) -> CGFloat {
        let period = 2 * square
        let shift = phase.truncatingRemainder(dividingBy: period)
        return (shift > 0 ? shift - period : shift)
    }
}
