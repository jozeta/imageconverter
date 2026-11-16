import AppIntents
import Foundation
import ImageconverterCore

// The Shortcuts actions that write images. Each is thin: the work is `IntentContext.convert` → `Automation.run`
// (Core). They run inside the app without showing its window (openAppWhenRun = false), never change the
// originals, and return the written files.

struct ConvertImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Images"
    static let description = IntentDescription(
        "Converts images with one of your imageconverter presets and returns the converted files. The originals are never changed.",
        categoryName: "Convert")
    static let openAppWhenRun = false

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @Parameter(title: "Format", description: "Leave empty to keep the preset's format.")
    var format: ImageFormatOption?

    @Parameter(title: "Output Folder",
               description: "Leave empty to only return the files. A folder must be allowed in imageconverter (Help ▸ Folder Access).",
               supportedTypeIdentifiers: ["public.folder"])
    var outputFolder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$images) with \(\.$preset)") {
            \.$format
            \.$outputFolder
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let chosen = try await IntentContext.preset(named: preset.id)
        let request = AutomationRequest.convert(preset: chosen, format: format?.format)
        return .result(value: try await IntentContext.convert(images, request: request, outputFolder: outputFolder))
    }
}

struct ApplyPresetToFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Preset to Folder"
    static let description = IntentDescription(
        "Converts the images in a folder (and subfolders) with a preset. The folder must be allowed in Help ▸ Folder Access.",
        categoryName: "Convert")
    static let openAppWhenRun = false

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @Parameter(title: "Output Folder",
               description: "Leave empty to only return the files. A folder must be allowed in imageconverter (Help ▸ Folder Access).",
               supportedTypeIdentifiers: ["public.folder"])
    var outputFolder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$preset) to \(\.$folder)") {
            \.$outputFolder
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let chosen = try await IntentContext.preset(named: preset.id)
        let (url, grant) = try IntentContext.checkedInputFolder(folder)
        defer { grant.release() }
        let request = AutomationRequest.convert(preset: chosen, format: nil)
        let input = IntentFile(fileURL: url, filename: url.lastPathComponent)
        return .result(value: try await IntentContext.convert([input], request: request, outputFolder: outputFolder))
    }
}

struct StripMetadataIntent: AppIntent {
    static let title: LocalizedStringResource = "Strip Metadata"
    static let description = IntentDescription(
        "Returns copies of the images without any metadata (location, camera, dates, descriptions), each in its own format.",
        categoryName: "Metadata")
    static let openAppWhenRun = false

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]

    @Parameter(title: "Output Folder",
               description: "Leave empty to only return the files. A folder must be allowed in imageconverter (Help ▸ Folder Access).",
               supportedTypeIdentifiers: ["public.folder"])
    var outputFolder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Strip metadata from \(\.$images)") {
            \.$outputFolder
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await IntentContext.convert(images, request: .stripMetadata(), outputFolder: outputFolder))
    }
}

struct ResizeImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Resize Images"
    static let description = IntentDescription(
        "Returns copies of the images with their longest edge at the given size in pixels. Each keeps its format.",
        categoryName: "Convert")
    static let openAppWhenRun = false

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]

    @Parameter(title: "Long Edge (pixels)", default: 2048, inclusiveRange: (1, 100_000))
    var longEdge: Int

    @Parameter(title: "Output Folder",
               description: "Leave empty to only return the files. A folder must be allowed in imageconverter (Help ▸ Folder Access).",
               supportedTypeIdentifiers: ["public.folder"])
    var outputFolder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Resize \(\.$images) to \(\.$longEdge) pixels") {
            \.$outputFolder
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let request: AutomationRequest
        do { request = try .resize(longEdge: longEdge) } catch { throw IntentFailure(error) }
        return .result(value: try await IntentContext.convert(images, request: request, outputFolder: outputFolder))
    }
}

struct ConvertFormatIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Format"
    static let description = IntentDescription(
        "Returns copies of the images in another format. Quality (1–100) applies to JPEG, HEIC, AVIF and JPEG 2000.",
        categoryName: "Convert")
    static let openAppWhenRun = false

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormatOption

    @Parameter(title: "Quality", description: "1–100; leave empty for the default (82).", inclusiveRange: (1, 100))
    var quality: Int?

    @Parameter(title: "Output Folder",
               description: "Leave empty to only return the files. A folder must be allowed in imageconverter (Help ▸ Folder Access).",
               supportedTypeIdentifiers: ["public.folder"])
    var outputFolder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$images) to \(\.$format)") {
            \.$quality
            \.$outputFolder
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let request: AutomationRequest
        do { request = try .convertFormat(format.format, qualityPercent: quality) } catch { throw IntentFailure(error) }
        return .result(value: try await IntentContext.convert(images, request: request, outputFolder: outputFolder))
    }
}
