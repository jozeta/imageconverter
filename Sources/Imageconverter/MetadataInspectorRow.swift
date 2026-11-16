import SwiftUI
import ImageconverterCore

/// How a metadata value reads in the panel (untrusted text, already escaped by Core for file values).
enum MetadataValueText {
    static func text(_ value: MetadataOverrideValue) -> String {
        switch value {
        case .text(let text): return MetadataInspection.display(text)
        case .keywords(let list): return MetadataInspection.display(list.joined(separator: ", "))
        case let .location(latitude, longitude, altitude):
            return MetadataInspection.positionText(GPSPosition(latitude: latitude, longitude: longitude, altitude: altitude))
        case .date(let date): return date.formatted(date: .abbreviated, time: .standard)
        case .rating(let stars): return stars < 0 ? "Rejected" : "\(stars) of 5 stars"
        case .removed: return "Removed"
        }
    }
}

/// One metadata row: label, value (long ones cut with "Show all"), its state for this image's outputs, and the
/// Edit, Remove and Revert buttons.
struct MetadataInspectorRow: View {
    @Bindable var model: AppModel
    let entry: MetadataEntry
    let highlighted: Bool
    @Binding var editing: String?
    @State private var showsAll = false
    static let shortLength = 240

    private var overrides: MetadataOverrides { model.selectedOverrides }
    private var path: MetadataPath? { entry.path }
    private var removed: Bool { path.map(overrides.isRemoved) ?? false }
    private var newValue: MetadataOverrideValue? {
        guard let field = entry.field, let value = overrides.fields[field], value != .removed else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xxs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text(entry.label)
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if removed { LGChip("Removed", status: .bad).fixedSize() }
                if newValue != nil { LGChip("Edited", status: .warn).fixedSize() }
                Spacer(minLength: 0)
                buttons
            }
            if let newValue {
                Text(MetadataValueText.text(newValue)).font(LadaGlass.Typography.body).textSelection(.enabled)
                Text("Original: " + shown(entry.value))
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            } else {
                Text(shown(entry.value))
                    .font(LadaGlass.Typography.body)
                    .strikethrough(removed)
                    .foregroundStyle(removed ? LadaGlass.Colors.muted : LadaGlass.Colors.text)
                    .textSelection(.enabled)
            }
            if entry.value.count > Self.shortLength {
                Button(showsAll ? "Show less" : "Show all") { showsAll.toggle() }
                    .buttonStyle(.lg(.ghost)).controlSize(.small)
            }
            if editing == entry.id, let field = entry.field {
                MetadataValueEditor(field: field, initial: newValue ?? entry.editValue) { value in
                    if model.setMetadataOverride(field, to: value) { editing = nil }
                } cancel: { editing = nil }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(LadaGlass.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
            .fill(highlighted ? LadaGlass.accent.color.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
            .strokeBorder(highlighted ? LadaGlass.accent.color : Color.clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    /// The label, the shown (cut) value and the state; an edit reads its new value.
    private var accessibilityText: String {
        let value = String(entry.value.prefix(Self.shortLength))
        if let newValue { return "\(entry.label): \(MetadataValueText.text(newValue)), edited, was \(value)" }
        return "\(entry.label): \(value)\(removed ? ", removed" : "")"
    }

    private func shown(_ text: String) -> String {
        showsAll || text.count <= Self.shortLength ? text : String(text.prefix(Self.shortLength)) + "…"
    }

    @ViewBuilder private var buttons: some View {
        let disabled = model.isRunning
        if let path, overrides.isChanged(path) {
            iconButton("arrow.uturn.backward", "Revert \(entry.label)") { model.revertMetadata(path) }
                .disabled(disabled)
        }
        if entry.field != nil, !removed {
            iconButton("pencil", "Edit \(entry.label)") { editing = entry.id }
                .disabled(disabled)
        }
        if let path, entry.removable, !removed {
            iconButton("minus.circle", "Remove \(entry.label) from this image's outputs") { model.removeMetadata(path) }
                .disabled(disabled)
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.lg(.ghost))
            .controlSize(.small)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// A field that isn't in the file and was added for this image's outputs.
struct MetadataAddedRow: View {
    @Bindable var model: AppModel
    let field: MetadataOverrideField
    let value: MetadataOverrideValue
    @Binding var editing: String?

    private var id: String { "added:\(field.label)" }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xxs) {
            HStack(spacing: LadaGlass.Spacing.xs) {
                Text(field.label).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
                LGChip("Added", status: .ok).fixedSize()
                Spacer(minLength: 0)
                Button { editing = id } label: { Image(systemName: "pencil") }
                    .buttonStyle(.lg(.ghost)).controlSize(.small)
                    .help("Edit \(field.label)").accessibilityLabel("Edit \(field.label)")
                Button { model.revertMetadata(field) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.lg(.ghost)).controlSize(.small)
                    .help("Remove the added \(field.label)").accessibilityLabel("Revert \(field.label)")
            }
            .disabled(model.isRunning)
            Text(MetadataValueText.text(value)).font(LadaGlass.Typography.body).textSelection(.enabled)
            if editing == id {
                MetadataValueEditor(field: field, initial: value) { newValue in
                    if model.setMetadataOverride(field, to: newValue) { editing = nil }
                } cancel: { editing = nil }
            }
        }
        .padding(LadaGlass.Spacing.xs)
        .accessibilityElement(children: .contain)
    }
}

/// Asks for one field's new value in the form the field takes (text, keywords, a position, a date, a rating).
struct MetadataValueEditor: View {
    let field: MetadataOverrideField
    let initial: MetadataOverrideValue?
    let save: (MetadataOverrideValue) -> Void
    let cancel: () -> Void

    @State private var text = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var altitude = ""
    @State private var date = Date()
    @State private var rating = 0
    @FocusState private var focused: Bool
    @Environment(\.overwritesOriginals) private var overwritesOriginals

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            fields
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.lg(.secondary)).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Apply to Outputs") { if let value { save(value) } }
                    .buttonStyle(.lg(.primary)).controlSize(.small)
                    .disabled(value?.validated == nil)
                    .help(overwritesOriginals ? MetadataInspector.overwriteNote
                          : "This image's outputs get the new value; the original isn't changed")
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var fields: some View {
        switch field.valueKind {
        case .text, .keywords:
            TextField(field.valueKind == .keywords ? "Keywords, separated by commas" : field.label, text: $text,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...6).focused($focused)
                .onSubmit { if let value, value.validated != nil { save(value) } }
        case .location:
            HStack {
                TextField("Latitude", text: $latitude).textFieldStyle(.roundedBorder).focused($focused)
                TextField("Longitude", text: $longitude).textFieldStyle(.roundedBorder)
            }
            TextField("Altitude in metres (optional)", text: $altitude).textFieldStyle(.roundedBorder)
            Text("Decimal degrees, negative for south and west").font(LadaGlass.Typography.label)
                .foregroundStyle(LadaGlass.Colors.muted)
        case .date:
            DatePicker("Date taken", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        case .rating:
            Picker("Rating", selection: $rating) {
                Text("Rejected").tag(-1)
                ForEach(0...5, id: \.self) { Text($0 == 0 ? "No stars" : "\($0) of 5 stars").tag($0) }
            }
            .labelsHidden()
        }
    }

    /// The value typed so far, or nil while it isn't one (e.g. a latitude that isn't a number).
    private var value: MetadataOverrideValue? {
        switch field.valueKind {
        case .text: return .text(text)
        case .keywords: return .keywords(text.split(separator: ",").map(String.init))
        case .location:
            guard let lat = Self.number(latitude), let lon = Self.number(longitude) else { return nil }
            let trimmed = altitude.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .location(latitude: lat, longitude: lon, altitude: nil) }
            guard let alt = Self.number(trimmed) else { return nil }
            return .location(latitude: lat, longitude: lon, altitude: alt)
        case .date: return .date(date)
        case .rating: return .rating(rating)
        }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func load() {
        switch initial {
        case .text(let value)?: text = value
        case .keywords(let list)?: text = list.joined(separator: ", ")
        case let .location(lat, lon, alt)?:
            latitude = String(lat)
            longitude = String(lon)
            altitude = alt.map { String($0) } ?? ""
        case .date(let value)?: date = value
        case .rating(let stars)?: rating = stars
        case .removed?, nil: break
        }
        focused = true
    }
}
