import Foundation
import ImageconverterCore

extension CLIParser {
    /// The keys `--variant` takes, for the error message.
    static let variantKeys = "name, format, quality, max-size, long, width, height, percent, suffix, folder"

    /// One `--variant "name=thumb,format=jpeg,quality=70,long=400,suffix=_thumb"`: comma-separated `key=value`
    /// pairs. The format defaults to JPEG and the suffix to `_<name>`; at most one of long, width, height and
    /// percent (none keeps the pipeline's size). `folder=` with an absolute path (or `~/…`) is the output's own
    /// folder; a relative one is a subfolder (template) under the main output's folder, as before. `position`
    /// numbers the variant, so its id is stable.
    static func variant(_ text: String, position: Int) throws -> OutputVariant {
        let fields = try variantFields(text)
        let (settings, resize) = try variantOutput(fields)
        let name = fields["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let suffix = fields["suffix"] ?? (name.isEmpty ? nil : "_\(name)") else {
            throw CLIUsageError("--variant needs suffix=… (or a name=… to make one from).")
        }
        let (folder, destination) = try variantFolder(fields["folder"])
        return OutputVariant(id: stableID(position), name: String(name.prefix(OutputVariant.maxNameLength)),
                             settings: settings, resize: resize, nameSuffix: suffix, subfolder: folder,
                             destination: destination)
    }

    /// `folder=`: an absolute path (or `~/…`) is a destination folder, anything else a subfolder template.
    private static func variantFolder(_ value: String?) throws -> (subfolder: String?, destination: OutputDestination?) {
        guard let value, !SubfolderTemplate.isBlank(value) else { return (nil, nil) }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return (value, nil) }
        let path = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        guard VariantFolder.isUsablePath(path), path.hasPrefix("/") else {
            throw CLIUsageError("--variant: folder must be a folder path.")
        }
        return (nil, .folder(VariantFolder(path: path)))
    }

    /// The `key=value` pairs, keys lower-cased; each key at most once.
    private static func variantFields(_ text: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        for pair in try variantPairs(text) {
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

    /// Splits on commas, except a comma written `\,` or inside a double-quoted value (`folder="/a,b"`), which is
    /// part of the value. The quotes themselves are dropped; `\"` and `\\` give a quote or a backslash, and any
    /// other backslash stays as it is. An unclosed quote is a usage error.
    static func variantPairs(_ text: String) throws -> [String] {
        var pairs: [String] = []
        var current = ""
        var quoted = false
        var chars = text.makeIterator()
        while let char = chars.next() {
            switch char {
            case "\\":
                guard let next = chars.next() else { current.append(char); break }
                if next == "," || next == "\"" || next == "\\" { current.append(next) } else { current.append(char); current.append(next) }
            case "\"" where quoted || current.hasSuffix("="): quoted.toggle()
            case "," where !quoted:
                if !current.isEmpty { pairs.append(current) }
                current = ""
            default: current.append(char)
            }
        }
        guard !quoted else { throw CLIUsageError("--variant: a quoted value is missing its closing \".") }
        if !current.isEmpty { pairs.append(current) }
        return pairs
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
