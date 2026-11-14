import Foundation
import ImageconverterCore

/// `imageconverter://` links. Any web page can open one, so `URLAction.parse` rejects anything unknown and
/// every action except `open` waits for the user to confirm a sheet that says what will happen.
extension ExternalActions {
    func handle(_ url: URL) {
        guard let action = URLAction.parse(url) else {
            // Not echoed back: the link's text is untrusted and could be crafted to mislead.
            reportProblem(LinkError.rejected, title: "Ignored a link")
            return
        }
        withModel { model, _ in
            Task { await self.perform(action, model: model) }
        }
    }

    private func perform(_ action: URLAction, model: AppModel) async {
        switch action {
        case .open:
            showWindow()
        case .selectPreset(let name):
            await selectPreset(named: name, model: model)
        case .addFiles(let urls):
            let count = urls.count
            let shown = urls.prefix(5).map(\.path).joined(separator: "\n")
            let more = count > 5 ? "\n…and \(count - 5) more" : ""
            guard await confirm(
                title: "Add \(count) \(count == 1 ? "item" : "items") from a link?",
                message: "A link asks to add these files and folders to the batch. Nothing is converted.\n\n"
                    + shown + more,
                confirm: "Add") else { return }
            add(urls)
        case .runJob(let name):
            await runJob(named: name, model: model)
        }
    }

    private func selectPreset(named name: String, model: AppModel) async {
        guard !model.isRunning else { return reportProblem(ExternalRequestError.busy, title: "Couldn't switch presets") }
        let preset: Preset
        do { preset = try ExternalRequests.preset(named: name, in: model.allPresets) } catch {
            return reportProblem(error, title: "Couldn't switch presets")
        }
        let discards = model.session.isModified
        let unsaved = discards ? " Your unsaved changes to \(model.session.selected?.name ?? "the preset") are discarded." : ""
        guard await confirm(title: "Switch to the preset \(preset.name)?",
                            message: "A link asks to select this preset. Nothing is converted." + unsaved,
                            confirm: "Switch", destructive: discards) else { return }
        _ = model.selectPreset(preset.id, force: true)
    }

    private func runJob(named name: String, model: AppModel) async {
        let job: Job
        do { job = try ExternalRequests.job(named: name, in: jobStore.load().jobs) } catch {
            return reportProblem(error, title: "Couldn't run the job")
        }
        let folders = job.inputs.map(\.path).joined(separator: "\n")
        let overwrite = job.output.kind == .overwrite
        guard await confirm(
            title: "Run the job \(job.name)?",
            message: "A link asks to run this job now. It converts the new or changed images in:\n\(folders)\n\n"
                + "and " + ExternalRequests.describe(job.output) + ".",
            confirm: overwrite ? "Run and Replace Originals" : "Run Job", destructive: overwrite) else { return }
        if !model.startJobRun(job, store: jobStore) {
            reportProblem(ExternalRequestError.busy, title: "Couldn't run the job")
        }
    }
}

private enum LinkError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "An imageconverter link was malformed, too long, used an unknown action or named a file that can't be read."
    }
}
