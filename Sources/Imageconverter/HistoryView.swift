import AppKit
import SwiftUI
import ImageconverterCore

extension Notification.Name {
    /// Posted after a run (manual or job) was written to the history.
    static let runHistoryChanged = Notification.Name("imageconverter.runHistoryChanged")
}

/// The History window's state, shared so the Jobs window can open it already filtered by a job.
/// All file work runs in detached tasks; a generation counter drops results that were overtaken.
@MainActor @Observable
final class HistoryController {
    static let shared = HistoryController()
    /// Nil shows every run.
    var jobFilter: String?
    private(set) var selection: UUID?
    private(set) var summaries: [RunSummary] = []
    private(set) var record: RunRecord?
    /// Written files of the selected run that still exist, checked once when the record loads.
    private(set) var outputs: [URL] = []
    /// Every job that has runs (not just the filtered ones), so the picker keeps its choices.
    private(set) var jobNames: [String] = []
    @ObservationIgnored let history = RunHistory.shared(directory: AppDefaults.historyDirectory)
    @ObservationIgnored private var generation = 0

    private struct Loaded: Sendable {
        var all: [RunSummary]
        var shown: [RunSummary]
        var selected: UUID?
        var record: RunRecord?
        var outputs: [URL]
    }

    private nonisolated static func load(_ history: RunHistory, filter: String?, wanted: UUID?) -> Loaded {
        let all = history.summaries()
        let shown = filter == nil ? all : all.filter { $0.jobName == filter }
        let selected = shown.first { $0.id == wanted }?.id ?? shown.first?.id
        let record = selected.flatMap { history.record(id: $0) }
        return Loaded(all: all, shown: shown, selected: selected, record: record, outputs: record?.report.existingOutputs() ?? [])
    }

    func reload() {
        generation += 1
        let token = generation
        let (history, filter, wanted) = (history, jobFilter, selection)
        Task.detached(priority: .userInitiated) {
            let result = Self.load(history, filter: filter, wanted: wanted)
            await MainActor.run { [weak self] in
                guard let self, token == generation else { return }
                summaries = result.shown
                jobNames = Array(Set(result.all.compactMap(\.jobName))).sorted()
                selection = result.selected
                record = result.record
                outputs = result.outputs
            }
        }
    }

    func select(_ id: UUID?) {
        selection = id
        generation += 1
        let token = generation
        let history = history
        Task.detached(priority: .userInitiated) {
            let record = id.flatMap { history.record(id: $0) }
            let outputs = record?.report.existingOutputs() ?? []
            await MainActor.run { [weak self] in
                guard let self, token == generation else { return }
                self.record = record
                self.outputs = outputs
            }
        }
    }

    func delete(_ id: UUID) {
        let history = history
        Task.detached(priority: .userInitiated) {
            history.delete(id: id)
            await MainActor.run { [weak self] in self?.reload() }
        }
    }

    func clearAll() {
        let history = history
        Task.detached(priority: .userInitiated) {
            history.clear()
            await MainActor.run { [weak self] in
                self?.selection = nil
                self?.reload()
            }
        }
    }
}

/// Window ▸ History (⌥⌘H): past runs, newest first, with the report of the selected one.
struct HistoryView: View {
    static let windowID = "history"
    @Bindable var controller: HistoryController
    @State private var confirmingClear = false
    @State private var confirmingDelete: UUID?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail.frame(minWidth: 420, maxWidth: .infinity)
        }
        .frame(minWidth: 720, minHeight: 380)
        .lgBackdrop()
        .lgCompact()
        .onAppear { controller.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .runHistoryChanged)) { _ in controller.reload() }
        .onChange(of: controller.jobFilter) { controller.reload() }
        .confirmationDialog("Delete this run from the history?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete", role: .destructive) { confirmingDelete.map(controller.delete) }
        } message: {
            Text("The converted images are not touched.")
        }
        .confirmationDialog("Clear the whole run history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { controller.clearAll() }
        } message: {
            Text("The reports are removed. The converted images are not touched.")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Show", selection: $controller.jobFilter) {
                Text("All runs").tag(String?.none)
                ForEach(controller.jobNames, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .accessibilityLabel("Filter runs by job")
            List(selection: Binding(get: { controller.selection }, set: { controller.select($0) })) {
                ForEach(controller.summaries) { summary in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(summary.finishedAt.formatted(date: .abbreviated, time: .shortened)).font(LadaGlass.Typography.body)
                        Text(Self.subtitle(summary)).font(LadaGlass.Typography.label)
                            .foregroundStyle(LadaGlass.Colors.muted).lineLimit(1)
                    }
                    .tag(summary.id)
                    .accessibilityElement(children: .combine)
                }
            }
            .overlay {
                if controller.summaries.isEmpty {
                    Text(controller.jobFilter == nil ? "No runs yet." : "No runs for this job.")
                        .font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
                }
            }
            .accessibilityLabel("Runs")
            Button("Clear History…") { confirmingClear = true }
                .buttonStyle(.lg(.secondary))
                .disabled(controller.summaries.isEmpty && controller.jobFilter == nil)
        }
        .padding(LadaGlass.Spacing.m)
    }

    static func subtitle(_ summary: RunSummary) -> String {
        var parts = [summary.jobName.map { "Job \($0)" } ?? summary.presetName ?? "Manual run", "\(summary.succeeded) written"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.extraFailureCount > 0 { parts.append(RunCountsText.extraFailures(summary.extraFailureCount)) }
        if summary.succeeded > 0, summary.savedBytes != 0 {
            parts.append(summary.savedBytes > 0 ? "saved \(SizeFormat.bytes(summary.savedBytes))"
                         : "grew \(SizeFormat.bytes(-summary.savedBytes))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var detail: some View {
        if let record = controller.record {
            let summary = record.summary
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(summary.jobName.map { "Job \($0)" } ?? summary.presetName ?? "Manual run")
                            .font(LadaGlass.Typography.title)
                        Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) · "
                             + "\(summary.outputMode) · \(String(format: "%.1f", summary.totalDuration)) s")
                            .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    }
                    Spacer()
                    ReportExportMenu(report: record.report)
                    Button("Reveal Outputs") { NSWorkspace.shared.activateFileViewerSelecting(Array(controller.outputs.prefix(200))) }
                        .disabled(controller.outputs.isEmpty)
                    Button("Delete") { confirmingDelete = summary.id }
                        .accessibilityLabel("Delete this run from the history")
                }
                .buttonStyle(.lg(.secondary))
                ReportView(report: record.report, truncated: record.entriesTruncated)
            }
            .padding(LadaGlass.Spacing.l)
        } else {
            Text("Select a run to see its report.")
                .font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Window ▸ History (⌥⌘H).
struct HistoryCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("History") {
                HistoryController.shared.jobFilter = nil
                openWindow(id: HistoryView.windowID)
            }
            .keyboardShortcut("h", modifiers: [.option, .command])
        }
    }
}
