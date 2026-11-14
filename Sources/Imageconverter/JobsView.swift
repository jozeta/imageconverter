import AppKit
import SwiftUI
import ImageconverterCore

/// The Jobs window (Window ▸ Jobs, ⌘J): saved jobs with their trigger, folders, last run and status, and the
/// actions on the selected one.
struct JobsView: View {
    static let windowID = "jobs"
    @Bindable var controller: JobsController
    let model: AppModel
    let settings: AppSettings
    @State private var selection: UUID?
    @State private var editing: JobDraft?
    @State private var confirmingDelete: Job?
    @State private var confirmingReset: Job?
    @State private var actionFailure: String?
    @Environment(\.openWindow) private var openWindow

    private var selected: Job? { selection.flatMap(controller.job) }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            header
            table
            actions
            Divider()
            footer
        }
        .padding(LadaGlass.Spacing.l)
        .frame(minWidth: 720, minHeight: 360)
        .lgBackdrop()
        .lgCompact()
        .sheet(item: $editing) { draft in
            JobEditor(draft: draft, presets: model.allPresets, currentPipeline: model.pipeline) { job in
                try controller.save(job, base: draft.isNew ? nil : draft.original)
                selection = job.id
            }
        }
        .confirmationDialog("Delete the job \(confirmingDelete?.name ?? "")?",
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            presenting: confirmingDelete) { job in
            Button("Delete Job", role: .destructive) { perform { try controller.delete(job.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its folders and the images in them are not touched. The list of processed files is deleted.")
        }
        .confirmationDialog("Process all files of \(confirmingReset?.name ?? "") again?",
                            isPresented: Binding(get: { confirmingReset != nil }, set: { if !$0 { confirmingReset = nil } }),
                            presenting: confirmingReset) { job in
            Button(job.output.kind == .overwrite ? "Forget and Re-encode Originals" : "Forget Processed Files",
                   role: job.output.kind == .overwrite ? .destructive : nil) {
                perform { try controller.resetProcessed(job.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text(Self.resetMessage(job))
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionFailure ?? "")
        }
        .onAppear { controller.start() }
        #if DEBUG
        .task { await openDebugEditor() }
        #endif
    }

    private var header: some View {
        HStack {
            Text("Jobs").font(LadaGlass.Typography.title)
            if controller.pausedAll { LGChip("All paused", status: .warn) }
            Spacer()
            Button("New Job from Current Pipeline") {
                editing = JobDraft(model.newJobDraft(settings: settings, existingNames: controller.jobs.map(\.name)),
                                   isNew: true)
            }
            .buttonStyle(.lg(.primary))
            .accessibilityLabel("New job from the current pipeline")
        }
    }

    // MARK: Table

    private var table: some View {
        Table(controller.jobs, selection: $selection) {
            TableColumn("Name") { job in
                Text(job.name).fontWeight(.medium)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Trigger") { job in Text(Self.triggerText(job.trigger)) }
                .width(min: 90, ideal: 120)
            TableColumn("Inputs") { job in
                Text(job.inputs.map(\.lastPathComponent).joined(separator: ", "))
                    .lineLimit(1).truncationMode(.tail)
                    .help(job.inputs.map(\.path).joined(separator: "\n"))
            }
            .width(min: 100, ideal: 160)
            TableColumn("Last run") { job in
                Text(Self.lastRunText(controller.status(of: job.id)))
                    .foregroundStyle(LadaGlass.Colors.muted)
            }
            .width(min: 120, ideal: 190)
            TableColumn("Status") { job in statusChip(job) }
                .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let job = controller.job(id) {
                Button("Edit…") { edit(job) }
                Button("Run Now") { controller.runNow(id) }
                Button(job.isEnabled ? "Switch Off" : "Switch On") { controller.setEnabled(id, !job.isEnabled) }
                Divider()
                Button("Process All Files Again…") { confirmingReset = job }
                Button("Delete…") { confirmingDelete = job }
                    .disabled(controller.status(of: id).isRunning)
            }
        } primaryAction: { ids in
            if let id = ids.first, let job = controller.job(id) { edit(job) }
        }
        .overlay {
            if controller.jobs.isEmpty {
                Text("No jobs yet. Set up the pipeline in the main window, then choose New Job from Current Pipeline.")
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .multilineTextAlignment(.center)
                    .padding(LadaGlass.Spacing.xl)
            }
        }
        .accessibilityLabel("Jobs")
    }

    @ViewBuilder private func statusChip(_ job: Job) -> some View {
        let status = controller.status(of: job.id)
        let (text, kind) = Self.statusText(job, status: status, paused: controller.pausedAll)
        LGChip(text, status: kind)
            .help(status.problem ?? job.disabledReason ?? text)
            .accessibilityLabel("Status: \(text)")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            Button("Edit…") { selected.map(edit) }
                .disabled(selected == nil)
            Button("Run Now") { selection.map(controller.runNow) }
                .disabled(selected == nil)
            Button("Open Last Report") { open(selection.flatMap { controller.status(of: $0).lastReport }) }
                .disabled(selection.flatMap { controller.status(of: $0).lastReport } == nil)
            Button("History…") {
                HistoryController.shared.jobFilter = selected?.name
                openWindow(id: HistoryView.windowID)
            }
            .disabled(selected == nil)
            .accessibilityLabel("Show the history of the selected job")
            Button("Reveal Output") { reveal(selected.flatMap(JobsController.outputFolder)) }
                .disabled(selected.flatMap(JobsController.outputFolder) == nil)
            Spacer()
            Button("Delete…") { confirmingDelete = selected }
                .disabled(selected == nil || selection.map { controller.status(of: $0).isRunning } == true)
                .accessibilityLabel("Delete the selected job")
        }
        .buttonStyle(.lg(.secondary))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.l) {
                Toggle("Pause all jobs", isOn: $controller.pausedAll)
                    .accessibilityLabel("Pause all jobs")
                Toggle("Keep running in the menu bar when the window is closed", isOn: $controller.keepInMenuBar)
                    .accessibilityLabel("Keep running in the menu bar when the window is closed")
            }
            Text("Watched folders and schedules run while the app is open. Job runs use half the processor "
                + "cores at low priority, so the main window stays fast.")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            if !controller.skipped.isEmpty {
                Text("Skipped \(controller.skipped.count) job file(s): "
                    + controller.skipped.map { "\($0.file): \($0.reason)" }.joined(separator: "; "))
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
            }
        }
    }

    private func edit(_ job: Job) { editing = JobDraft(job, isNew: false) }

    #if DEBUG
    /// Screenshot aid: `-debugEditJob <name>` opens that job's editor once the window is up.
    private func openDebugEditor() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-debugEditJob"), index + 1 < arguments.count else { return }
        try? await Task.sleep(for: .seconds(1))
        controller.start()
        guard let job = controller.jobs.first(where: { $0.name == arguments[index + 1] }) else { return }
        selection = job.id
        edit(job)
    }
    #endif

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { actionFailure = AppModel.message(error) }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        if !NSWorkspace.shared.open(url) { actionFailure = "The report \(url.lastPathComponent) couldn't be opened." }
    }

    private func reveal(_ folder: URL?) {
        guard let folder else { return }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            actionFailure = "The folder \(folder.lastPathComponent) doesn't exist yet. It is created by the first run."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: - Text

extension JobsView {
    static func triggerText(_ trigger: JobTrigger) -> String {
        switch trigger {
        case .manual: return "Manual"
        case .watch: return "Watch folder"
        case .schedule(let every): return "Every " + intervalText(every)
        }
    }

    static func intervalText(_ seconds: TimeInterval) -> String {
        if seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        return "\(Int(seconds / 60)) min"
    }

    static func lastRunText(_ status: JobStatus) -> String {
        guard let summary = status.lastSummary else {
            return status.lastChecked.map { "Checked \(relative($0)), nothing new" } ?? "Never"
        }
        var parts = ["\(summary.succeeded) converted"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return "\(relative(summary.finishedAt)) · " + parts.joined(separator: ", ")
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func statusText(_ job: Job, status: JobStatus, paused: Bool) -> (String, LGChip.Status) {
        if status.isRunning {
            if let progress = status.progress, progress.total > 0 {
                return ("Running \(progress.completed + progress.failed)/\(progress.total)", .ok)
            }
            return ("Running", .ok)
        }
        if status.isQueued { return ("Waiting", .neutral) }
        if !job.isEnabled {
            return job.disabledReason == nil ? ("Off", .neutral) : ("Off: folder missing", .bad)
        }
        if status.problem != nil { return ("Problem", .bad) }
        if paused, job.trigger != .manual { return ("Paused", .warn) }
        switch job.trigger {
        case .manual: return ("Ready", .neutral)
        case .watch: return ("Watching", .ok)
        case .schedule: return ("Scheduled", .ok)
        }
    }

    /// "Resize 2048 px · Metadata · AVIF 85 %" for the editor and the menu bar.
    static func pipelineSummary(_ pipeline: Pipeline) -> String {
        var parts = pipeline.steps.filter(\.isEnabled).map { $0.operation.summary }
        if pipeline.metadata.isIncluded && pipeline.metadata.isEnabled { parts.append(pipeline.metadata.summary) }
        if pipeline.rename.isIncluded && pipeline.rename.isEnabled { parts.append("Rename \(pipeline.rename.pattern)") }
        let output = pipeline.output
        let quality = output.format.supportsQuality ? " \(Int((output.clampedQuality * 100).rounded())) %" : ""
        parts.append(output.format.displayName + quality)
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Names the job and its folders, and what the next run will do.
    static func resetMessage(_ job: Job) -> String {
        let folders = job.inputs.map { "\u{2022} " + $0.path }.joined(separator: "\n")
        let effect = job.output.kind == .overwrite
            ? "The next run converts every image in these folders again and replaces the originals once more."
            : "The next run converts every image in these folders again; existing results get new names (_2, _3, …)."
        return "The job forgets which files it has processed.\n\n\(folders)\n\n\(effect)"
    }
}
