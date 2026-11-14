import Foundation

/// Reads a pipeline from a JSON file the user points at (the command line's `--pipeline`). The file is untrusted:
/// it is opened without following links, capped at 1 MB and must be a pipeline or a preset file.
public enum PipelineFile {
    private struct Wrapper: Decodable {
        let schemaVersion: Int?
        let pipeline: Pipeline?
    }

    private struct Keys: Decodable {
        let hasKey: Bool
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            hasKey = ["pipeline", "steps", "output", "metadata", "rename"]
                .contains { name in AnyKey(stringValue: name).map(container.contains) ?? false }
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public static func load(_ url: URL) throws -> Pipeline {
        let data = try StoredFile.readData(url)
        let decoder = JSONDecoder()
        let keys: Keys
        do { keys = try decoder.decode(Keys.self, from: data) } catch { throw StoredFile.decodeError(error) }
        guard keys.hasKey else { throw PresetError.invalidStructure }
        do {
            let wrapper = try decoder.decode(Wrapper.self, from: data)
            if let pipeline = wrapper.pipeline {
                guard (wrapper.schemaVersion ?? 1) <= Preset.schemaVersion else {
                    throw PresetError.unsupportedVersion(wrapper.schemaVersion ?? 1)
                }
                return pipeline
            }
            return try decoder.decode(Pipeline.self, from: data)
        } catch let error as PresetError {
            throw error
        } catch {
            throw StoredFile.decodeError(error)
        }
    }
}
