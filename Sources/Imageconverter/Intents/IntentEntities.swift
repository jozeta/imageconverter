import AppIntents
import Foundation
import ImageconverterCore

/// A preset, by name (like AppleScript, links and the command line): renaming a preset means choosing it again
/// in the shortcut, and a preset that is gone fails the action with "There is no preset named …".
struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Preset")
    static let defaultQuery = PresetQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct PresetQuery: EntityStringQuery {
    /// Every name is given back, also one that no longer exists, so the action itself can say what is missing.
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        identifiers.map(PresetEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [PresetEntity] {
        let wanted = string.trimmingCharacters(in: .whitespaces)
        return try await suggestedEntities().filter {
            wanted.isEmpty || $0.id.localizedCaseInsensitiveContains(wanted)
        }
    }

    /// The built-in and saved presets, from the presets folder.
    func suggestedEntities() async throws -> [PresetEntity] {
        await IntentContext.presets().map { PresetEntity(id: $0.name) }
    }
}

/// A saved job, by name (like `imageconverter jobs run` and `imageconverter://jobs/run?name=`).
struct JobEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Job")
    static let defaultQuery = JobQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct JobQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [JobEntity] {
        identifiers.map(JobEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [JobEntity] {
        let wanted = string.trimmingCharacters(in: .whitespaces)
        return try await suggestedEntities().filter {
            wanted.isEmpty || $0.id.localizedCaseInsensitiveContains(wanted)
        }
    }

    func suggestedEntities() async throws -> [JobEntity] {
        await IntentContext.jobs().map { JobEntity(id: $0.name) }
    }
}

/// The formats an action can write (whether this Mac can write AVIF or JPEG 2000 is checked when it runs).
enum ImageFormatOption: String, AppEnum {
    case jpeg, png, heic, tiff, gif, bmp, jpeg2000, avif

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Image Format")
    static let caseDisplayRepresentations: [ImageFormatOption: DisplayRepresentation] = [
        .jpeg: "JPEG", .png: "PNG", .heic: "HEIC", .tiff: "TIFF", .gif: "GIF", .bmp: "BMP",
        .jpeg2000: "JPEG 2000", .avif: "AVIF",
    ]

    var format: OutputFormat {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        case .jpeg2000: return .jpeg2000
        case .avif: return .avif
        }
    }
}
