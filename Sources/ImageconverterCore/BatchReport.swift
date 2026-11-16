import Foundation

/// How far a batch has got. `completed` counts successes, failures and files skipped by a condition.
public struct BatchProgress: Equatable, Sendable {
    public let completed: Int
    public let failed: Int
    public let total: Int

    public init(completed: Int, failed: Int, total: Int) {
        self.completed = completed
        self.failed = failed
        self.total = total
    }
}

/// A file that was skipped, and why.
public struct BatchFailure: Equatable, Sendable {
    public let source: URL
    public let reason: String
    /// Size of the source file, read on the worker before it was touched; nil if it couldn't be read.
    public let inputBytes: Int?
    /// Seconds the worker spent on the file (0 when unknown); set by the runner after the fact.
    public var duration: Double = 0
    /// It failed only because the enlargement model isn't downloaded yet: a job doesn't count it as an attempt.
    public var awaitsModelDownload = false

    public init(source: URL, reason: String, inputBytes: Int? = nil) {
        self.source = source
        self.reason = reason
        self.inputBytes = inputBytes
    }
}

/// A file a condition left alone: nothing was written for it, and it isn't a failure.
public struct BatchSkip: Equatable, Sendable {
    public let source: URL
    public let reason: String
    public let inputBytes: Int?

    public init(source: URL, reason: String = ConditionalStep.skippedReason, inputBytes: Int? = nil) {
        self.source = source
        self.reason = reason
        self.inputBytes = inputBytes
    }
}

/// Something worth telling about a file that was written (e.g. a target size it couldn't reach).
public struct BatchNote: Equatable, Sendable {
    public let source: URL
    public let text: String

    public init(source: URL, text: String) {
        self.source = source
        self.text = text
    }
}

/// One written file with its byte counts.
public struct BatchResultEntry: Equatable, Sendable {
    public let source: URL
    public let destination: URL
    /// Nil when the source size couldn't be read.
    public let inputBytes: Int?
    public let outputBytes: Int
    public let note: String?
    /// The extra output's label; nil for the primary output.
    public var variant: String?
    /// Seconds the worker spent on the file, and the pixel sizes read before and after (set by the runner).
    public var duration: Double = 0
    public var inputWidth: Int?
    public var inputHeight: Int?
    public var outputWidth: Int?
    public var outputHeight: Int?
    /// The note needs attention (see `ReportEntry.warning`).
    public var warning = false

    public init(source: URL, destination: URL, inputBytes: Int?, outputBytes: Int, note: String? = nil) {
        self.source = source
        self.destination = destination
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.note = note
    }
}

/// An extra output that wasn't written although its image was (couldn't be encoded, saved or named).
public struct BatchExtraFailure: Equatable, Sendable {
    public let source: URL
    /// The output's label.
    public let name: String
    /// Where it was planned to go; nil when it found no free name.
    public let destination: URL?
    public let reason: String

    public init(source: URL, name: String, destination: URL?, reason: String) {
        self.source = source
        self.name = name
        self.destination = destination
        self.reason = reason
    }

    /// "Extra output “Thumbnail” failed: …", as the report, the error log and the item's note say it.
    public var message: String { BatchRunner.variantFailedNote(name, reason: reason) }
}

/// The outcome of a batch: all lists are in input order. A note is not a failure; its file was written.
public struct BatchReport: Equatable, Sendable {
    public var written: [URL]
    public var failures: [BatchFailure]
    public var notes: [BatchNote]
    public var cancelled: Bool
    /// One entry per written file (same order as `written`): each item's primary output, then its extra outputs.
    public var entries: [BatchResultEntry]

    /// Every processed file's source, written, failed or skipped, in input order (so reports can interleave them).
    public var order: [URL] = []
    /// Files a condition skipped (in input order); always listed, even when the run was cancelled.
    public var skipped: [BatchSkip] = []
    /// Extra outputs that weren't written for images that were (in input order). Their images count as converted;
    /// a job doesn't try them again.
    public var extraFailures: [BatchExtraFailure] = []

    /// Source bytes of the converted images whose size is known (files with an unknown size are left out of both
    /// totals); each source counts once, however many outputs it has.
    public var inputBytes: Int { entries.filter { $0.variant == nil }.reduce(0) { $0 + ($1.inputBytes ?? 0) } }
    /// Output bytes of every file written from them (extra outputs included).
    public var outputBytes: Int { entries.filter { $0.inputBytes != nil }.reduce(0) { $0 + $1.outputBytes } }
    /// Output bytes of the primary outputs only, for the "saved" phrase (an extra output isn't a saving or a loss).
    public var primaryOutputBytes: Int {
        entries.filter { $0.variant == nil && $0.inputBytes != nil }.reduce(0) { $0 + $1.outputBytes }
    }
    /// Images converted (each source once; `written` also holds the extra outputs).
    public var convertedCount: Int { entries.filter { $0.variant == nil }.count }

    public init(written: [URL] = [], failures: [BatchFailure] = [], notes: [BatchNote] = [], cancelled: Bool = false,
                entries: [BatchResultEntry] = []) {
        self.written = written
        self.failures = failures
        self.notes = notes
        self.cancelled = cancelled
        self.entries = entries
    }
}
