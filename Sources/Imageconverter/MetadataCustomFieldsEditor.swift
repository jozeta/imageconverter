import SwiftUI
import ImageconverterCore

/// Rows of extra EXIF/IPTC/XMP fields: namespace and key from the allowlist, and a value. An empty value
/// clears the field. Rows have no ids of their own, so view state keeps stable ones.
struct MetadataCustomFieldsEditor: View {
    @Binding var fields: [MetadataField]
    @State private var ids: RowIDs

    init(fields: Binding<[MetadataField]>) {
        _fields = fields
        _ids = State(initialValue: RowIDs(count: fields.wrappedValue.count))
    }

    private static let namespaceLabels: [MetadataNamespace: String] = [.exif: "EXIF", .iptc: "IPTC", .xmp: "XMP"]

    var body: some View {
        ForEach(ids.rows(count: fields.count), id: \.id) { row in
            fieldRow(row.index)
        }
        Button {
            add()
        } label: {
            Label("Add field", systemImage: "plus")
        }
        .buttonStyle(.lg(.ghost))
        .disabled(fields.count >= Self.maxRows)
        .accessibilityLabel("Add custom field")
        Text("Only fields on the allowlist can be written. An empty value is ignored.")
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
            .onChange(of: fields.count) { _, count in ids.sync(count: count) }
    }

    private static let maxRows = 30

    @ViewBuilder private func fieldRow(_ index: Int) -> some View {
        if fields.indices.contains(index) {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
                HStack(spacing: LadaGlass.Spacing.s) {
                    Picker("Namespace", selection: Binding(
                        get: { fields.indices.contains(index) ? fields[index].namespace : .exif },
                        set: { setNamespace($0, at: index) })) {
                        ForEach(MetadataNamespace.allCases, id: \.self) { Text(Self.namespaceLabels[$0] ?? $0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Namespace")
                    Picker("Field", selection: Binding(
                        get: { fields.indices.contains(index) ? fields[index].key : "" },
                        set: { if fields.indices.contains(index) { fields[index].key = $0 } })) {
                        ForEach(MetadataFields.writable[fields[index].namespace] ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Field")
                    Spacer(minLength: 0)
                    removeButton(index)
                }
                TextField("Value", text: Binding(
                    get: { fields.indices.contains(index) ? fields[index].value : "" },
                    set: { if fields.indices.contains(index) { fields[index].value = $0 } }),
                    prompt: Text("Empty is ignored"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Value")
            }
        }
    }

    private func removeButton(_ index: Int) -> some View {
        Button {
            remove(index)
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(LadaGlass.Colors.muted)
        .accessibilityLabel("Remove field \(fields.indices.contains(index) ? fields[index].key : "")")
    }

    private func setNamespace(_ namespace: MetadataNamespace, at index: Int) {
        guard fields.indices.contains(index), fields[index].namespace != namespace else { return }
        fields[index].namespace = namespace
        // Keys differ per namespace; start at the first one.
        fields[index].key = MetadataFields.writable[namespace]?.first ?? ""
    }

    private func add() {
        // The first allowlisted key not used yet, so a new row doesn't repeat an existing one.
        for namespace in MetadataNamespace.allCases {
            for key in MetadataFields.writable[namespace] ?? []
            where !fields.contains(where: { $0.namespace == namespace && $0.key == key }) {
                ids.append()
                fields.append(MetadataField(namespace: namespace, key: key, value: ""))
                return
            }
        }
    }

    private func remove(_ index: Int) {
        guard fields.indices.contains(index) else { return }
        ids.remove(at: index)
        fields.remove(at: index)
    }
}
