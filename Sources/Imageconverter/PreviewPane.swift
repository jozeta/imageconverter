import SwiftUI
import ImageconverterCore

/// The right-hand pane: before and after of the selected image, what it is renamed to, and the filmstrip.
struct PreviewPane: View {
    @Bindable var model: AppModel
    /// Below this pane width the two images are stacked.
    static let stackedBelow: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            header
            if model.items.isEmpty {
                Spacer()
                Text("Add images to see a preview")
                    .font(LadaGlass.Typography.body)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                GeometryReader { geometry in
                    images(stacked: geometry.size.width < Self.stackedBelow)
                }
                .overlay { if model.isRenderingPreview { spinner } }
                runProgress
                infoTable
                Filmstrip(model: model)
            }
        }
        .lgPanel()
        .padding(LadaGlass.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
    }

    private var header: some View {
        Text("Preview").font(LadaGlass.Typography.subtitle)
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .padding(LadaGlass.Spacing.s)
            .lgSurface()
            .accessibilityLabel("Rendering the preview")
    }

    @ViewBuilder private func images(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: LadaGlass.Spacing.m))
                             : AnyLayout(HStackLayout(spacing: LadaGlass.Spacing.m))
        layout {
            side(title: "Before", image: model.previewResult?.before, failure: nil)
            side(title: "After", image: model.previewFailure == nil ? model.previewResult?.after : nil,
                 failure: model.previewFailure)
        }
    }

    private func side(title: String, image: CGImage?, failure: String?) -> some View {
        VStack(spacing: LadaGlass.Spacing.xs) {
            LGChip(title, status: .neutral)
            ZStack {
                if let image {
                    Image(image, scale: 1, label: Text("\(title) image")).resizable().scaledToFit()
                } else if let failure {
                    Text(failure)
                        .font(LadaGlass.Typography.body)
                        .foregroundStyle(LadaGlass.Colors.warnText)
                        .multilineTextAlignment(.center)
                        .padding(LadaGlass.Spacing.m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Progress bar and Cancel while a batch runs, directly above the table.
    @ViewBuilder private var runProgress: some View {
        if model.isRunning {
            HStack(spacing: LadaGlass.Spacing.s) {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .accessibilityLabel("Conversion progress")
                    Text("\(progress.completed) / \(progress.total)")
                        .font(LadaGlass.Typography.mono)
                        .foregroundStyle(LadaGlass.Colors.muted)
                } else {
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.lg(.secondary))
                    .accessibilityLabel("Cancel the conversion")
            }
        }
    }

    @ViewBuilder private var infoTable: some View {
        let result = model.previewResult
        let failed = model.previewFailure != nil
        if result != nil || failed {
            Grid(alignment: .leading, horizontalSpacing: LadaGlass.Spacing.m, verticalSpacing: LadaGlass.Spacing.xs) {
                GridRow {
                    Text("")
                    cell("Original", muted: true)
                    cell("Result", muted: true)
                }
                GridRow {
                    label("Name")
                    cell(result?.sourceName ?? model.previewFailureName ?? "—")
                    if let failure = model.previewFailure {
                        Text(failure).font(LadaGlass.Typography.mono)
                            .foregroundStyle(LadaGlass.Colors.warnText)
                            .lineLimit(2).gridCellColumns(1)
                    } else {
                        cell(result?.outputName ?? "—")
                    }
                }
                if !failed, let result {
                    GridRow {
                        label("Folder")
                        folderCell(result.source.deletingLastPathComponent())
                        folderCell(result.outputURL.deletingLastPathComponent())
                    }
                    GridRow {
                        label("Dimensions")
                        cell("\(result.sourceSize.0) × \(result.sourceSize.1)")
                        cell("\(result.outputSize.0) × \(result.outputSize.1)")
                    }
                    GridRow {
                        label("Size")
                        cell(Self.bytes(model.sizeEstimate?.original ?? result.sourceFileSize))
                        cell(resultSize)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private var resultSize: String {
        if model.isEstimating { return "Estimating…" }
        return Self.bytes(model.sizeEstimate?.output)
    }

    private static func bytes(_ count: Int?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
    }

    private func cell(_ text: String, muted: Bool = false) -> some View {
        Text(text)
            .font(muted ? LadaGlass.Typography.label : LadaGlass.Typography.mono)
            .foregroundStyle(muted ? LadaGlass.Colors.muted : LadaGlass.Colors.text)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func folderCell(_ url: URL) -> some View {
        let path = url.path
        return Text(path)
            .font(LadaGlass.Typography.mono)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}
