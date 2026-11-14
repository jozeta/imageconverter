import Foundation

public typealias WatermarkTemplate = Template<WatermarkOptions>
public typealias WatermarkTemplateStore = TemplateStore<WatermarkOptions>

extension Template where Payload == WatermarkOptions {
    public init(id: UUID = UUID(), name: String, options: WatermarkOptions, isBuiltIn: Bool = false) {
        self.init(id: id, name: name, payload: options, isBuiltIn: isBuiltIn)
    }

    public var options: WatermarkOptions {
        get { payload }
        set { payload = newValue }
    }
}

extension TemplateStore where Payload == WatermarkOptions {
    public static let watermarkFolderName = "watermark-templates"

    /// A store for watermark templates with the built-ins; `directory` defaults to the app's folder. Image
    /// watermarks are stored as plain paths, like presets.
    public static func watermark(directory: URL? = nil) -> WatermarkTemplateStore {
        WatermarkTemplateStore(directory: directory ?? defaultDirectory(folder: watermarkFolderName),
                               builtIns: WatermarkTemplates.builtIns, noun: "template")
    }
}

public enum WatermarkTemplates {
    // swiftlint:disable force_unwrapping
    private static let cornerID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000E1")!
    private static let tiledID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000E2")!
    private static let filenameID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000E3")!
    // swiftlint:enable force_unwrapping

    public static let builtIns: [WatermarkTemplate] = {
        let corner = WatermarkOptions(content: .text(TextWatermark(text: "© {year} {artist}")), anchor: .bottomRight,
                                      sizePercent: 4, opacity: WatermarkOptions.defaultOpacity, marginPercent: 3)
        let tiled = WatermarkOptions(content: .text(TextWatermark(text: "© {artist}")), anchor: .center,
                                     sizePercent: 5, opacity: 0.15, marginPercent: 0, rotation: -30,
                                     layout: .tiled(spacing: 100, stagger: true))
        let filename = WatermarkOptions(
            content: .text(TextWatermark(text: "{filename} · {date}", shadow: WatermarkShadow())),
            anchor: .bottomLeft, sizePercent: 3, opacity: 0.9, marginPercent: 3)
        return [
            WatermarkTemplate(id: cornerID, name: "© corner (bottom right, 4 %)", options: corner, isBuiltIn: true),
            WatermarkTemplate(id: tiledID, name: "Tiled diagonal (30°, 15 % opacity)", options: tiled, isBuiltIn: true),
            WatermarkTemplate(id: filenameID, name: "Filename + date (bottom left)", options: filename, isBuiltIn: true)
        ]
    }()
}
