import CoreGraphics

/// How big the preview's histogram panel is for a stage `stageHeight` points tall: the whole panel takes at most two
/// fifths of the stage. The chart is `chartWidth` wide (the chips row's width) and its height scales between
/// `minChartHeight` and `maxChartHeight`; below `compactBelow` the Original/Result picker gives way to a small label
/// in the chart (`compact`).
public struct HistogramLayout: Equatable, Sendable {
    public static let chartWidth: CGFloat = 240
    public static let maxChartHeight: CGFloat = 120
    public static let minChartHeight: CGFloat = 48
    public static let compactBelow: CGFloat = 300
    /// The share of the stage the panel may cover.
    static let share: CGFloat = 0.4
    /// The panel's padding (top and bottom), the chips row and the picker row, each with its spacing.
    static let padding: CGFloat = 16
    static let chipRow: CGFloat = 24
    static let pickerRow: CGFloat = 26

    public let chartSize: CGSize
    public let compact: Bool

    /// 0 (not measured yet) gives the full-size panel.
    public init(stageHeight: CGFloat) {
        guard stageHeight > 0 else {
            self.init(chartHeight: Self.maxChartHeight, compact: false)
            return
        }
        let compact = stageHeight < Self.compactBelow
        let chrome = Self.padding + Self.chipRow + (compact ? 0 : Self.pickerRow)
        let height = (stageHeight * Self.share - chrome).rounded(.down)
        self.init(chartHeight: min(max(height, Self.minChartHeight), Self.maxChartHeight), compact: compact)
    }

    private init(chartHeight: CGFloat, compact: Bool) {
        chartSize = CGSize(width: Self.chartWidth, height: chartHeight)
        self.compact = compact
    }

    /// The panel's height with this chart, as laid out by the app.
    public var panelHeight: CGFloat {
        chartSize.height + Self.padding + Self.chipRow + (compact ? 0 : Self.pickerRow)
    }
}
