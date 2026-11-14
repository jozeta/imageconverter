import Foundation

public typealias MetadataTemplate = Template<MetadataOptions>
public typealias MetadataTemplateStore = TemplateStore<MetadataOptions>

extension Template where Payload == MetadataOptions {
    public init(id: UUID = UUID(), name: String, options: MetadataOptions, isBuiltIn: Bool = false) {
        self.init(id: id, name: name, payload: options, isBuiltIn: isBuiltIn)
    }

    public var options: MetadataOptions {
        get { payload }
        set { payload = newValue }
    }
}

extension TemplateStore where Payload == MetadataOptions {
    public static let folderName = "metadata-templates"

    /// A store for metadata templates with the built-ins; `directory` defaults to the app's folder.
    public static func metadata(directory: URL? = nil) -> MetadataTemplateStore {
        MetadataTemplateStore(directory: directory ?? defaultDirectory(folder: folderName),
                              builtIns: MetadataTemplates.builtIns, noun: "template")
    }
}

public enum MetadataTemplates {
    // swiftlint:disable force_unwrapping
    private static let privacyID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000D1")!
    private static let webID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000D2")!
    private static let everythingID = UUID(uuidString: "B1A5E000-0000-4000-8000-0000000000D3")!
    // swiftlint:enable force_unwrapping

    public static let builtIns: [MetadataTemplate] = {
        var privacy = MetadataOptions(isEnabled: true, isIncluded: true, removeLocation: true, removeCamera: true)
        privacy.removeAuthor = true
        var web = MetadataOptions(isEnabled: true, isIncluded: true, removeAll: true, removeLocation: false)
        web.keepWhenRemovingAll = [.copyright]
        let everything = MetadataOptions(isEnabled: true, isIncluded: true, removeAll: true, removeLocation: false)
        return [
            MetadataTemplate(id: privacyID, name: "Privacy (remove location, camera, author)",
                             options: privacy, isBuiltIn: true),
            MetadataTemplate(id: webID, name: "Web (remove all, keep copyright)", options: web, isBuiltIn: true),
            MetadataTemplate(id: everythingID, name: "Remove everything", options: everything, isBuiltIn: true)
        ]
    }()

    /// Applies a template on top of the current options. Per field, "the template sets it" means:
    /// - text (artist, copyright, description, title): non-nil overrides (an empty string clears);
    /// - location and date taken: anything but `.keep` overrides;
    /// - keywords: non-nil overrides together with its mode, except an empty list in add mode (adds nothing);
    /// - the removal and file-date switches: true turns them on, false never turns one off;
    /// - removeAll: true turns it on and the template's keep list replaces the current one; false leaves both;
    /// - custom fields: merged by namespace and key, the template's value wins.
    /// The step becomes included and enabled.
    public static func apply(_ template: MetadataTemplate, to current: MetadataOptions) -> MetadataOptions {
        let set = template.options
        var result = current
        result.isEnabled = true
        result.isIncluded = true
        if set.removeAll {
            result.removeAll = true
            result.keepWhenRemovingAll = set.keepWhenRemovingAll
        }
        if set.location != .keep { result.location = set.location }
        result.removeCamera = result.removeCamera || set.removeCamera
        result.removeAuthor = result.removeAuthor || set.removeAuthor
        result.removeThumbnail = result.removeThumbnail || set.removeThumbnail
        result.removeIPTC = result.removeIPTC || set.removeIPTC
        result.removeXMP = result.removeXMP || set.removeXMP
        result.setFileDates = result.setFileDates || set.setFileDates
        if let artist = set.artist { result.artist = artist }
        if let copyright = set.copyright { result.copyright = copyright }
        if let description = set.description { result.description = description }
        if let title = set.title { result.title = title }
        if let keywords = set.keywords, !(keywords.isEmpty && set.keywordsMode == .add) {
            result.keywords = keywords
            result.keywordsMode = set.keywordsMode
        }
        if set.dateTaken != .keep { result.dateTaken = set.dateTaken }
        for field in set.custom {
            if let index = result.custom.firstIndex(where: { $0.namespace == field.namespace && $0.key == field.key }) {
                result.custom[index] = field
            } else {
                result.custom.append(field)
            }
        }
        return result
    }
}
