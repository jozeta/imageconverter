import SwiftUI
import ImageconverterCore

/// Which part a crop keeps: a fixed position (the anchor grid), the subject or the faces. Used by Crop and by
/// Resize's "Fill, crop edges".
struct FocusPicker: View {
    @Binding var focus: CropFocus
    /// The anchor last chosen, so trying Subject or Faces and going back keeps it.
    @State private var lastAnchor = Anchor.center

    private enum Kind: String, CaseIterable {
        case position = "Position", subject = "Subject", faces = "Faces"
    }

    private var kind: Kind {
        switch focus {
        case .anchor: return .position
        case .subject: return .subject
        case .faces: return .faces
        }
    }

    private static let detectedHelp = "Found on this Mac with Vision. When nothing is found the crop is centred "
        + "and the report says so."

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            HStack(spacing: LadaGlass.Spacing.s) {
                Text("Focus").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .accessibilityHidden(true)
                Picker("Focus", selection: Binding(
                    get: { kind },
                    set: { new in
                        switch new {
                        case .position: focus = .anchor(lastAnchor)
                        case .subject: focus = .subject
                        case .faces: focus = .faces
                        }
                    })) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Focus")
                .help("Position keeps the part at the anchor; Subject keeps what stands out; Faces keeps every face")
            }
            if case .anchor(let anchor) = focus {
                HStack(alignment: .top, spacing: LadaGlass.Spacing.s) {
                    Text("Anchor").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    AnchorPicker(anchor: Binding(
                        get: { anchor }, set: { lastAnchor = $0; focus = .anchor($0) }))
                }
            } else {
                Text(focus == .faces ? "Keeps every face; without faces, the subject. " + Self.detectedHelp
                                     : "Keeps what stands out most. " + Self.detectedHelp)
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if case .anchor(let anchor) = focus { lastAnchor = anchor } }
    }
}
