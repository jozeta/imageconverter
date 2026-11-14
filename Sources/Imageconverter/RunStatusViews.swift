import SwiftUI
import ImageconverterCore

/// The progress area: bar, "12 / 124 · 3.4 img/s · about 2 min left", Pause/Resume and Cancel while a batch
/// runs, and the Performance disclosure during and after it. Shown in the preview pane, or in the sidebar
/// when the preview is hidden.
struct RunProgressArea: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            if model.isRunning { progressRows }
            // A run that doesn't report its stages (a saved job) shows the counts only.
            if model.monitor.isActive || (model.monitor.hasResults && !model.isRunning) { PerformancePanel(model: model) }
        }
    }

    private var line: String {
        let progress = model.progress
        let snapshot = model.monitor.snapshot
        guard model.monitor.isActive else { return "\(progress?.completed ?? 0) / \(progress?.total ?? 0)" }
        return RunStatusText.progress(completed: progress?.completed ?? 0, total: progress?.total ?? 0,
                                      imagesPerSecond: snapshot?.imagesPerSecond ?? 0, eta: snapshot?.eta,
                                      paused: model.monitor.isPaused)
    }

    /// Bar and buttons on one row, the counts, rate and time left below: two rows in the pane and the sidebar.
    @ViewBuilder private var progressRows: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            if let progress = model.progress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .accessibilityLabel("Conversion progress")
                    .accessibilityValue(line)
            } else {
                ProgressView().controlSize(.small)
                Spacer()
            }
            buttons
        }
        status
    }

    private var status: some View {
        Text(line)
            .font(LadaGlass.Typography.mono)
            .foregroundStyle(model.monitor.isPaused ? LadaGlass.Colors.warnText : LadaGlass.Colors.muted)
            // Two lines in the narrow sidebar rather than a cut-off time left.
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var buttons: some View {
        let paused = model.monitor.isPaused
        if model.monitor.isActive {
            Button(paused ? "Resume" : "Pause") { model.togglePause() }
                .buttonStyle(.lg(.secondary))
                .help(paused ? "Start new images again (⌥⌘.)" : "Finish the images in progress, start no new ones (⌥⌘.)")
                .accessibilityLabel(paused ? "Resume the conversion" : "Pause the conversion")
        }
        Button("Cancel") { model.cancel() }
            .buttonStyle(.lg(.secondary))
            .help("Stop the conversion (⌘.)")
            .accessibilityLabel("Cancel the conversion")
    }
}

/// CPU, memory, workers, img/s, MP/s and elapsed time, sampled once a second while running; averages and
/// the peak afterwards. Compact (three columns of label over value) so the preview keeps its room. The header
/// row also holds the Low-memory mode switch.
struct PerformancePanel: View {
    @Bindable var model: AppModel
    private static let columns = 3

    var body: some View {
        let monitor = model.monitor
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Button {
                    withAnimation(LadaGlass.Motion.quick) { monitor.expanded.toggle() }
                } label: {
                    HStack(spacing: LadaGlass.Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(monitor.expanded ? 90 : 0))
                        Text("Performance").font(LadaGlass.Typography.body)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(monitor.expanded ? "Hide performance details" : "Show performance details")
                Spacer(minLength: LadaGlass.Spacing.s)
                Toggle("Low-memory mode", isOn: $model.lowMemoryMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize()
                    .help("At most two images at a time and a quarter of the memory; the preview pauses during a run")
                    .accessibilityLabel("Low-memory mode")
            }
            if monitor.expanded { metrics }
        }
    }

