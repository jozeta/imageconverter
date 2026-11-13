/// Admission control for a batch: limits how many items run at once and their combined weight
/// (pixels), so big images do not pile up in memory. One oversized item may always run alone.
public struct WorkWindow {
    public let maxItems: Int
    public let maxWeight: Int
    private var inFlightItems = 0
    private var inFlightWeight = 0

    public init(maxItems: Int, maxWeight: Int) {
        self.maxItems = maxItems
        self.maxWeight = maxWeight
    }

    public func canStart(weight: Int) -> Bool {
        guard inFlightItems < maxItems else { return false }
        if inFlightItems == 0 { return true }
        let (sum, overflow) = inFlightWeight.addingReportingOverflow(weight)
        return !overflow && sum <= maxWeight
    }

    public mutating func start(weight: Int) {
        inFlightItems += 1
        inFlightWeight = inFlightWeight.addingReportingOverflow(weight).overflow
            ? Int.max : inFlightWeight + weight
    }

    public mutating func finish(weight: Int) {
        inFlightItems = max(0, inFlightItems - 1)
        // Weights saturate at Int.max, so recompute-free subtraction is clamped at zero.
        inFlightWeight = inFlightItems == 0 ? 0 : max(0, inFlightWeight - weight)
    }
}
