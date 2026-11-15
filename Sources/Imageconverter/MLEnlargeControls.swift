import SwiftUI
import ImageconverterCore

/// The Resize editor's ML enlarge fields: the factor and the model's state, with Download… when it isn't on
/// this Mac yet. The download needs a one-time yes; it never starts any other way.
struct MLEnlargeControls: View {
    @Binding var options: ResizeOptions
    @State private var model = MLEnlargeModel.shared
    @State private var askingConsent = false

    static let consentTitle = "Download Apple's enlargement model?"
    static let consentMessage = "macOS will download Apple's enlargement model from Apple. imageconverter itself "
        + "sends nothing. Download now?"

    private var factor: Int {
        if case .mlEnlarge(let value) = options.mode { return MLEnlarge.clampedFactor(value) }
        return 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Picker("Enlarge", selection: Binding(get: { factor }, set: { options.mode = .mlEnlarge(factor: $0) })) {
                ForEach(MLEnlarge.factors, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Enlargement factor")
            status
        }
        .onAppear { model.refresh() }
        .alert(Self.consentTitle, isPresented: $askingConsent) {
            Button("Download") {
                model.recordConsent()
                model.download()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.consentMessage)
        }
    }

    @ViewBuilder private var status: some View {
        if let message = model.availability.editorMessage {
            HStack(spacing: LadaGlass.Spacing.s) {
                Image(systemName: model.availability == .downloadRequired ? "arrow.down.circle" : "exclamationmark.triangle")
                    .foregroundStyle(LadaGlass.Colors.warnText)
                    .accessibilityHidden(true)
                Text(message)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.availability == .downloadRequired {
                    Button("Download\u{2026}") {
                        if model.hasConsent { model.download() } else { askingConsent = true }
                    }
                    .accessibilityHint("macOS downloads the model from Apple")
                }
            }
            if case .downloading(let progress) = model.availability {
                ProgressView(value: min(max(progress, 0), 1))
                    .accessibilityLabel("Model download")
            }
            if let error = model.downloadError {
                Text(error).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
            }
            Text("Until then, images with this step aren't enlarged: they fail with a note in the report.")
                .font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