    private var metrics: some View {
        let rows = self.rows
        return Grid(alignment: .leading, horizontalSpacing: LadaGlass.Spacing.l, verticalSpacing: LadaGlass.Spacing.xs) {
            ForEach(Array(stride(from: 0, to: rows.count, by: Self.columns)), id: \.self) { start in
                GridRow {
                    ForEach(rows[start..<min(start + Self.columns, rows.count)], id: \.0) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.0).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                            Text(row.1).font(LadaGlass.Typography.mono).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Performance")
    }

    /// While running: the last sample and the moving rates. After the run: averages over the whole run.
    private var rows: [(String, String)] {
        let monitor = model.monitor
        let snapshot = monitor.snapshot
        let elapsed = snapshot?.elapsed ?? 0
        if monitor.isActive {
            return [
                ("CPU", monitor.resources.map { RunStatusText.percent($0.cpuPercent) } ?? "—"),
                ("Memory", monitor.resources.map { SizeFormat.bytes(Int($0.memoryBytes)) } ?? "—"),
                ("Workers", "\(monitor.workersInUse)"),
                ("Images", RunStatusText.rate(snapshot?.imagesPerSecond ?? 0, unit: "img/s")),
                ("Pixels", RunStatusText.rate(snapshot?.megapixelsPerSecond ?? 0, unit: "MP/s")),
                ("Elapsed", RunStatusText.elapsed(elapsed)),
            ]
        }
        let done = Double(snapshot?.imagesDone ?? 0)
        return [
            ("Average CPU", monitor.averageCPU.map(RunStatusText.percent) ?? "—"),
            ("Peak memory", monitor.peakMemory > 0 ? SizeFormat.bytes(Int(monitor.peakMemory)) : "—"),
            ("Images done", "\(snapshot?.imagesDone ?? 0)"),
            ("Images", RunStatusText.rate(elapsed > 0 ? done / elapsed : 0, unit: "img/s")),
            ("Pixels", RunStatusText.rate(elapsed > 0 ? monitor.megapixelsDone / elapsed : 0, unit: "MP/s")),
            ("Elapsed", RunStatusText.elapsed(elapsed)),
        ]
    }
}

/// A small ring on a thumbnail: queued (outline), working (part ring), done (check) or failed (cross).
struct StageRing: View {
    let stage: ItemStage
    static let side: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().fill(LadaGlass.Colors.elevated)
            switch stage.ring {
            case .queued:
                Circle().strokeBorder(LadaGlass.Colors.muted, lineWidth: 1.5)
            case .working:
                Circle().strokeBorder(LadaGlass.Colors.border, lineWidth: 2)
                Circle().inset(by: 1).trim(from: 0, to: 0.65)
                    .stroke(LadaGlass.accent.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            case .done:
                Circle().fill(stage == .skipped ? LadaGlass.Colors.muted : LadaGlass.Colors.ok)
                Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(LadaGlass.Colors.onAccent)
            case .failed:
                Circle().fill(LadaGlass.Colors.bad)
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(LadaGlass.Colors.onAccent)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }
}

/// "The last batch was interrupted": Resume adds the images still to do and runs them, Discard forgets it.
/// Escape closes the sheet and keeps the journal for the next launch.
struct InterruptedRunSheet: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    let journal: RunJournal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let total = journal.items.count
        let done = journal.completed.count
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text("The last batch was interrupted").font(LadaGlass.Typography.body.weight(.semibold))
            Text("\(done) of \(total) \(total == 1 ? "image was" : "images were") done when it stopped, "
                 + "on \(journal.started.formatted(date: .abbreviated, time: .shortened)).")
                .font(LadaGlass.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Resume runs the other \(total - done) with the same pipeline and output: \(modeText).")
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { dismiss() }
                    .buttonStyle(.lg(.ghost))
                    .keyboardShortcut(.cancelAction)
                    .help("Ask again at the next launch")
                Spacer()
                Button("Discard") {
                    model.discardInterruptedRun()
                    dismiss()
                }
                .buttonStyle(.lg(.secondary))
                .accessibilityLabel("Discard the interrupted batch")
                Button("Resume") {
                    model.resumeInterruptedRun(settings: settings)
                    dismiss()
                }
                .buttonStyle(.lg(.primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Resume the interrupted batch")
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(width: 400)
        .lgSheetSurface()
    }

    private var modeText: String {
        switch journal.outputMode {
        case .newFolder(let folder): return "a new folder (\(folder.lastPathComponent))"
        case .sameFolder(let suffix): return "same folder, suffix \(suffix)"
        case .overwrite: return "overwrite the originals"
        }
    }
}

extension View {
    /// The resume sheet, shown while `model.interruptedRun` is set.
    func interruptedRunSheet(model: AppModel, settings: AppSettings) -> some View {
        sheet(isPresented: Binding(get: { model.interruptedRun != nil }, set: { if !$0 { model.interruptedRun = nil } })) {
            if let journal = model.interruptedRun {
                InterruptedRunSheet(model: model, settings: settings, journal: journal)
            }
        }
    }
}
