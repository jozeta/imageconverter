import Foundation

/// The text fields behind the Metadata editor's Location "Set" mode, kept apart from SwiftUI so the rules can be tested.
public struct LocationDraft: Equatable, Sendable {
    public var latitude = ""
    public var longitude = ""
    public var altitude = ""

    public init() {}

    /// Fields showing a stored position (empty for anything else).
    public init(_ location: LocationEdit) {
        guard case .set(let lat, let lon, let alt) = location else { return }
        latitude = Self.text(lat, digits: 6)
        longitude = Self.text(lon, digits: 6)
        altitude = alt.map { Self.text($0, digits: 2) } ?? ""
    }

    private static func text(_ value: Double, digits: Int) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...digits)))
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// What is wrong with the fields, or nil when they make a valid position.
    public var problem: String? {
        guard let lat = Self.number(latitude) else { return "Enter a latitude from -90 to 90." }
        guard (-90...90).contains(lat) else { return "Latitude must be from -90 to 90." }
        guard let lon = Self.number(longitude) else { return "Enter a longitude from -180 to 180." }
        guard (-180...180).contains(lon) else { return "Longitude must be from -180 to 180." }
        if !altitude.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let alt = Self.number(altitude), alt.isFinite, abs(alt) <= LocationEdit.maxAltitude else {
                return "Altitude is in metres, at most 100 000 either way (leave empty for none)."
            }
        }
        return nil
    }

    /// The location to store: the position when the fields are valid, otherwise `.remove`, so the file's own
    /// position (the one the user meant to replace) never leaks through half-typed fields.
    public var edit: LocationEdit {
        guard problem == nil, let lat = Self.number(latitude), let lon = Self.number(longitude) else { return .remove }
        let alt = altitude.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.number(altitude)
        return .set(latitude: lat, longitude: lon, altitude: alt)
    }
}

/// A date shift as the editor shows it: a direction plus days, hours and minutes.
public struct DateShift: Equatable, Sendable {
    public var later: Bool
    public var days: Int
    public var hours: Int
    public var minutes: Int

    public init(later: Bool = true, days: Int = 0, hours: Int = 0, minutes: Int = 0) {
        self.later = later
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }

    /// `laterWhenZero` keeps the chosen direction while the shift is zero (the sign can't be read from 0).
    public init(seconds: Int, laterWhenZero: Bool = true) {
        let total = abs(seconds)
        self.init(later: seconds == 0 ? laterWhenZero : seconds > 0, days: total / 86_400,
                  hours: total % 86_400 / 3_600, minutes: total % 3_600 / 60)
    }

    /// The shift in seconds, limited to `DateEdit.maxShift`.
    public var seconds: Int {
        let total = max(0, days) * 86_400 + max(0, hours) * 3_600 + max(0, minutes) * 60
        return min(total, DateEdit.maxShift) * (later ? 1 : -1)
    }
}
