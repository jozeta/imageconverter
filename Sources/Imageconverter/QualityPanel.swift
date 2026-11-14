import SwiftUI
import ImageconverterCore

/// Four tiles with the selected image encoded at 40, 60, 80 and 95 %, each showing the region the preview
/// shows (re-cropped after a pan or zoom), with size and saving. Clicking a tile makes its quality the Output quality.
struct QualityPanel: View {
    @Bindable var model: AppModel
    /// A narrow pane gets lower tiles, so the images above keep their room.
    let stacked: Bool
    private var tileHeight: CGFloat { stacked ? 64 : 96 }

    var body: some View {
        let ladder = model.compare.ladder
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack {
                Text("Compare quality").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                Spacer()
                Button("Close") { model.compare.showsQuality = false }
                    .buttonStyle(.lg(.ghost))
                    .accessibilityLabel("Close the quality comparison")
            }
            if let ladder, !ladder.rungs.isEmpty {
                let columns = Array(repeating: GridItem(.flexible(), spacing: LadaGlass.Spacing.s), count: 4)
                LazyVGrid(columns: columns, spacing: LadaGlass.Spacing.s) {
                    ForEach(ladder.rungs, id: \.quality) { rung in tile(rung, original: ladder.originalBytes) }
                }
            } else if let failure = ladder?.failure {
                Text(failure).font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
            } else {
                HStack(spacing: LadaGlass.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Encoding at 40, 60, 80 and 95 %…")
                        .font(LadaGlass.Typography.body).foregroundStyle(LadaGlass.Colors.muted)
                }
                .frame(height: tileHeight)
            }
        }
        .padding(LadaGlass.Spacing.s)
        .lgSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare quality")
    }

    private func tile(_ rung: QualityLadder.Rung, original: Int?) -> some View {
        let percent = Int((rung.quality * 100).rounded())
        let output = model.pipeline.output
        let isCurrent = output.compression == .quality && abs(output.clampedQuality - rung.quality) < 0.005
        let size = SizeFormat.bytes(rung.bytes)
        let saving = CompareText.saving(original: original, output: rung.bytes)
        return Button {
            model.chooseQuality(rung.quality)
        } label: {
            VStack(spacing: LadaGlass.Spacing.xxs) {
                // The rung is already a crop of the region on screen, so it is shown whole.
                Image(rung.image, scale: 1, label: Text("Quality \(percent) percent"))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .background(Checkerboard())
                    .frame(maxWidth: .infinity)
                    .frame(height: tileHeight)
                    .clipShape(RoundedRectangle(cornerRadius: LadaGlass.Radius.small))
                Text("\(percent) %").font(LadaGlass.Typography.label)
                Text(saving.map { "\(size) · \($0)" } ?? size)
                    .font(LadaGlass.Typography.mono)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(1)
            }
            .padding(LadaGlass.Spacing.xs)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
                    .strokeBorder(isCurrent ? LadaGlass.accent.color : LadaGlass.Colors.border,
                                  lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help("Use \(percent) % as the output quality")
        .accessibilityLabel("Quality \(percent) percent, \(size)\(saving.map { ", \($0)" } ?? "")")
        .accessibilityHint("Sets the output quality")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
