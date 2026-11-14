import Foundation

/// Whether new keywords are added to the file's own or replace them.
public enum KeywordsMode: String, Codable, Sendable, CaseIterable {
    case add, replace
}

/// What happens to the GPS position.
public enum LocationEdit: Codable, Equatable, Sendable {
    /// Left as it is.
    case keep
    /// GPS and IPTC/XMP place names removed.
    case remove
    /// The GPS position replaced (place names kept). Altitude in metres, negative below sea level.
    case set(latitude: Double, longitude: Double, altitude: Double?)

    /// Altitudes beyond this many metres are rejected (no camera is that far up or down).
    public static let maxAltitude = 100_000.0

    public static func isValid(latitude: Double, longitude: Double, altitude: Double?) -> Bool {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return false }
        guard let altitude else { return true }
        return altitude.isFinite && abs(altitude) <= maxAltitude
    }

    private enum CodingKeys: String, CodingKey { case mode, latitude, longitude, altitude }
    private enum Mode: String, Codable { case keep, remove, set }

    /// Throws for an unknown mode or an out-of-range position, so a tampered file is rejected.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .keep: self = .keep
        case .remove: self = .remove
        case .set:
            let latitude = try container.decode(Double.self, forKey: .latitude)
            let longitude = try container.decode(Double.self, forKey: .longitude)
            let altitude = try container.decodeIfPresent(Double.self, forKey: .altitude)
            guard Self.isValid(latitude: latitude, longitude: longitude, altitude: altitude) else {
                throw DecodingError.dataCorruptedError(forKey: .latitude, in: container,
                                                       debugDescription: "GPS position out of range")
            }
            self = .set(latitude: latitude, longitude: longitude, altitude: altitude)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keep: try container.encode(Mode.keep, forKey: .mode)
        case .remove: try container.encode(Mode.remove, forKey: .mode)
        case let .set(latitude, longitude, altitude):
            try container.encode(Mode.set, forKey: .mode)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encodeIfPresent(altitude, forKey: .altitude)
        }
    }
}

/// What happens to the date taken (EXIF, TIFF, IPTC and XMP dates).
public enum DateEdit: Codable, Equatable, Sendable {
    case keep
    /// Every date-taken field set to this moment, written as wall time in the file's own time zone
    /// (EXIF OffsetTimeOriginal) or, without one, the Mac's.
    case set(Date)
    /// Every date-taken field present moved by this many seconds; a file without a date keeps none.
    case shift(seconds: Int)

    /// Shifts are limited to ±200 years.
    public static let maxShift = 200 * 366 * 86_400

    private enum CodingKeys: String, CodingKey { case mode, date, seconds }
    private enum Mode: String, Codable { case keep, set, shift }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .keep: self = .keep
        case .set:
            let interval = try container.decode(Double.self, forKey: .date)
            // Years 1...9999 so the EXIF date format stays four digits.
            guard interval.isFinite, (-63_082_281_600...252_423_993_599).contains(interval) else {
                throw DecodingError.dataCorruptedError(forKey: .date, in: container, debugDescription: "Date out of range")
            }
            self = .set(Date(timeIntervalSinceReferenceDate: interval))
        case .shift:
            let seconds = try container.decode(Int.self, forKey: .seconds)
            guard abs(seconds) <= Self.maxShift else {
                throw DecodingError.dataCorruptedError(forKey: .seconds, in: container,
                                                       debugDescription: "Shift out of range")
            }
            self = .shift(seconds: seconds)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keep: try container.encode(Mode.keep, forKey: .mode)
        case .set(let date):
            try container.encode(Mode.set, forKey: .mode)
            try container.encode(date.timeIntervalSinceReferenceDate, forKey: .date)
        case .shift(let seconds):
            try container.encode(Mode.shift, forKey: .mode)
            try container.encode(seconds, forKey: .seconds)
        }
    }
}

/// Fields that survive "Remove all metadata" when ticked.
///
/// - copyright: EXIF/TIFF Copyright, IPTC CopyrightNotice, PNG Copyright, XMP dc:rights and xmpRights.
/// - author: EXIF/TIFF Artist, IPTC Byline, BylineTitle and Writer, PNG Author, XMP dc:creator,
///   photoshop:AuthorsPosition and photoshop:CaptionWriter.
/// - dateTaken: EXIF DateTimeOriginal/Digitized with their offsets and sub-seconds, TIFF DateTime,
///   IPTC DateCreated/TimeCreated, XMP xmp:CreateDate and photoshop:DateCreated.
/// - orientation: always applied to the pixels and written as 1 (upright), so nothing is lost either way.
/// - colorProfile: the profile is embedded from the image itself and is never stripped; ticking it changes nothing.
/// - cameraInfo: make, model, software, lens, serial numbers and exposure settings (EXIF/TIFF and {ExifAux});
///   opaque maker notes are not kept.
/// - location: GPS and IPTC/XMP place names.
public enum KeepField: String, Codable, Sendable, CaseIterable {
    case copyright, author, dateTaken, orientation, colorProfile, cameraInfo, location
}
