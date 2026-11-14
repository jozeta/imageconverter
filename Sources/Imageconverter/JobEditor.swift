import AppKit
import SwiftUI
import ImageconverterCore

/// A job being edited: the job plus the controls' own state (schedule number and unit, Save to fields).
struct JobDraft: Identifiable {
    enum Trigger: String, CaseIterable { case manual, watch, schedule }
    enum Unit: String, CaseIterable { case minutes, hours }

    var job: Job
    let isNew: Bool
    var trigger: Trigger
    var every: Int
    var unit: Unit
    var outputKind: OutputModeKind
    var outputFolder: URL?
    var suffix: String

    var id: UUID { job.id }

    init(_ job: Job, isNew: Bool) {
        self.job = job
        self.isNew = isNew
        var interval = JobSchedule.minimumInterval * 3
        switch job.trigger {
        case .manual: trigger = .manual
        case .watch: trigger = .watch
        case .schedule(let seconds):
            trigger = .schedule
            interval = seconds
        }
        let hours = interval.truncatingRemainder(dividingBy: 3600) == 0
        unit = hours ? .hours : .minutes
        every = max(1, Int(interval / (hours ? 3600 : 60)))
        outputKind = job.output.kind
        switch job.output {
        case .newFolder(let url): outputFolder = url; suffix = OutputPlanner.defaultSuffix
        case .sameFolder(let text): suffix = text
        case .overwrite: suffix = OutputPlanner.defaultSuffix
        }
    }

    var interval: TimeInterval { TimeInterval(every) * (unit == .hours ? 3600 : 60) }

    /// Why the draft can't be saved yet; nil when it can.
    var problem: String? {
        if job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the job a name." }
        if job.inputs.isEmpty { return "Add at least one input folder." }
        if outputKind == .newFolder, outputFolder == nil { return "Choose the output folder." }
        if trigger == .schedule, interval < JobSchedule.minimumInterval { return "Run at most every 5 minutes." }
        if trigger == .schedule, interval > JobSchedule.maximumInterval { return "Run at least every 30 days." }
        return nil
    }

    /// The job to save (call only when `problem` is nil).
    var result: Job {
        var job = self.job
        switch trigger {
        case .manual: job.trigger = .manual
        case .watch: job.trigger = .watch
        case .schedule: job.trigger = .schedule(every: interval)
        }
        switch outputKind {
        case .newFolder: job.output = .newFolder(outputFolder ?? URL(fileURLWithPath: "/"))
        case .sameFolder: job.output = .sameFolder(suffix: suffix)
        case .overwrite: job.output = .overwrite
        }
        return job
    }
}

