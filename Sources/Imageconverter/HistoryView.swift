import AppKit
import SwiftUI
import ImageconverterCore

extension Notification.Name {
    /// Posted after a run (manual or job) was written to the history.
    static let runHistoryChanged = Notification.Name("imageconverter.runHistoryChanged")
}

/// The History window's state, shared so the Jobs window can open it already filtered by a job.
@MainActor @Observable
final class HistoryController {
    static let shared = HistoryController()
    /// Nil shows every run.
    var jobFilter: String?
    var selection: UUID?
    private(set) var summaries: [RunSummary] = []
    private(set) var record: RunRecord?
    @ObservationIgnored let history = RunHistory.shared(directory: AppDefaults.historyDirectory)

    var jobNames: [String] {
        Array(Set(summaries.compactMap(\.jobName))).sorted()
    }

    func reload() {
        summaries = history.summaries(jobName: jobFilter)
        if let selection, !summaries.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = summaries.first?.id }
        record = selection.flatMap { history.record(id: $0) }
    }

    func select(_ id: UUID?) {
        selection = id
        record = id.flatMap { history.record(id: $0) }
    }

    func delete(_ id: UUID) {
        history.delete(id: id)
        reload()
    }

    func clearAll() {
        history.clear()
        selection = nil
        reload()
    }
}

/// Window ▸ History (⌥⌘H): past runs, newest first, with the report of the selected one.
struct HistoryView: View {
    static let windowID = "history"
    @Bindable var controller: HistoryController
    @State private var confirmingClear = false

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
                    Button("Reveal Outputs") { Self.reveal(record.report) }
                        .disabled(Self.outputs(record.report).isEmpty)
                    Button("Delete") { controller.delete(summary.id) }
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

    /// Written files that still exist.
    private static func outputs(_ report: ProcessingReport) -> [URL] {
        report.entries.compactMap { entry in
            guard entry.status == .succeeded, let path = entry.destination, FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private static func reveal(_ report: ProcessingReport) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(outputs(report).prefix(200)))
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
