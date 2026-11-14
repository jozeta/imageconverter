import ImageconverterCore

/// The kinds of condition, as the grouped kind picker lists them.
enum ConditionKind: String, CaseIterable {
    case fileName, fileExtension, folder
    case dateTaken, dateCreated, dateModified
    case metadataField, camera, location
    case longestEdge, width, height, megapixels, aspectRatio, orientation, fileSize, format, transparency
    case bitDepth, colorSpace, colorProfile, dpi, rotated, animated

    enum Group: CaseIterable {
        case nameAndLocation, dates, metadata, image

        var title: String {
            switch self {
            case .nameAndLocation: return "Name & location"
            case .dates: return "Dates"
            case .metadata: return "Metadata"
            case .image: return "Image"
            }
        }

        var kinds: [ConditionKind] {
            switch self {
            case .nameAndLocation: return [.fileName, .fileExtension, .folder]
            case .dates: return [.dateTaken, .dateCreated, .dateModified]
            case .metadata: return [.metadataField, .camera, .location]
            case .image:
                return [.longestEdge, .width, .height, .megapixels, .aspectRatio, .orientation, .fileSize, .format,
                        .transparency, .bitDepth, .colorSpace, .colorProfile, .dpi, .rotated, .animated]
            }
        }
    }

    // One case per check.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ check: ConditionCheck) {
        switch check {
        case .longestEdge: self = .longestEdge
        case .width: self = .width
        case .height: self = .height
        case .fileSize: self = .fileSize
        case .format: self = .format
        case .hasTransparency: self = .transparency
        case .orientation: self = .orientation
        case .hasGPS: self = .location
        case .camera: self = .camera
        case .name: self = .fileName
        case .fileExtension: self = .fileExtension
        case .folder: self = .folder
        case .date(.taken, _): self = .dateTaken
        case .date(.created, _): self = .dateCreated
        case .date(.modified, _): self = .dateModified
        case .metadata: self = .metadataField
        default: self = Self.imageKind(check)
        }
    }

    private static func imageKind(_ check: ConditionCheck) -> ConditionKind {
        switch check {
        case .megapixels: return .megapixels
        case .aspectRatio: return .aspectRatio
        case .bitDepth: return .bitDepth
        case .colorSpace: return .colorSpace
        case .hasProfile: return .colorProfile
        case .dpi: return .dpi
        case .isRotated: return .rotated
        case .isAnimated: return .animated
        default: return .longestEdge
        }
    }

    var displayName: String {
        switch self {
        case .fileName: return "File name"
        case .fileExtension: return "Extension"
        case .folder: return "Folder path"
        case .dateTaken: return "Date taken"
        case .dateCreated: return "File created"
        case .dateModified: return "File modified"
        case .metadataField: return "Metadata field"
        case .camera: return "Camera"
        case .location: return "Location"
        default: return imageName
        }
    }

    private var imageName: String {
        switch self {
        case .longestEdge: return "Longest edge"
        case .width: return "Width"
        case .height: return "Height"
        case .megapixels: return "Megapixels"
        case .aspectRatio: return "Aspect ratio"
        case .orientation: return "Orientation"
        case .fileSize: return "File size"
        case .format: return "Format"
        case .transparency: return "Transparency"
        case .bitDepth: return "Bit depth"
        case .colorSpace: return "Color space"
        case .colorProfile: return "Color profile"
        case .dpi: return "DPI"
        case .rotated: return "Rotated (EXIF)"
        case .animated: return "Animated / pages"
        default: return ""
        }
    }

    var defaultCheck: ConditionCheck {
        switch self {
        case .fileName: return .name(TextMatch(.contains, "IMG"))
        case .fileExtension: return .fileExtension(["jpg"])
        case .folder: return .folder(contains: "Holiday")
        case .dateTaken: return .date(.taken, .withinLastDays(30))
        case .dateCreated: return .date(.created, .withinLastDays(30))
        case .dateModified: return .date(.modified, .withinLastDays(30))
        case .metadataField: return .metadata(MetadataTest(.named(.copyright), .missing))
        case .camera: return .camera(contains: "iPhone")
        case .location: return .hasGPS(true)
        case .longestEdge: return .longestEdge(.greaterThan, 2048)
        case .width: return .width(.greaterThan, 2048)
        case .height: return .height(.greaterThan, 2048)
        case .megapixels: return .megapixels(.greaterThan, 12)
        case .aspectRatio: return .aspectRatio(.widerThan(1.5))
        case .orientation: return .orientation(.portrait)
        case .fileSize: return .fileSize(.greaterThan, bytes: 5_000_000)
        case .format: return .format(.format(.png))
        case .transparency: return .hasTransparency(true)
        default: return imageDefault
        }
    }

    private var imageDefault: ConditionCheck {
        switch self {
        case .bitDepth: return .bitDepth(.sixteen)
        case .colorSpace: return .colorSpace(.displayP3)
        case .colorProfile: return .hasProfile
        case .dpi: return .dpi(.atLeast, 300)
        case .rotated: return .isRotated
        case .animated: return .isAnimated
        default: return .longestEdge(.greaterThan, 2048)
        }
    }

    /// The check of this kind, keeping the comparison and number between pixel kinds and the rule between
    /// date kinds.
    func converted(from old: ConditionCheck) -> ConditionCheck {
        switch (self, old) {
        case (.longestEdge, .width(let comparison, let value)), (.longestEdge, .height(let comparison, let value)):
            return .longestEdge(comparison, value)
        case (.width, .longestEdge(let comparison, let value)), (.width, .height(let comparison, let value)):
            return .width(comparison, value)
        case (.height, .longestEdge(let comparison, let value)), (.height, .width(let comparison, let value)):
            return .height(comparison, value)
        case (.dateTaken, .date(_, let rule)): return .date(.taken, rule)
        case (.dateCreated, .date(_, let rule)): return .date(.created, rule)
        case (.dateModified, .date(_, let rule)): return .date(.modified, rule)
        default: return defaultCheck
        }
    }
}
