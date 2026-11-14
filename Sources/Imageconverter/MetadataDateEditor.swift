import SwiftUI
import ImageconverterCore

// MARK: - Date

private enum DateMode: String, CaseIterable { case keep = "Keep", set = "Set", shift = "Shift" }

/// Date taken: keep, set to a fixed moment, or shift by days, hours and minutes; plus "file dates".
struct MetadataDateEditor: View {
    @Binding var options: MetadataOptions
    /// Only matters while the shift is zero (then the sign can't be read from the stored value).
    @State private var laterWhenZero = true

    private var shiftSeconds: Int {
        if case .shift(let seconds) = options.dateTaken { return seconds }
        return 0
    }

    private var later: Bool { shiftSeconds == 0 ? laterWhenZero : shiftSeconds > 0 }

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
            EmptyView()
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
            Picker("Direction", selection: Binding(get: { later }, set: { laterWhenZero = $0; commit(sign: $0, parts: parts) })) {
                Text("Later").tag(true)
                Text("Earlier").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Shift direction")
            shiftField("Days", 0, "d")
            shiftField("Hours", 1, "h")
            shiftField("Minutes", 2, "min")
        }
    }

    /// Days, hours and minutes of the stored shift (hours and minutes may exceed their usual range once typed).
    private var parts: [Int] {
        let total = abs(shiftSeconds)
        return [total / 86_400, total % 86_400 / 3_600, total % 3_600 / 60]
    }

    private func shiftField(_ title: String, _ slot: Int, _ suffix: String) -> some View {
        NumberField(title: title, value: Binding(get: { parts[slot] }, set: { new in
            var updated = parts
            updated[slot] = new
            commit(sign: later, parts: updated)
        }), minimum: 0, maximum: 73_000, suffix: suffix, showsTitle: false)
    }

    private func commit(sign: Bool, parts: [Int]) {
        let total = parts[0] * 86_400 + parts[1] * 3_600 + parts[2] * 60
        options.dateTaken = .shift(seconds: min(total, DateEdit.maxShift) * (sign ? 1 : -1))
    }

    private func choose(_ new: DateMode) {
        switch new {
        case .keep: options.dateTaken = .keep
        case .set:
            if case .set = options.dateTaken { return }
            options.dateTaken = .set(Date())
        case .shift:
            if case .shift = options.dateTaken { return }
            commit(sign: laterWhenZero, parts: [0, 0, 0])
        }
    }
}

// MARK: - Location

private enum LocationMode: String, CaseIterable { case keep = "Keep", remove = "Remove", set = "Set" }

/// GPS: keep, remove, or set latitude, longitude and optional altitude (validated as you type).
struct MetadataLocationEditor: View {
    @Binding var location: LocationEdit
    @State private var picked: LocationMode?
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var altitude = ""

    private var storedMode: LocationMode {
        switch location {
        case .keep: .keep
        case .remove: .remove
        case .set: .set
        }
    }

    /// The choice shown: while "Set" is picked but the fields aren't valid yet, the stored value is `.keep`.
    private var mode: LocationMode { picked ?? storedMode }

    var body: some View {
        Picker("Location", selection: Binding(get: { mode }, set: choose)) {
            ForEach(LocationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Location")
        .onAppear(perform: load)
        .onChange(of: location) { _, new in
            // A preset or template changed it from outside.
            if case .set = new { picked = nil; load() } else if picked == .set { picked = nil }
        }
        if mode == .set {
            FieldRow {
                coordinateField("Latitude", $latitude)
                coordinateField("Longitude", $longitude)
                coordinateField("Altitude (m)", $altitude)
            }
            if let problem {
                Text(problem).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
                    .accessibilityLabel("Problem: \(problem)")
            }
        }
    }

    private func coordinateField(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0; commit() }),
                  prompt: Text(title))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(title)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// What is wrong with the fields, or nil when they make a valid position.
    private var problem: String? {
        guard let lat = Self.number(latitude) else { return "Enter a latitude from -90 to 90." }
        guard (-90...90).contains(lat) else { return "Latitude must be from -90 to 90." }
        guard let lon = Self.number(longitude) else { return "Enter a longitude from -180 to 180." }
        guard (-180...180).contains(lon) else { return "Longitude must be from -180 to 180." }
        if !altitude.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let alt = Self.number(altitude), abs(alt) <= LocationEdit.maxAltitude else {
                return "Altitude is in metres, at most 100 000 either way (leave empty for none)."
            }
        }
        return nil
    }

    private func load() {
        guard case .set(let lat, let lon, let alt) = location else { return }
        latitude = lat.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
        longitude = lon.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
        altitude = alt.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) } ?? ""
    }

    private func commit() {
        guard problem == nil, let lat = Self.number(latitude), let lon = Self.number(longitude) else {
            // Never keep a stale position while the fields are wrong.
            if case .set = location { location = .keep }
            return
        }
        let alt = altitude.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.number(altitude)
        location = .set(latitude: lat, longitude: lon, altitude: alt)
    }

    private func choose(_ new: LocationMode) {
        switch new {
        case .keep: picked = nil; location = .keep
        case .remove: picked = nil; location = .remove
        case .set:
            picked = .set
            commit()
            if case .set = location { picked = nil } else { location = .keep }
        }
    }
}
