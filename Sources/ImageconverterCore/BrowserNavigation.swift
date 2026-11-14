import CoreGraphics

/// Keyboard movement in the batch browser's grid.
public enum BrowserNavigation {
    public enum Direction: Sendable { case left, right, above, below }

    /// How many cells of `cell` points with `spacing` between them fit in `width`; at least one.
    public static func columns(width: CGFloat, cell: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, cell > 0, width >= cell else { return 1 }
        return max(1, Int((width + spacing) / (cell + spacing)))
    }

    /// The index an arrow key selects from `index` in a grid of `columns` filled row by row. Left and right
    /// walk the order; up and down move a row and stop at the edges (down to a short last row lands on the
    /// last item). Nil when there are no items.
    public static func move(from index: Int, direction: Direction, columns: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let current = min(max(index, 0), count - 1)
        let columns = max(columns, 1)
        switch direction {
        case .left: return max(current - 1, 0)
        case .right: return min(current + 1, count - 1)
        case .above: return current - columns >= 0 ? current - columns : current
        case .below:
            let lastRow = (count - 1) / columns
            guard current / columns < lastRow else { return current }
            return min(current + columns, count - 1)
        }
    }
}

/// Texts for the comparison views.
public enum CompareText {
    /// The amplification `ImageDifference.render` is called with by the preview.
    public static let amplify = 4

    public static func differenceSummary(_ stats: ImageDifference.Stats) -> String {
        guard stats.psnr.isFinite else { return "Identical: no pixel changed" }
        let psnr = String(format: "%.1f", stats.psnr)
        let mean = String(format: "%.2f", stats.meanAbsError)
        return "PSNR \(psnr) dB · mean error \(mean) · max \(stats.maxError) (shown ×\(amplify))"
    }

    /// "−75 %" against the original's size; nil when the original's size is unknown.
    public static func saving(original: Int?, output: Int) -> String? {
        guard let original else { return nil }
        return SizeFormat.percentChange(from: original, to: output)
    }
}
