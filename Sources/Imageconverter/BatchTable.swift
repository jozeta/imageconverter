import SwiftUI
import ImageconverterCore

/// One batch item as a list row.
private struct BatchRow: Identifiable {
    let index: Int
    let item: InputItem
    var id: URL { item.source }
}

/// The batch as a table: name, dimensions, file size, the estimated output (selected item only, once known)
/// and how the last run ended for each file. Dimensions and sizes are read lazily for the rows on screen.
struct BatchTable: View {
    @Bindable var model: AppModel
    /// Rebuilt only when the batch changes, not on every body pass.
    @State private var rows: [BatchRow] = []
    @State private var statuses: [String: ReportStatus] = [:]

    var body: some View {
        let hasReport = model.runReport != nil
        let selection = Binding<URL?>(
            get: { model.selectedItemIndex.map { model.items[$0].source } },
            set: { url in
                if let url, let index = model.items.firstIndex(where: { $0.source == url }) { model.selectedIndex = index }
            })
        Table(rows, selection: selection) {
            TableColumn("Name") { row in
                Text(row.item.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.item.source.path)
                    .task(id: row.id) { await model.loadSummary(for: row.id) }
            }
            .width(min: 120, ideal: 200)
            TableColumn("Dimensions") { row in
                mono(model.compare.summaries[row.id].flatMap { summary in
                    summary.width.flatMap { width in summary.height.map { "\(width) × \($0)" } }
                } ?? "—")
            }
            .width(min: 80, ideal: 100)
            TableColumn("Size") { row in
                mono(model.compare.summaries[row.id]?.bytes.map(SizeFormat.bytes) ?? "—")
            }
            .width(min: 60, ideal: 80)
            TableColumn("Estimated") { row in mono(estimate(for: row.id)) }
                .width(min: 70, ideal: 90)
            // Live stages during a run and its final ones after (read through the monitor, which the cells
            // observe). Runs without stages (saved jobs) use the report; after a cancelled run, files without an
            // entry were never processed.
            TableColumn("Status") { row in
                if let stage = model.monitor.stage(for: row.id) {
                    liveStatus(stage, running: model.isRunning)
                } else {
                    status(statuses[row.id.path] ?? (hasReport ? .cancelled : nil))
                }
            }
            .width(min: 60, ideal: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: URL.self) { urls in
            if model.isRunning, !urls.isEmpty {
                Button("Process Next") { model.processNext(model.items.map(\.source).filter(urls.contains)) }
            }
        }
        .onChange(of: model.items, initial: true) { _, items in
            rows = items.enumerated().map { BatchRow(index: $0.offset, item: $0.element) }
            model.compare.setActiveSources(Set(items.map(\.source)))
        }
        .onChange(of: model.runReport, initial: true) { _, report in statuses = Self.statuses(report) }
        .accessibilityLabel("Image list")
    }

    /// Only the selected item has an estimate, and only once it is ready.
    private func estimate(for url: URL) -> String {
        guard let estimate = model.sizeEstimate, estimate.item == url,
              url == model.selectedItemIndex.map({ model.items[$0].source }),
              let output = estimate.output else { return "—" }
        return SizeFormat.bytes(output)
    }

    /// How each file of the last run ended, by source path. A file with several entries keeps the first.
    private static func statuses(_ report: ProcessingReport?) -> [String: ReportStatus] {
        guard let report else { return [:] }
        return Dictionary(report.entries.map { ($0.source, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    @ViewBuilder private func status(_ status: ReportStatus?) -> some View {
        switch status {
        case .succeeded: LGChip("Written", status: .ok)
        case .skipped: LGChip("Skipped", status: .warn)
        case .failed: LGChip("Failed", status: .bad)
        case .cancelled: LGChip("Not run", status: .neutral)
        case nil: mono("—")
        }
    }

    /// The item's stage; working stages are named (Decoding, Encoding…). Still queued after the run: not run.
    @ViewBuilder private func liveStatus(_ stage: ItemStage, running: Bool) -> some View {
        switch stage.ring {
        case .queued: LGChip(running ? stage.title : ItemStage.cancelled.title, status: .neutral)
        case .working: LGChip(stage.title, status: .neutral)
        case .done: LGChip(stage.title, status: stage == .skipped ? .warn : .ok)
        case .failed: LGChip(stage.title, status: .bad)
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.mono).lineLimit(1)
    }
}