/// The New / Edit job sheet.
struct JobEditor: View {
    @State var draft: JobDraft
    let presets: [Preset]
    /// The main window's pipeline, for "Use current pipeline".
    let currentPipeline: Pipeline
    let onSave: (Job) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text(draft.isNew ? "New job" : "Edit job").font(LadaGlass.Typography.title)
            ScrollView {
                Form {
                    TextField("Name", text: $draft.job.name)
                        .accessibilityLabel("Job name")
                    pipelineSection
                    inputsSection
                    Section("Output") {
                        SaveToControl(kind: $draft.outputKind, folder: $draft.outputFolder, suffix: $draft.suffix,
                                      overwriteNote: "Converted images replace the originals.")
                    }
                    triggerSection
                    Section("Report and status") {
                        Picker("Report", selection: $draft.job.report) {
                            Text("None").tag(ReportFormat?.none)
                            ForEach(ReportFormat.allCases, id: \.self) { Text(Self.title(of: $0)).tag(ReportFormat?.some($0)) }
                        }
                        .accessibilityLabel("Report file format")
                        Toggle("Enabled", isOn: $draft.job.isEnabled)
                            .accessibilityLabel("Job enabled")
                        if let reason = draft.job.disabledReason, !draft.job.isEnabled {
                            Text(reason).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            footer
        }
        .padding(LadaGlass.Spacing.l)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 620)
        .lgSheetSurface()
        .onChange(of: draft.job) { _, _ in failure = nil }
    }

    static func title(of format: ReportFormat) -> String {
        switch format {
        case .csv: return "CSV"
        case .json: return "JSON"
        case .text: return "Text"
        case .html: return "HTML"
        }
    }

    // MARK: Sections

    private var pipelineSection: some View {
        Section("Pipeline") {
            Picker("Use", selection: $draft.job.presetID) {
                Text("The job's own pipeline").tag(UUID?.none)
                ForEach(presets) { Text("Preset: \($0.name)").tag(UUID?.some($0.id)) }
            }
            .accessibilityLabel("Pipeline source")
            if let id = draft.job.presetID {
                Text(presets.contains { $0.id == id }
                     ? "Uses the preset as it is when the job runs."
                     : "This preset no longer exists; choose another or use the job's own pipeline.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            } else {
                Text(JobsView.pipelineSummary(draft.job.pipeline))
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .accessibilityLabel("Steps: \(JobsView.pipelineSummary(draft.job.pipeline))")
                Button("Use current pipeline") { draft.job.pipeline = currentPipeline }
                    .buttonStyle(.lg(.secondary))
                    .help("Copies the pipeline from the main window into this job")
            }
        }
    }

    private var inputsSection: some View {
        Section("Input folders") {
            if draft.job.inputs.isEmpty {
                Text("No folders yet").foregroundStyle(LadaGlass.Colors.muted)
            }
            ForEach(draft.job.inputs, id: \.self) { url in
                HStack {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(url.path).font(LadaGlass.Typography.mono).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        draft.job.inputs.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.lg(.ghost))
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                }
            }
            Button("Add folder…", action: addFolders)
                .buttonStyle(.lg(.secondary))
                .accessibilityLabel("Add input folder")
            Toggle("Include subfolders", isOn: $draft.job.recursive)
                .accessibilityLabel("Include subfolders")
        }
    }

    private var triggerSection: some View {
        Section("Runs") {
            Picker("Start", selection: $draft.trigger) {
                Text("Manually (Run now)").tag(JobDraft.Trigger.manual)
                Text("When files arrive (watch)").tag(JobDraft.Trigger.watch)
                Text("On a schedule").tag(JobDraft.Trigger.schedule)
            }
            .accessibilityLabel("When the job runs")
            if draft.trigger == .schedule {
                HStack {
                    Text("Every")
                    TextField("Every", value: $draft.every, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .labelsHidden()
                        .accessibilityLabel("Run every")
                    Stepper("Every", value: $draft.every, in: 1...999).labelsHidden()
                        .accessibilityLabel("Run every")
                    Picker("Unit", selection: $draft.unit) {
                        Text("minutes").tag(JobDraft.Unit.minutes)
                        Text("hours").tag(JobDraft.Unit.hours)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Schedule unit")
                }
            }
            Text(triggerNote).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
        }
    }

    private var triggerNote: String {
        switch draft.trigger {
        case .manual: return "Runs only when you choose Run now."
        case .watch: return "New and changed images are processed once they have finished copying. "
            + "Watching runs while the app is open, and catches up when it starts."
        case .schedule: return "Looks for new and changed images on this schedule while the app is open (at least every 5 minutes)."
        }
    }

    private var footer: some View {
        HStack {
            if let message = failure ?? draft.problem {
                Text(message)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(failure == nil ? LadaGlass.Colors.muted : LadaGlass.Colors.badText)
                    .accessibilityLabel("Problem: \(message)")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.lg(.ghost))
                .keyboardShortcut(.cancelAction)
            Button(draft.isNew ? "Create Job" : "Save", action: save)
                .buttonStyle(.lg(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose the folders this job watches"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.job.inputs.contains(url) && draft.job.inputs.count < JobSettings.maxInputs {
            draft.job.inputs.append(url)
        }
    }

    private func save() {
        guard draft.problem == nil else { return }
        do {
            try onSave(draft.result)
            dismiss()
        } catch {
            failure = AppModel.message(error)
        }
    }
}
