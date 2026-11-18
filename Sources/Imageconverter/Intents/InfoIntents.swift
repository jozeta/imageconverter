import AppIntents
import Foundation
import ImageconverterCore

struct RunJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Job"
    static let description = IntentDescription(
        "Runs one of your imageconverter jobs now, waits until it has finished and returns a summary.",
        categoryName: "Jobs")
    static let openAppWhenRun = false

    @Parameter(title: "Job")
    var job: JobEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run the job \(\.$job)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let jobs = await IntentContext.jobs()
        let found: Job
        do { found = try ExternalRequests.job(named: job.id, in: jobs) } catch { throw IntentFailure(error) }
        let id = found.id
        switch await MainActor.run(body: { JobsController.shared }).runNowAndWait(id) {
        case .finished(let result):
            return .result(value: Automation.jobSummary(of: result, job: found.name))
        case .quitting:
            throw IntentFailure(AutomationError.quitting)
        case .didNotRun:
            let reason = await MainActor.run { JobsController.shared.job(id)?.disabledReason }
            throw IntentFailure("The job \(found.name) didn't run." + (reason.map { " \($0)" } ?? ""))
        }
    }
}

struct GetImageMetadataIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Image Metadata"
    static let description = IntentDescription(
        "Returns an image's metadata as text: file, camera, location, description, rights and technical fields. Only the header is read.",
        categoryName: "Metadata")
    static let openAppWhenRun = false

    @Parameter(title: "Image", supportedTypeIdentifiers: ["public.image"])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Get the metadata of \(\.$image)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            let scratch = try Automation.newScratchFolder(in: Automation.scratchBase)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let inputs = try IntentInputs([image], copiesIn: scratch)
            defer { inputs.release() }
            guard let url = inputs.urls.first else { throw AutomationError.noFiles }
            return .result(value: try Automation.metadataText(of: url))
        } catch {
            throw IntentFailure(error)
        }
    }
}

extension IntentContext {
    /// The input folder of Apply Preset to Folder: it must be readable (allowed in Folder Access when sandboxed).
    static func checkedInputFolder(_ file: IntentFile) throws -> (URL, FolderAccess.Grant) {
        do {
            return try folder(file) { FileManager.default.isReadableFile(atPath: $0.path) }
        } catch {
            throw IntentFailure(error)
        }
    }
}
