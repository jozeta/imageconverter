import SwiftUI
import ImageconverterCore

/// The preview table's "Alt text" row: the generated sentence (model output, shown as plain text), "Generating…",
/// or why there is none.
struct PreviewAltTextRow: View {
    let state: PreviewAltText.State?

    private var text: String {
        switch state {
        case .done(.text(let generated)): generated
        case .done(.failed(let reason)): "Not generated: \(reason)"
        case .generating, nil: "Generating\u{2026}"
        }
    }

    private var failed: Bool {
        if case .done(.failed) = state { return true }
        return false
    }

    var body: some View {
        GridRow(alignment: .top) {
            Text("Alt text").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            Text("—").font(LadaGlass.Typography.mono).foregroundStyle(LadaGlass.Colors.text)
            Text(text)
                .font(LadaGlass.Typography.body)
                .foregroundStyle(failed ? LadaGlass.Colors.warnText : LadaGlass.Colors.text)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
                .accessibilityLabel("Generated alt text: \(text)")
        }
    }
}
