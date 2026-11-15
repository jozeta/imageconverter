import Foundation
import ImageconverterCore

extension CLIParser {
    /// The keys `--variant` takes, for the error message.
    static let variantKeys = "name, format, quality, max-size, long, width, height, percent, suffix, folder"

    /// One `--variant "name=thumb,format=jpeg,quality=70,long=400,suffix=_thumb"`: comma-separated `key=value`
    /// pairs. The format defaults to JPEG and the suffix to `_<name>`; at most one of long, width, height and
    /// percent (none keeps the pipeline's size). `position` numbers the variant, so its id is stable.
    static func variant(_ text: String, position: Int) throws -> OutputVariant {
        let fields = try variantFields(text)
        let (settings, resize) = try variantOutput(fields)
        let name = fields["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let suffix = fields["suffix"] ?? (name.isEmpty ? nil : "_\(name)") else {
            throw CLIUsageError("--variant needs suffix=… (or a name=… to make one from).")
        }
        let folder = fields["folder"].flatMap { SubfolderTemplate.isBlank($0) ? nil : $0 }
        return OutputVariant(id: stableID(position), name: String(name.prefix(OutputVariant.maxNameLength)),
                             settings: settings, resize: resize, nameSuffix: suffix, subfolder: folder)
    }

    /// The `key=value` pairs, keys lower-cased; each key at most once.
    private static func variantFields(_ text: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        for pair in text.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard parts.count == 2, !key.isEmpty else {
                throw CLIUsageError("--variant takes key=value pairs separated by commas (\(variantKeys)).")
            }
            guard fields.updateValue(parts[1], forKey: key) == nil else {
                throw CLIUsageError("--variant: '\(key)' was given more than once.")
            }
        }
        return fields
    }

    /// The format, quality and size keys.
    private static func variantOutput(_ fields: [String: String]) throws -> (OutputSettings, VariantResize?) {
        var settings = OutputSettings()
        var resize: VariantResize?
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "name", "suffix", "folder": continue
            case "format": settings.format = try format(value)
            case "quality": settings.quality = try quality(value)
            case "max-size": settings.compression = .maxSize(bytes: try maxSize(value))
            case "long", "width", "height", "percent":
                guard resize == nil else {
                    throw CLIUsageError("--variant takes only one of long, width, height and percent.")
                }
                resize = try variantResize(key, value)
            default:
                throw CLIUsageError("--variant: unknown key '\(key)'. Use \(variantKeys).")
            }
        }
        return (settings, resize)
    }

    private static func variantResize(_ key: String, _ value: String) throws -> VariantResize {
        if key == "percent" {
            guard let number = Double(value), VariantResize.percentRange.contains(number) else {
                throw CLIUsageError("--variant: percent must be a number from 1 to 1000.")
            }
            return .percent(number)
        }
        guard let pixels = Int(value), VariantResize.pixelRange.contains(pixels) else {
            throw CLIUsageError("--variant: \(key) must be a whole number of pixels from 1 to \(maxResizeEdge).")
        }
        switch key {
        case "width": return .maxWidth(pixels)
        case "height": return .maxHeight(pixels)
        default: return .longestEdge(pixels)
        }
    }

    /// The variants together: every suffix set and different, at most `OutputVariant.maxCount`.
    static func validateVariants(_ variants: [OutputVariant]) throws {
        guard variants.count <= OutputVariant.maxCount else {
            throw CLIUsageError("At most \(OutputVariant.maxCount) --variant outputs.")
        }
        let problems = OutputVariant.problems(in: variants)
        guard let first = variants.first(where: { problems[$0.id] != nil }), let problem = problems[first.id] else {
            return
        }
        let label = first.cleanSuffix.isEmpty ? "--variant" : "--variant with suffix '\(first.cleanSuffix)'"
        throw CLIUsageError("\(label): \(problem.prefix(1).lowercased() + problem.dropFirst()).")
    }

    private static func stableID(_ position: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", position + 1)) ?? UUID()
    }
}
