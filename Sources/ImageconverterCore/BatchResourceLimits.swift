import Foundation

/// How many images a batch works on at once and its memory budget. Background work (jobs and Shortcuts actions)
/// uses `background`, so a manual batch beside it keeps its share.
public struct BatchResourceLimits: Equatable, Sendable {
    public var concurrency: Int
    public var memoryBudgetPixels: Int

    public init(concurrency: Int, memoryBudgetPixels: Int) {
        self.concurrency = max(1, concurrency)
        self.memoryBudgetPixels = max(1, memoryBudgetPixels)
    }

    /// Half the cores and half the default budget: jobs and Shortcuts actions.
    public static var background: BatchResourceLimits {
        BatchResourceLimits(concurrency: ProcessInfo.processInfo.activeProcessorCount / 2,
                            memoryBudgetPixels: BatchRunner.defaultMemoryBudgetPixels / 2)
    }
}
