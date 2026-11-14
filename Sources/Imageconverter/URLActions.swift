import Foundation
import ImageconverterCore

/// `imageconverter://` links. Any web page can open one, so `URLAction.parse` rejects anything unknown, every
/// action except `open` waits for the user to confirm a sheet that says what will happen, only one link
/// confirmation is open at a time (links arriving meanwhile are dropped and counted), and nothing a link
/// says is echoed back in a message.
extension ExternalActions {
    func handle(_ url: URL) {
        guard !linkPending else {
            droppedLinks += 1
            return
        }
        guard let action = URLAction.parse(url) else {
            let hint = Sandbox.isEnforced ? " " + ExternalRequestError.sandboxHint : ""
            reportProblem(title: "Ignored a link", message: "An imageconverter link was malformed, too long, used an "
                          + "unknown action or named a file that can't be read." + hint)
            return
        }
        guard action.needsConfirmation else { return showWindow() }
        linkPending = true
        withModel { model, _ in
            Task {
                await self.perform(action, model: model)
                self.linkFinished(model: model)
            }
        }
    }

    private func linkFinished(model: AppModel) {
        linkPending = false
        guard droppedLinks > 0 else { return }
        let count = droppedLinks
        droppedLinks = 0
        model.toasts.show("Ignored \(count) more \(count == 1 ? "link" : "links")", type: .info,
                          description: "They arrived while another link was waiting for your answer.")
    }

    private func perform(_ action: URLAction, model: AppModel) async {
        switch action {
        case .open:
            showWindow()
        case .selectPreset(let name):
            await selectPreset(named: name, model: model)
        case .addFiles(let urls):
            let count = urls.count
            guard await confirm(
                title: "Add \(count) \(count == 1 ? "item" : "items") from a link?",
                message: "A link asks to add these files and folders to the batch. Nothing is converted.\n\n"
                    + ExternalRequests.fileList(urls),
                confirm: "Add") else { return }
            add(urls)
        case .runJob(let name):
            await runJob(named: name, model: model)
        }
    }

    private func selectPreset(named name: String, model: AppModel) async {
        guard !model.isRunning else { return reportProblem(ExternalRequestError.busy, title: "Couldn't switch presets") }
        guard let preset = try? ExternalRequests.preset(named: name, in: model.allPresets) else {
            return reportProblem(title: "Couldn't switch presets", message: "A link asked for a preset that doesn't exist.")
        }
        let discards = model.session.isModified
        let unsaved = discards ? " Your unsaved changes to \(model.session.selected?.name ?? "the preset") are discarded." : ""
        guard await confirm(title: "Switch to the preset \(preset.name)?",
                            message: "A link asks to select this preset. Nothing is converted." + unsaved,
                            confirm: "Switch", destructive: discards) else { return }
        _ = model.selectPreset(preset.id, force: true)
    }

    private func runJob(named name: String, model: AppModel) async {
        guard let job = try? ExternalRequests.job(named: name, in: jobStore.load().jobs) else {
            return reportProblem(title: "Couldn't run the job", message: "A link asked for a job that doesn't exist.")
        }
        let pipeline = job.presetID.map { id in
            model.allPresets.first { $0.id == id }.map { "the preset \($0.name)" } ?? "a preset that no longer exists"
        } ?? "the job's own pipeline"
        let folders = job.inputs.isEmpty ? "It has no input folders, so nothing is converted."
            : "It converts the new or changed images in these folders with \(pipeline) and "
                + ExternalRequests.describe(job.output) + ":\n\n" + ExternalRequests.fileList(job.inputs)
        let overwrite = job.output.kind == .overwrite && !job.inputs.isEmpty
        guard await confirm(
            title: "Run the job \(job.name)?",
            message: "A link asks to run this job now. " + folders,
            confirm: overwrite ? "Run and Replace Originals" : "Run Job", destructive: overwrite) else { return }
        // Through the Jobs controller: one run per job at a time (a link during a run becomes its follow-up).
        let jobs = JobsController.shared
        jobs.start()
        let waits = jobs.hasActiveRuns
        model.toasts.show(waits ? "The job \(job.name) runs once the current job run has finished"
                                : "Running the job \(job.name)…", type: .info)
        jobs.runNow(job.id)
    }
}
