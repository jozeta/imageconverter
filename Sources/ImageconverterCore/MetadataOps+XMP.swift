import Foundation
import ImageIO

/// The XMP to write with an image; carried in the output properties under `MetadataOps.xmpPropertyKey`
/// and taken out again by `ImageEncoder`, which then writes it with `CGImageDestinationAddImageAndMetadata`.
public struct OutputXMP: @unchecked Sendable {
    public let metadata: CGImageMetadata
}

extension MetadataOps {
    /// Not an ImageIO key: `ImageEncoder` removes it before writing.
    public static let xmpPropertyKey = "ImageconverterOutputXMP"

    /// EXIF/TIFF mirrors in ImageIO's metadata view. They are written from the property dictionary, so
    /// copying them as XMP would only bring back what the dictionary stripped.
    private static let mirroredNamespaces: Set<String> = Set([
        kCGImageMetadataNamespaceExif, kCGImageMetadataNamespaceExifAux, kCGImageMetadataNamespaceExifEX,
        kCGImageMetadataNamespaceTIFF, "http://ns.apple.com/ImageIO/1.0/" as CFString
    ].map { $0 as String })

    private static let locationPaths: Set<String> = [
        "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
        "Iptc4xmpExt:LocationShown", "Iptc4xmpExt:LocationCreated",
    ]
    private static let authorPaths: Set<String> = ["dc:creator", "photoshop:AuthorsPosition", "photoshop:CaptionWriter",
                                                   "Iptc4xmpCore:CreatorContactInfo"]
    /// Language alternatives in XMP (written as rdf:Alt with an x-default entry).
    private static let altTextPaths = ["dc:title", "dc:description", "dc:rights", "xmpRights:UsageTerms",
                                       accessibilityAltTextPath]
    /// IPTC Photo Metadata 2021's "Alt Text (Accessibility)", a language alternative.
    static let accessibilityAltTextPath = "Iptc4xmpCore:AltTextAccessibility"
    /// Lightroom/Camera Raw settings name the lens and camera profile.
    private static let cameraRawNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"
    /// The IPTC Core fields that live in Dublin Core.
    private static let iptcDublinCorePaths: Set<String> = ["dc:title", "dc:creator", "dc:description", "dc:subject",
                                                           "dc:rights"]
    private static let iptcNamespaces: Set<String> = Set([
        kCGImageMetadataNamespacePhotoshop, kCGImageMetadataNamespaceIPTCCore, kCGImageMetadataNamespaceIPTCExtension
    ].map { $0 as String })
    /// Tag names that identify the camera in any namespace (vendor schemas included).
    private static let cameraNames: Set<String> = [
        "make", "model", "lens", "lensmodel", "lensid", "lensinfo", "lensserialnumber", "serialnumber",
        "cameraserialnumber", "bodyserialnumber", "creatortool", "cameramodelname",
    ]

    private static let namespaces: [String: CFString] = [
        "dc": kCGImageMetadataNamespaceDublinCore, "photoshop": kCGImageMetadataNamespacePhotoshop,
        "xmpRights": kCGImageMetadataNamespaceXMPRights, "Iptc4xmpCore": kCGImageMetadataNamespaceIPTCCore,
        "xmp": kCGImageMetadataNamespaceXMPBasic,
    ]

    /// The properties to write: `apply` plus, unless XMP is removed, the XMP built by `xmp(...)`.
    /// An inactive step leaves `properties` untouched (and writes no source XMP, as before).
    public static func output(_ options: MetadataOptions, properties: [String: Any],
                              metadata: CGImageMetadata?) -> [String: Any] {
        guard options.isActive else { return properties }
        let properties = MetadataDates.restoringTIFFDate(properties, from: metadata)
        var props = apply(options, to: properties, metadata: metadata)
        if !options.removeXMP {
            let xmp = xmp(options, source: metadata, original: properties, final: props)
            props[xmpPropertyKey] = OutputXMP(metadata: xmp)
        }
        return props
    }

    /// The source's XMP with the same removals as the property dictionary, then the edits. IPTC fields that
    /// changed are mirrored so formats that keep IPTC inside XMP (HEIC) and readers that prefer XMP agree.
    static func xmp(_ options: MetadataOptions, source: CGImageMetadata?, original: [String: Any],
                    final props: [String: Any]) -> CGMutableImageMetadata {
        let meta = source.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        for (prefix, namespace) in namespaces {
            CGImageMetadataRegisterNamespaceForPrefix(meta, namespace, prefix as CFString, nil)
        }
        removeTags(in: meta) { namespace, _, _ in mirroredNamespaces.contains(namespace) }
        if options.removeAll {
            let keep = options.keepWhenRemovingAll
            removeTags(in: meta) { namespace, path, name in !isKept(path: path, namespace: namespace, name: name, keep) }
        } else {
            strip(options, in: meta)
        }
        removeMirrors(ofRemovedIPTCIn: original, final: props, from: meta)
        syncIPTC(original: original, final: props, into: meta)
        // Before the edits, which write alternatives themselves.
        normalizeAltText(in: meta)
        setFields(options, final: props, in: meta)
        return meta
    }

