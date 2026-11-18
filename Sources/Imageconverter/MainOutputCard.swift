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
            HStack(spacing: LadaGlass.Spacing.s) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(LadaGlass.Typography.subtitle)
                    Text(summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title): \(summary)")
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
