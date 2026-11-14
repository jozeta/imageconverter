import Foundation
import ImageconverterCore

/// What the command line asked for.
public enum CLICommand: Equatable {
    case help
    case version
    case convert(ConvertOptions)
    case presetsList(json: Bool)
    case jobsList(json: Bool)
    case jobsRun(name: String, quiet: Bool, json: Bool)
}

public struct ConvertOptions: Equatable {
    public var inputs: [String] = []
    public var preset: String?
    public var pipelineFile: String?
    public var outputDirectory: String?
    public var sameFolder = false
    public var suffix: String?
    public var overwrite = false
    public var confirmed = false
    public var format: OutputFormat?
    /// 0...1
    public var quality: Double?
    public var maxSizeBytes: Int?
    public var resizeLongEdge: Int?
    public var stripGPS = false
    public var stripAll = false
    public var report: ReportFormat?
    public var dryRun = false
    public var quiet = false
    public var json = false

    public init() {}
}

/// A mistake in the arguments; the tool prints it with a hint and exits with code 2.
public struct CLIUsageError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Exit codes of the tool.
public enum CLIExit {
    public static let success: Int32 = 0
    public static let someFailed: Int32 = 1
    public static let usage: Int32 = 2
    public static let nothingToDo: Int32 = 3
    /// 128 + SIGINT, after a Ctrl-C.
    public static let interrupted: Int32 = 130
}
