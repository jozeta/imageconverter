import SwiftUI
import ImageconverterCore

/// The main output as the "Output 1" card, the same card as the extra outputs' (`VariantPanel`): format and
/// compression with the ⓘ, and Save to. No remove button, name, size or suffix: the main output has none of them.
struct MainOutputCard: View {
    @Bindable var model: AppModel
    var settings: AppSettings

    private let title = OutputVariant.mainOutputName

    private var summary: String {
        OutputSummary.cardLine(model.pipeline.output, saveTo: settings.modeKind,
                               folderName: settings.outputFolder?.lastPathComponent, suffix: settings.sameFolderSuffix)
    }

    var body: some View {
        @Bindable var settings = settings
        @Bindable var panel = model.outputPanel
        return AccordionCard(isExpanded: $panel.mainOutputExpanded, canExpand: true, title: title) {
            OutputCardHeader(title: title, line: summary)
        } content: {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
                OutputFormatControls(output: $model.pipeline.output) {
                    EstimateInfoButton(model: model)
                }
                SaveToControl(kind: $settings.modeKind, folder: $settings.outputFolder,
                              suffix: $settings.sameFolderSuffix)
            }
            .disabled(model.isRunning)
        }
    }
}

/// The header of every output card ("Output 1" and the extra outputs): the title, one line under it (the summary, or
/// a problem in the warning colour) and an optional trailing control. Title and line are one VoiceOver element
/// ("Output 1: JPEG · 82 % · Converted"); the trailing control (the remove button) stays its own element.
struct OutputCardHeader<Trailing: View>: View {
    let title: String
    let line: String
    var isProblem = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: LadaGlass.Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(LadaGlass.Typography.subtitle)
                Text(line)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(isProblem ? LadaGlass.Colors.badText : LadaGlass.Colors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title): \(line)")
            Spacer(minLength: 0)
            trailing
        }
        .contentShape(Rectangle())
    }
}

extension OutputCardHeader where Trailing == EmptyView {
    init(title: String, line: String, isProblem: Bool = false) {
        self.init(title: title, line: line, isProblem: isProblem) { EmptyView() }
    }
}
