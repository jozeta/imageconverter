import SwiftUI
import ImageconverterCore

/// Templates ▸ Apply ▸ …, Save as template…, Delete ▸ … for the Metadata editor.
struct MetadataTemplatesMenu: View {
    @Binding var options: MetadataOptions
    @Environment(MetadataTemplatesModel.self) private var templates: MetadataTemplatesModel?
    @Environment(AppModel.self) private var model: AppModel?
    @State private var showSave = false
    @State private var pendingDelete: MetadataTemplate?

    var body: some View {
        if let templates {
            Menu("Templates") {
                Menu("Apply") {
                    ForEach(templates.builtIns) { template in
                        Button(template.name) { options = MetadataTemplates.apply(template, to: options) }
                    }
                    if !templates.saved.isEmpty {
                        Divider()
                        ForEach(templates.saved) { template in
                            Button(template.name) { options = MetadataTemplates.apply(template, to: options) }
                        }
                    }
                }
                Button("Save as template…") { showSave = true }
                Menu("Delete") {
                    ForEach(templates.saved) { template in
                        Button(template.name) { pendingDelete = template }
                    }
                }
                .disabled(templates.saved.isEmpty)
            }
            .fixedSize()
            .accessibilityLabel("Metadata templates")
            .onAppear {
                let skipped = templates.loadIfNeeded()
                if !skipped.isEmpty {
                    model?.toasts.show("Skipped \(skipped.count) template \(skipped.count == 1 ? "file" : "files")",
                                       type: .info,
                                       description: skipped.map { "\($0.file): \($0.reason)" }.joined(separator: "\n"))
                }
            }
            .sheet(isPresented: $showSave) {
                NameSheet(title: "Save as template", initial: "", confirm: "Save", fieldLabel: "Template name",
                          validate: { try templates.validate($0) },
                          onSubmit: { name in
                              try templates.save(name: name, options: options)
                              model?.toasts.show("Saved template \(name)", type: .ok)
                          })
            }
            .confirmationDialog("Delete template \(pendingDelete?.name ?? "")?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
    }

    private func delete() {
        guard let template = pendingDelete, let templates else { return }
        pendingDelete = nil
        do {
            try templates.delete(template)
            model?.toasts.show("Deleted template \(template.name)", type: .info)
        } catch {
            model?.toasts.show("Couldn't delete the template", type: .bad, description: AppModel.message(error))
        }
    }
}
