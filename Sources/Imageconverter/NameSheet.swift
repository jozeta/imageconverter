import SwiftUI
import ImageconverterCore

/// A name field with inline validation, for saving and renaming presets and templates.
struct NameSheet: View {
    let title: String
    let initial: String
    let confirm: String
    /// The field's VoiceOver label, e.g. "Preset name".
    let fieldLabel: String
    /// Throws (a `PresetError`) when the name can't be used; runs as the user types.
    let validate: (String) throws -> Void
    let onSubmit: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// The reason the typed name can't be used yet (nil when it is fine).
    private var problem: String? {
        do {
            try validate(name)
            return nil
        } catch {
            return AppModel.message(error)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.m) {
            Text(title).font(LadaGlass.Typography.body.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel(fieldLabel)
            if let message = failure ?? (name.isEmpty ? nil : problem) {
                Text(message)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.badText)
                    .accessibilityLabel("Problem: \(message)")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.lg(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .buttonStyle(.lg(.primary))
                    .disabled(problem != nil)
            }
        }
        .padding(LadaGlass.Spacing.l)
        .frame(minWidth: 300)
        .lgSheetSurface()
        .onAppear {
            name = initial
            focused = true
        }
        .onChange(of: name) { _, _ in failure = nil }
    }

    private func submit() {
        guard problem == nil else { return }
        do {
            try onSubmit(name)
            dismiss()
        } catch {
            failure = AppModel.message(error)
        }
    }
}
