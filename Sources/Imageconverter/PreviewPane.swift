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
                infoLine
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
        HStack {
            Text("Preview").font(LadaGlass.Typography.subtitle)
            Spacer()
            Button("Hide preview") { model.togglePreview() }
                .buttonStyle(.lg(.ghost))
                .accessibilityLabel("Hide the preview")
        }
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

    @ViewBuilder private var infoLine: some View {
        if model.previewFailure != nil {
            Text(model.previewResult?.sourceName ?? model.previewFailureName ?? "")
                .font(LadaGlass.Typography.mono)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let result = model.previewResult {
            Text("\(result.sourceName) \(result.sourceSize.0) × \(result.sourceSize.1) → "
                 + "\(result.outputName) \(result.outputSize.0) × \(result.outputSize.1)")
                .font(LadaGlass.Typography.mono)
                .foregroundStyle(LadaGlass.Colors.muted)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
