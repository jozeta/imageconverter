import SwiftUI
import ImageconverterCore

// MARK: - Date

private enum DateMode: String, CaseIterable { case keep = "Keep", set = "Set", shift = "Shift" }

/// Date taken: keep, set to a fixed moment, or shift by days, hours and minutes; plus "file dates".
struct MetadataDateEditor: View {
    @Binding var options: MetadataOptions
    /// Only matters while the shift is zero (then the sign can't be read from the stored value).
    @State private var laterWhenZero = true

    private var shift: DateShift {
        if case .shift(let seconds) = options.dateTaken { return DateShift(seconds: seconds, laterWhenZero: laterWhenZero) }
        return DateShift(later: laterWhenZero)
    }

    private var mode: DateMode {
        switch options.dateTaken {
        case .keep: .keep
        case .set: .set
        case .shift: .shift
        }
    }

    var body: some View {
        Picker("Date taken", selection: Binding(get: { mode }, set: choose)) {
            ForEach(DateMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Date taken")
        switch options.dateTaken {
        case .keep:
            if options.dateTakenWasInvalid {
                LGChip(MetadataOptions.invalidDateNote, status: .warn)
                    .accessibilityLabel(MetadataOptions.invalidDateNote)
            }
        case .set(let date):
            DatePicker("Date taken", selection: Binding(get: { date }, set: { options.dateTaken = .set($0) }),
                       in: Self.range, displayedComponents: [.date, .hourAndMinute])
                .accessibilityLabel("Date and time taken")
        case .shift:
            shiftControls
        }
        Toggle("Set file dates to date taken", isOn: $options.setFileDates)
            .accessibilityLabel("Set file dates to date taken")
            .help("Creation and modification dates of the output file follow the date taken (or the original file's dates).")
    }

    /// Years 1...9999 so the EXIF date stays four digits (matches the core's limits).
    private static let range = Date(timeIntervalSinceReferenceDate: -63_082_281_600)...Date(timeIntervalSinceReferenceDate: 252_423_993_599)

    private var shiftControls: some View {
        FieldRow {
            Picker("Direction", selection: Binding(get: { shift.later }, set: { later in
                laterWhenZero = later
                var updated = shift
                updated.later = later
                options.dateTaken = .shift(seconds: updated.seconds)
            })) {
                Text("Later").tag(true)
                Text("Earlier").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Shift direction")
            shiftField("Days", \.days, "d")
            shiftField("Hours", \.hours, "h")
            shiftField("Minutes", \.minutes, "min")
        }
    }

    private func shiftField(_ title: String, _ part: WritableKeyPath<DateShift, Int>, _ suffix: String) -> some View {
        NumberField(title: title, value: Binding(get: { shift[keyPath: part] }, set: { new in
            var updated = shift
            updated[keyPath: part] = new
            options.dateTaken = .shift(seconds: updated.seconds)
        }), minimum: 0, maximum: 73_000, suffix: suffix, showsTitle: false)
    }

    private func choose(_ new: DateMode) {
        switch new {
        case .keep: options.dateTaken = .keep
        case .set:
            if case .set = options.dateTaken { return }
            options.dateTaken = .set(Date())
        case .shift:
            if case .shift = options.dateTaken { return }
            options.dateTaken = .shift(seconds: 0)
        }
    }
}

// MARK: - Location

private enum LocationMode: String, CaseIterable { case keep = "Keep", remove = "Remove", set = "Set" }

/// GPS: keep, remove, or set latitude, longitude and optional altitude (validated as you type). While "Set" is
/// chosen but the fields aren't valid, the location is removed, never kept, so the original position can't leak.
struct MetadataLocationEditor: View {
    @Binding var location: LocationEdit
    /// The chosen mode lives here, not in the stored value, so it survives half-typed fields and collapsing.
    @State private var mode: LocationMode
    @State private var draft: LocationDraft

    init(location: Binding<LocationEdit>) {
        _location = location
        _draft = State(initialValue: LocationDraft(location.wrappedValue))
        switch location.wrappedValue {
        case .keep: _mode = State(initialValue: .keep)
        case .remove: _mode = State(initialValue: .remove)
        case .set: _mode = State(initialValue: .set)
        }
    }

    var body: some View {
        Picker("Location", selection: Binding(get: { mode }, set: choose)) {
            ForEach(LocationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Location")
        .onChange(of: location) { _, new in external(new) }
        if mode == .set {
            FieldRow {
                coordinateField("Latitude", \.latitude)
                coordinateField("Longitude", \.longitude)
                coordinateField("Altitude (m)", \.altitude)
            }
            if let problem = draft.problem {
                Text("\(problem) Until then the location is removed.")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                    .accessibilityLabel("Problem: \(problem)")
            }
        }
    }

    private func coordinateField(_ title: String, _ field: WritableKeyPath<LocationDraft, String>) -> some View {
        TextField(title, text: Binding(get: { draft[keyPath: field] }, set: { new in
            draft[keyPath: field] = new
            location = draft.edit
        }), prompt: Text(title))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(title)
    }

    /// A change that didn't come from these fields (a preset, a template): follow it, without reformatting
    /// what is being typed.
    private func external(_ new: LocationEdit) {
        if mode == .set, new == draft.edit { return }
        switch new {
        case .keep: mode = .keep
        case .remove: mode = .remove
        case .set:
            mode = .set
            draft = LocationDraft(new)
        }
    }

    private func choose(_ new: LocationMode) {
        mode = new
        switch new {
        case .keep: location = .keep
        case .remove: location = .remove
        case .set: location = draft.edit
        }
    }
}