    /// Camera and lens identifiers: well-known names in any namespace, Camera Raw's lens/camera settings and
    /// Photoshop's camera profile list.
    private static func isCameraTag(namespace: String, path: String, name: String) -> Bool {
        let lower = name.lowercased()
        if cameraNames.contains(lower) || lower.contains("serialnumber") || path == "photoshop:CameraProfiles" {
            return true
        }
        return namespace == cameraRawNamespace && (lower.contains("lens") || lower.contains("camera"))
    }

    private static func isKept(path: String, namespace: String, name: String, _ keep: Set<KeepField>) -> Bool {
        (keep.contains(.copyright) && (path == "dc:rights" || namespace == kCGImageMetadataNamespaceXMPRights as String))
            || (keep.contains(.author) && authorPaths.contains(path))
            || (keep.contains(.dateTaken) && MetadataDates.xmpPaths.contains(path))
            || (keep.contains(.location) && (locationPaths.contains(path) || isGPSName(name)))
            || (keep.contains(.cameraInfo) && isCameraTag(namespace: namespace, path: path, name: name))
    }

    static func isGPSName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["gps", "latitude", "longitude", "altitude"].contains { lower.contains($0) }
    }

    /// The top-level XMP tags ("prefix:name") whose struct or array value holds a GPS coordinate, e.g. IPTC
    /// Extension's LocationCreated/LocationShown with exif:GPSLatitude inside (Lightroom, Photo Mechanic).
    static func pathsHoldingGPS(in meta: CGImageMetadata?) -> [String] {
        guard let meta, let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return [] }
        return tags.compactMap { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?, holdsGPS(tag) else { return nil }
            return "\(prefix):\(name)"
        }.sorted()
    }

    /// Removes every top-level tag `pathsHoldingGPS` finds.
    static func removeTagsHoldingGPS(from meta: CGMutableImageMetadata) {
        for path in pathsHoldingGPS(in: meta) { CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) }
    }

    /// Whether a struct or array value has a GPS field at any depth (at most 8 levels: the XMP is untrusted).
    private static func holdsGPS(_ tag: CGImageMetadataTag, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        switch CGImageMetadataTagCopyValue(tag) {
        case let items as [CGImageMetadataTag]:
            return items.contains { holdsGPS($0, depth: depth + 1) }
        case let fields as [String: CGImageMetadataTag]:
            return fields.contains { isGPSName($0.key) || holdsGPS($0.value, depth: depth + 1) }
        default:
            return false
        }
    }

    private static func strip(_ options: MetadataOptions, in meta: CGMutableImageMetadata) {
        switch options.location {
        case .keep: break
        case .remove:
            removeTags(in: meta) { _, path, name in locationPaths.contains(path) || isGPSName(name) }
            removeTagsHoldingGPS(from: meta)
        case .set:
            let places = options.removePlaceNames
            removeTags(in: meta) { _, path, name in isGPSName(name) || places && locationPaths.contains(path) }
            // The old coordinates inside a location structure go too (its place names with them).
            removeTagsHoldingGPS(from: meta)
        }
        if options.removeCamera {
            removeTags(in: meta) { namespace, path, name in isCameraTag(namespace: namespace, path: path, name: name) }
        }
        if options.removeAuthor { removeTags(in: meta) { _, path, _ in authorPaths.contains(path) } }
        if options.removeIPTC {
            removeTags(in: meta) { namespace, path, _ in
                iptcNamespaces.contains(namespace) || iptcDublinCorePaths.contains(path)
            }
        }
    }

    /// Removes the top-level tags `predicate(namespace, path, name)` picks.
    private static func removeTags(in meta: CGMutableImageMetadata,
                                   where predicate: (String, String, String) -> Bool) {
        let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] ?? []
        let paths = tags.compactMap { tag -> String? in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let path = "\(prefix):\(name)"
            return predicate(namespace, path, name) ? path : nil
        }
        for path in paths { CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) }
    }

    private static func iptc(_ props: [String: Any]) -> [String: Any] {
        props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
    }

    /// An IPTC field that the dictionary lost (by any rule) also loses its XMP twin.
    private static func removeMirrors(ofRemovedIPTCIn original: [String: Any], final props: [String: Any],
                                      from meta: CGMutableImageMetadata) {
        let kept = iptc(props)
        for key in iptc(original).keys where kept[key] == nil {
            guard let tag = CGImageMetadataCopyTagMatchingImageProperty(
                meta, kCGImagePropertyIPTCDictionary, key as CFString) else { continue }
            removePath(of: tag, from: meta)
        }
    }

    private static func removePath(of tag: CGImageMetadataTag, from meta: CGMutableImageMetadata) {
        guard let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) else { return }
        CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix):\(name)" as CFString)
    }

    /// Writes the XMP twin of every IPTC field that is new or changed (dates are handled with the other dates).
    private static func syncIPTC(original: [String: Any], final props: [String: Any], into meta: CGMutableImageMetadata) {
        let before = iptc(original)
        let skipped = Set(MetadataDates.iptcDateFamily)
        for (key, value) in iptc(props) where !skipped.contains(key) {
            let unchanged = before[key].map { ($0 as AnyObject).isEqual(value) } ?? false
            let present = CGImageMetadataCopyTagMatchingImageProperty(
                meta, kCGImagePropertyIPTCDictionary, key as CFString) != nil
            guard !(unchanged && present) else { continue }
            // Values from the source file's IPTC: no XML-illegal characters in the XMP.
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyIPTCDictionary, key as CFString,
                                                         xmlSafe(value) as CFTypeRef)
        }
    }

    /// A text or list-of-text IPTC value without XML-illegal characters; other values as they are.
    private static func xmlSafe(_ value: Any) -> Any {
        if let text = value as? String { return MetadataFields.xmlSafe(text) }
        if let list = value as? [Any] { return list.map { ($0 as? String).map(MetadataFields.xmlSafe) ?? $0 } }
        return value
    }

    /// ImageIO's IPTC twins (and simple values in source files) are plain text; XMP wants a language
    /// alternative for these fields. Real alternatives are left as they are (other languages kept).
    private static func normalizeAltText(in meta: CGMutableImageMetadata) {
        // Found through the top-level list: copying a tag by path crashes ImageIO when a plain value was
        // stored as an alternative (type says alternative, value is a string, which it then reports as nil).
        let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] ?? []
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  case let path = "\(prefix):\(name)", altTextPaths.contains(path),
                  isPlainText(CGImageMetadataTagCopyValue(tag)), // a real alternative is left alone
                  let value = CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
            else { continue }
            CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
            CGImageMetadataSetValueWithPath(meta, nil, "\(path)[x-default]" as CFString, value as CFString)
        }
    }

    private static func isPlainText(_ value: CFTypeRef?) -> Bool {
        guard let value else { return true }
        return CFGetTypeID(value) == CFStringGetTypeID()
    }

    private static func setFields(_ options: MetadataOptions, final props: [String: Any],
                                  in meta: CGMutableImageMetadata) {
        if let artist = options.artist { set(artist, at: "dc:creator", in: meta) }
        if let copyright = options.copyright { set(copyright, at: "dc:rights", in: meta) }
        if let description = options.description { set(description, at: "dc:description", in: meta) }
        if let title = options.title { set(title, at: "dc:title", in: meta) }
        // Model text, already sanitised (`AltText.sanitized`); `set` sanitises again like every other value.
        if let altText = options.generatedAltText { set(altText, at: accessibilityAltTextPath, in: meta) }
        if options.keywords != nil { setList(iptcKeywords(props), at: "dc:subject", ordered: false, in: meta) }
        let zone = MetadataDates.zone(of: props)
        for path in MetadataDates.xmpPaths {
            let current = CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
            let value = MetadataDates.xmpValue(options.dateTaken, current: current, zone: zone)
            if value != current { set(value ?? "", at: path, in: meta) }
        }
        for field in options.custom where field.namespace == .xmp && !field.value.isEmpty && MetadataFields.isWritable(.xmp, field.key) {
            set(field.value, at: field.key, in: meta)
        }
    }

    /// Sets a text field (an empty value removes it); dc:creator is a list as XMP requires.
    private static func set(_ value: String, at path: String, in meta: CGMutableImageMetadata) {
        let value = MetadataFields.sanitized(value)
        if path == "dc:creator" {
            setList(value.isEmpty ? [] : [value], at: path, ordered: true, in: meta)
            return
        }
        CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
        guard !value.isEmpty else { return }
        let target = altTextPaths.contains(path) ? "\(path)[x-default]" : path
        CGImageMetadataSetValueWithPath(meta, nil, target as CFString, value as CFString)
    }

    private static func setList(_ values: [String], at path: String, ordered: Bool, in meta: CGMutableImageMetadata) {
        CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
        let parts = path.split(separator: ":").map(String.init)
        guard !values.isEmpty, parts.count == 2, let namespace = namespaces[parts[0]],
              let tag = CGImageMetadataTagCreate(namespace, parts[0] as CFString, parts[1] as CFString,
                                                 ordered ? .arrayOrdered : .arrayUnordered, values as CFArray)
        else { return }
        CGImageMetadataSetTagWithPath(meta, nil, path as CFString, tag)
    }
}
