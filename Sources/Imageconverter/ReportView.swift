import AppKit
import SwiftUI
import ImageconverterCore

/// The summary cards of one run: processed, succeeded, failed, skipped, original → output, saved, average
/// ratio and average time. Used in the sidebar Report section and in the History window.
struct ReportCards: View {
    let summary: RunSummary

    private struct Card: Identifiable {
        let title: String
        let value: String
        var tint: Color = LadaGlass.Colors.text
        var id: String { title }
    }

    private var cards: [Card] {
        let written = summary.succeeded > 0
        return [
            Card(title: "Processed", value: "\(summary.total)"),
            Card(title: "Succeeded", value: "\(summary.succeeded)", tint: written ? LadaGlass.Colors.okText : LadaGlass.Colors.text),
            Card(title: "Failed", value: "\(summary.failed)", tint: summary.failed > 0 ? LadaGlass.Colors.badText : LadaGlass.Colors.text),
            Card(title: "Skipped", value: "\(summary.skipped)"),
            Card(title: "Original → output",
                 value: written ? "\(SizeFormat.bytes(summary.inputBytes)) → \(SizeFormat.bytes(summary.outputBytes))" : "—"),
            Card(title: "Saved", value: written ? savedText : "—"),
            Card(title: "Average ratio", value: summary.averageRatio.map { "\(Int(($0 * 100).rounded())) %" } ?? "—"),
            Card(title: "Average time", value: summary.averageDuration > 0 ? String(format: "%.2f s", summary.averageDuration) : "—")
        ]
    }

    private var savedText: String {
        let bytes = summary.savedBytes
        return bytes < 0 ? "−" + SizeFormat.bytes(-bytes) : SizeFormat.bytes(bytes)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: LadaGlass.Spacing.s)], spacing: LadaGlass.Spacing.s) {
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.xxs) {
                    Text(card.title).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    Text(card.value).font(LadaGlass.Typography.subtitle).foregroundStyle(card.tint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LadaGlass.Spacing.s)
                .lgSurface()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(card.title): \(card.value)")
            }
        }
    }
}

/// Export ▸ CSV / JSON / HTML / Text… through a save panel (the sandbox grants the chosen file only).
struct ReportExportMenu: View {
    let report: ProcessingReport

    var body: some View {
        Menu("Export") {
            ForEach(ReportFormat.allCases, id: \.self) { format in
                Button(Self.title(format) + "…") { Self.export(report, format: format) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Export the report")
    }

    static func title(_ format: ReportFormat) -> String {
        switch format {
        case .csv: return "CSV"
        case .json: return "JSON"
        case .html: return "HTML"
        case .text: return "Text"
        }
    }

    @MainActor static func export(_ report: ProcessingReport, format: ReportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "report-\(Self.stamp(report.summary.finishedAt)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportExporter.data(report, format: format).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The report couldn't be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }
}

/// One run in full: the cards and a sortable table with a row per image.
struct ReportView: View {
    let report: ProcessingReport
    var truncated = false

    private struct Row: Identifiable {
        let id: Int
        let entry: ReportEntry
        var name: String { entry.name }
        var status: String { entry.status.rawValue }
        var input: Int { entry.inputBytes ?? -1 }
        var output: Int { entry.outputBytes ?? -1 }
        var ratio: Double { entry.ratio ?? .infinity }
        var duration: Double { entry.duration }
        var note: String { entry.note ?? "" }
    }

    @State private var sortOrder = [KeyPathComparator(\Row.id)]

    private var rows: [Row] {
        report.entries.enumerated().map { Row(id: $0.offset, entry: $0.element) }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            ReportCards(summary: report.summary)
            if truncated {
                Text("Only the first \(RunHistory.maxEntries) files of this run are stored.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("File", value: \.name) { row in
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.entry.source)
                }
                TableColumn("Status", value: \.status) { row in
                    Text(row.status).foregroundStyle(row.entry.status == .failed ? LadaGlass.Colors.badText : LadaGlass.Colors.text)
                }
                .width(min: 60, ideal: 70)
                TableColumn("Original", value: \.input) { row in
                    Text(row.entry.inputBytes.map(SizeFormat.bytes) ?? "—")
                }
                .width(min: 60, ideal: 70)
                TableColumn("Output", value: \.output) { row in
                    Text(row.entry.outputBytes.map(SizeFormat.bytes) ?? "—")
                }
                .width(min: 60, ideal: 70)
                TableColumn("Change", value: \.ratio) { row in
                    Text(row.entry.inputBytes.flatMap { input in
                        row.entry.outputBytes.flatMap { SizeFormat.percentChange(from: input, to: $0) }
                    } ?? "—")
                }
                .width(min: 50, ideal: 60)
                TableColumn("Time", value: \.duration) { row in
                    Text(row.duration > 0 ? String(format: "%.2f s", row.duration) : "—")
                }
                .width(min: 50, ideal: 60)
                TableColumn("Note", value: \.note) { row in
                    Text(row.note).lineLimit(1).truncationMode(.tail).help(row.note)
                        .foregroundStyle(row.entry.status == .failed ? LadaGlass.Colors.badText : LadaGlass.Colors.muted)
                }
            }
            .accessibilityLabel("Files in this run")
        }
    }
}

/// The error log: the newest failures, newest first. Paths and reasons are shown as plain text.
struct ErrorLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ErrorLogEntry] = []
    private let log = ErrorLog.shared(directory: AppDefaults.logsDirectory)

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("Error log").font(LadaGlass.Typography.title)
            if entries.isEmpty {
                Text("No failures recorded.").font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
            } else {
                List(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.path).font(LadaGlass.Typography.body).lineLimit(1).truncationMode(.middle)
                        Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.reason)")
                            .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.badText)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityLabel("Recent failures")
            }
            HStack {
                Button("Reveal Log File") { NSWorkspace.shared.activateFileViewerSelecting([log.logURL]) }
                    .disabled(entries.isEmpty)
                Button("Clear Log") { log.clear(); entries = [] }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.lg(.secondary))
        }
        .padding(LadaGlass.Spacing.l)
        .frame(width: 520, height: 360)
        .lgBackdrop()
        .lgCompact()
        .onAppear { entries = log.recent(limit: 200) }
    }
}
