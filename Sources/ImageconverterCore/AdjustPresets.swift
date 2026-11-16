import Foundation

public typealias AdjustPreset = Template<AdjustOptions>
public typealias AdjustPresetStore = TemplateStore<AdjustOptions>

extension Template where Payload == AdjustOptions {
    public init(id: UUID = UUID(), name: String, options: AdjustOptions, isBuiltIn: Bool = false) {
        self.init(id: id, name: name, payload: options, isBuiltIn: isBuiltIn)
    }

    public var options: AdjustOptions {
        get { payload }
        set { payload = newValue }
    }
}

extension TemplateStore where Payload == AdjustOptions {
    public static let adjustFolderName = "adjust-presets"

    /// A store for Adjust presets with the built-in looks; `directory` defaults to the app's folder.
    public static func adjust(directory: URL? = nil) -> AdjustPresetStore {
        AdjustPresetStore(directory: directory ?? defaultDirectory(folder: adjustFolderName),
                          builtIns: AdjustPresets.builtIns, noun: "preset")
    }
}

/// The built-in Adjust looks: fixed sets of the Adjust sliders (documented in the README). Applying one replaces
/// every Adjust value; the step stays editable afterwards.
public enum AdjustPresets {
    /// Stable IDs, so a built-in is never mistaken for a saved preset.
    private static func id(_ index: Int) -> UUID {
        // swiftlint:disable:next force_unwrapping
        UUID(uuidString: String(format: "AD1057E0-0000-4000-8000-%012X", index))!
    }

    private static let looks: [(name: String, options: AdjustOptions)] = [
        ("Vivid", AdjustOptions(contrast: 10, saturation: 20, vibrance: 30)),
        // The warm looks: strong warmth with a little magenta and less vibrance, which on skies and grass would
        // pull the image back to blue and green (AdjustWarmLooksTests measures them on the sample photos).
        ("Vivid Warm", AdjustOptions(contrast: 10, saturation: 5, vibrance: 15, warmth: 70, tint: 10)),
        ("Vivid Cool", AdjustOptions(contrast: 10, saturation: 15, vibrance: 30, warmth: -30, tint: -2)),
        ("Dramatic", AdjustOptions(highlights: -30, shadows: -15, contrast: 30, blackPoint: 10, saturation: -20,
                                   definition: 25)),
        ("Dramatic Warm", AdjustOptions(highlights: -30, shadows: -15, contrast: 30, blackPoint: 10,
                                        saturation: -15, warmth: 70, tint: 10, definition: 25)),
        ("Dramatic Cool", AdjustOptions(highlights: -30, shadows: -15, contrast: 30, blackPoint: 10,
                                        saturation: -10, warmth: -35, definition: 25)),
        ("Mono", AdjustOptions(contrast: 10, saturation: -100)),
        ("Silvertone", AdjustOptions(brilliance: 20, highlights: 20, contrast: -10, blackPoint: -15,
                                     saturation: -100, warmth: -8)),
        ("Noir", AdjustOptions(highlights: 15, shadows: -25, contrast: 45, blackPoint: 25, saturation: -100,
                               definition: 20)),
        ("Fade", AdjustOptions(highlights: -10, contrast: -20, blackPoint: -35, saturation: -20)),
        ("Film", AdjustOptions(highlights: -15, shadows: 10, contrast: 10, blackPoint: -20, saturation: -10,
                               warmth: 12, tint: 5, sharpness: -10)),
        ("Golden Hour", AdjustOptions(exposure: 5, highlights: -20, shadows: 15, vibrance: 10, warmth: 100,
                                      tint: 15)),
        ("Cool Breeze", AdjustOptions(exposure: 5, contrast: -5, brightness: 5, vibrance: 10, warmth: -35,
                                      tint: -4)),
        ("Matte", AdjustOptions(brilliance: 10, highlights: -25, shadows: 10, contrast: -15, blackPoint: -30,
                                saturation: -5)),
        ("Punch", AdjustOptions(contrast: 25, blackPoint: 5, saturation: 10, vibrance: 40, sharpness: 30,
                                definition: 30)),
        ("Soft Portrait", AdjustOptions(brilliance: 15, highlights: -15, shadows: 15, contrast: -10,
                                        vibrance: -5, warmth: 10, tint: 5, sharpness: -25))
    ]

    public static let builtIns: [AdjustPreset] = looks.enumerated().map { index, look in
        AdjustPreset(id: id(index + 1), name: look.name, options: look.options, isBuiltIn: true)
    }

    /// A new, saved-kind copy of `preset` named "<name> copy" (or "copy 2", "copy 3", …), unique among
    /// `existing` (case-insensitive) and within the name length limit.
    public static func duplicate(_ preset: AdjustPreset, existing: [AdjustPreset]) -> AdjustPreset {
        let taken = Set(existing.map { StoredFile.fold($0.name) })
        var number = 1
        while true {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let base = String(preset.name.prefix(AdjustPresetStore.maxNameLength - suffix.count))
                .trimmingCharacters(in: .whitespaces)
            let name = base + suffix
            if !taken.contains(StoredFile.fold(name)) {
                return AdjustPreset(name: name, options: preset.options)
            }
            number += 1
        }
    }
}
