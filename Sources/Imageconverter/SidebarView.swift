import SwiftUI
import ImageconverterCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @State private var targeted = false
    @State private var showFailures = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                dropZone
                countRow
                outputSection
                modeRow
                runSection
                failureList
            }
            .lgPanel()
            .padding(LadaGlass.Spacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .lgToasts(model.toasts)
    }

    private var dropZone: some View {
        VStack(spacing: LadaGlass.Spacing.s) {
            Text("Drop images or folders here")
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .multilineTextAlignment(.center)
            Button("Add…") { model.chooseInputs() }
                .buttonStyle(.lg(.secondary))
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityLabel("Add images or folders")
        }
        .frame(maxWidth: .infinity)
        .padding(LadaGlass.Spacing.l)
        .lgSurface()
        .overlay(
            RoundedRectangle(cornerRadius: LadaGlass.Radius.card)
                .strokeBorder(targeted ? LadaGlass.accent.color : LadaGlass.Colors.border,
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private var countRow: some View {
        HStack {
            LGChip("\(model.items.count) \(model.items.count == 1 ? "image" : "images")", status: .neutral)
            Spacer()
            Button("Clear") { model.clear() }
                .buttonStyle(.lg(.ghost))
                .disabled(model.items.isEmpty || model.isRunning)
                .accessibilityLabel("Clear the image list")
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Text("Output").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            Picker("Format", selection: $model.output.format) {
                ForEach(OutputFormat.available(), id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("Output format")
            if model.output.format.supportsQuality {
                HStack {
                    Slider(value: $model.output.quality, in: 0.1...1, step: 0.01)
                        .accessibilityLabel("Quality")
                        .accessibilityValue("\(Int((model.output.quality * 100).rounded())) percent")
                    Text("\(Int((model.output.quality * 100).rounded())) %")
                        .font(LadaGlass.Typography.mono)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            if model.output.format == .tiff {
                Picker("Compression", selection: $model.output.tiffCompression) {
                    Text("None").tag(TIFFCompression.none)
                    Text("LZW").tag(TIFFCompression.lzw)
                }
                .accessibilityLabel("TIFF compression")
            }
        }
        .disabled(model.isRunning)
    }

    private var modeRow: some View {
        HStack {
            Text(settings.summary)
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(2)
            Spacer()
            Button("Change…") { openSettings() }
                .buttonStyle(.lg(.ghost))
                .accessibilityLabel("Change output settings")
        }
    }

    @ViewBuilder private var runSection: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed + progress.failed), total: Double(max(progress.total, 1)))
                        .accessibilityLabel("Conversion progress")
                    Text("\(progress.completed + progress.failed) / \(progress.total)")
                        .font(LadaGlass.Typography.mono)
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.lg(.secondary))
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel("Cancel the conversion")
            }
        } else {
            Button("Run on \(model.items.count) \(model.items.count == 1 ? "image" : "images")") {
                model.run(settings: settings)
            }
            .buttonStyle(.lg(.primary))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.items.isEmpty)
            .accessibilityLabel("Run the conversion")
        }
    }

    @ViewBuilder private var failureList: some View {
        if let failures = model.lastReport?.failures, !failures.isEmpty {
            DisclosureGroup("\(failures.count) skipped", isExpanded: $showFailures) {
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(failure.source.lastPathComponent).font(LadaGlass.Typography.body)
                            Text(failure.reason).font(LadaGlass.Typography.label)
                                .foregroundStyle(LadaGlass.Colors.badText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(LadaGlass.Typography.body)
        }
    }
}
