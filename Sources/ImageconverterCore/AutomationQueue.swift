import Foundation

/// Runs the Shortcuts actions' batches one at a time, in the order they arrived (B2). Each action's batch already
/// uses half the cores and half the memory budget (`BatchResourceLimits.background`); a folder automation firing
/// once per file would otherwise run many of them side by side and overcommit the process. Once quitting
/// (`stop`), waiting actions and new ones are refused with `AutomationError.quitting` (C4).
public actor AutomationQueue {
    private var isBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    public private(set) var isStopping = false

    public init() {}

    /// How many actions are waiting for their turn (for tests).
    public var waitingCount: Int { waiters.count }
    /// Whether an action is running now (for tests).
    public var isRunning: Bool { isBusy }

    /// Waits for this action's turn, then runs `work`. Cancelling the caller while it waits takes it out of the
    /// queue (`CancellationError`).
    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        if isStopping { throw AutomationError.quitting }
        return try await work()
    }

    /// Quitting: every waiting action is refused, and so is every later one. The running one is cancelled by its
    /// owner (`AutomationRuns.cancelAll`).
    public func stop() {
        isStopping = true
        let refused = waiters
        waiters = []
        refused.forEach { $0.continuation.resume(throwing: AutomationError.quitting) }
    }

    private func acquire() async throws {
        if isStopping { throw AutomationError.quitting }
        if !isBusy {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the turn to the next action (it stays busy), or frees it.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
