import SwiftUI
import ImageconverterCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var settings: AppSettings
    @State private var targeted = false
    @State private var showFailures = false

    /// Panel padding plus the outer padding, top and bottom.
    private static let verticalChrome = 2 * LadaGlass.Spacing.l * LadaGlass.Density.paddingScale
        + 2 * LadaGlass.Spacing.m

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
                    PresetBar(model: model)
                    dropZone
                    countRow
                    PipelineSection(model: model, settings: settings)
                    runSection
                    failureList
                }
                // The natural height (not the stretched one), so the measurement never feeds back on the window.
                .background {
                    GeometryReader {
                        Color.clear.preference(key: SidebarContentHeightKey.self,
                                               value: $0.size.height + Self.verticalChrome)
                    }
                }
                // With the preview open the window can be taller than the content: the panel fills it.
                .frame(minHeight: max(viewport.size.height - Self.verticalChrome, 0), alignment: .top)
                .lgPanel()
                .padding(LadaGlass.Spacing.m)
            }
        }
        .onPreferenceChange(SidebarContentHeightKey.self) { model.windowSizer.contentHeightChanged($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lgBackdrop()
        .lgCompact()
        .lgToasts(model.toasts)
    }

    private var dropZone: some View {
        VStack(spacing: LadaGlass.Spacing.s) {
            Text(model.isAdding ? "Adding…" : "Drop images or folders here")
                .font(LadaGlass.Typography.body)
                .foregroundStyle(LadaGlass.Colors.muted)
                .multilineTextAlignment(.center)
            Button("Add…") { model.chooseInputs() }
                .buttonStyle(.lg(.secondary))
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

    @ViewBuilder private var runSection: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .accessibilityLabel("Conversion progress")
                    Text("\(progress.completed) / \(progress.total)")
                        .font(LadaGlass.Typography.mono)
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.lg(.secondary))
                    .accessibilityLabel("Cancel the conversion")
            }
        } else {
            Button("Run on \(model.items.count) \(model.items.count == 1 ? "image" : "images")") {
                model.run(settings: settings)
            }
            .buttonStyle(.lg(.primary))
            .disabled(model.items.isEmpty || model.isAdding)
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

/// The natural height of the sidebar's content plus its paddings; the window height follows it.
private struct SidebarContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
