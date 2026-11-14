import Foundation

/// One item's place in a running batch, as the list and the thumbnail rings show it.
public enum ItemStage: Equatable, Sendable {
    case queued, decoding, processing, encoding, writing, done, failed, skipped, cancelled

    /// The four states a thumbnail ring can show.
    public enum Ring: Equatable, Sendable {
        case queued, working, done, failed
    }

    public init(_ stage: ItemEvent.Stage) {
        switch stage {
        case .queued: self = .queued
        case .decoding: self = .decoding
        case .processing: self = .processing
        case .encoding: self = .encoding
        case .writing: self = .writing
        case .done: self = .done
        case .failed: self = .failed
        case .skipped: self = .skipped
        case .cancelled: self = .cancelled
        }
    }

    /// On a worker right now.
    public var isWorking: Bool {
        switch self {
        case .decoding, .processing, .encoding, .writing: return true
        default: return false
        }
    }

    /// Skipped by a condition counts as done (nothing went wrong); not run counts as still waiting.
    public var ring: Ring {
        switch self {
        case .queued, .cancelled: return .queued
        case .decoding, .processing, .encoding, .writing: return .working
        case .done, .skipped: return .done
        case .failed: return .failed
        }
    }

    public var title: String {
        switch self {
        case .queued: return "Queued"
        case .decoding: return "Decoding"
        case .processing: return "Processing"
        case .encoding: return "Encoding"
        case .writing: return "Writing"
        case .done: return "Written"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Not run"
        }
    }
}

/// Each item's latest stage in a run, and how many are on a worker. Fed with `ItemEvent`s in the order they
/// arrive (one item's events are ordered); the caller owns the synchronisation.
public struct ItemStageTracker: Sendable {
    private var stages: [URL: ItemStage] = [:]
    public private(set) var workersInUse = 0

    public init() {}

    public mutating func record(_ event: ItemEvent) {
        let next = ItemStage(event.stage)
        let previous = stages.updateValue(next, forKey: event.source)
        workersInUse += (next.isWorking ? 1 : 0) - (previous?.isWorking == true ? 1 : 0)
        workersInUse = max(0, workersInUse)
    }

    public func stage(for source: URL) -> ItemStage? { stages[source] }

    /// After the run: nothing is on a worker any more, and an item still shown as working never finished.
    public mutating func finishRun() {
        for (source, stage) in stages where stage.isWorking { stages[source] = .cancelled }
        workersInUse = 0
    }
}

/// The words of the progress line and the performance panel.
public enum RunStatusText {
    /// "12 / 124 · 3.4 img/s · about 2 min left", or "12 / 124 · paused".
    public static func progress(completed: Int, total: Int, imagesPerSecond: Double, eta: TimeInterval?,
                                paused: Bool) -> String {
        var parts = ["\(completed) / \(total)"]
        if paused {
            parts.append("paused")
        } else {
            if imagesPerSecond > 0 { parts.append(rate(imagesPerSecond, unit: "img/s")) }
            parts.append(self.eta(eta))
        }
        return parts.joined(separator: " · ")
    }

    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "estimating time left" }
        if seconds < 1 { return "almost done" }
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return "about \(minutes / 60) h \(minutes % 60) min left"
    }

    /// "2:05", or "1:02:05" from an hour on.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    public static func rate(_ value: Double, unit: String) -> String {
        String(format: "%.1f \(unit)", value)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }
}
