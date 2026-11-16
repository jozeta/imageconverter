import CoreGraphics
import Foundation
import ImageIO

/// Metadata-only edits without re-encoding: when an item's resolved pipeline changes nothing but metadata, the
/// source's image data is copied as it is (`CGImageDestinationCopyImageSource`) with the new metadata, so a
/// JPEG's compressed scan data stays byte-identical. The written result is read back and checked against what
/// the re-encode would carry; anything the options remove that survived sends the item back to the re-encode.
///
/// The path is taken when all of these hold:
/// - the Metadata step is on (`MetadataOptions.isActive`), or the image has metadata panel changes
///   (`Pipeline.effectiveMetadata`), which the check below verifies like the step's own edits;
/// - the pipeline has no enabled image step at all (after conditions are resolved: resize, crop, rotate,
///   perspective, trim, canvas, color profile, Adjust and watermark all count, even when set to do nothing);
/// - the output format is the source's own format (by content, not extension);
/// - the compression mode is plain quality (a target size, maximum size or smart mode asks for compression).
///
/// The quality slider and progressive JPEG are then ignored: the image data is the source's own (PNG and TIFF
/// never take this path, see `supportedTypes`). A JPEG copy is rebuilt from an allowlist of segments
/// (`JPEGSegments`), which drops its EXIF thumbnail too; a HEIC copy with a thumbnail, more images or auxiliary
/// data is re-encoded. The EXIF orientation flag is kept instead of rotating pixels (the re-encode saves
/// photos upright with orientation 1); viewers show the copy the same way.
enum LosslessMetadata {
    /// The report note for a file written this way.
    static let pixelsUntouchedNote = "Metadata only, pixels untouched"
    /// The report note when the path would apply but the format (or a multi-image file) doesn't support it.
    static let unsupportedNote = "Re-encoded: lossless metadata edit isn't available for this format"

    /// The report note when the copy still held something the options remove.
    static func notRemovedNote(_ fields: [String]) -> String {
        "Lossless edit couldn't remove \(listed(fields)); re-encoded"
    }

    /// The report note when the copy lacked something the re-encode keeps or sets.
    static func notWrittenNote(_ fields: [String]) -> String {
        "Lossless edit couldn't write \(listed(fields)); re-encoded"
    }

    private static func listed(_ fields: [String]) -> String {
        fields.prefix(3).joined(separator: ", ") + (fields.count > 3 ? ", …" : "")
    }

    /// Formats whose copy takes replaced metadata. PNG is left out: ImageIO keeps its eXIf chunk (GPS included)
    /// whatever metadata the copy is given, and its re-encode is lossless anyway. TIFF keeps its own IFD tags
    /// (camera, serials), which the check below catches; JPEG and HEIC replace all of it.
    static let supportedTypes: Set<String> = [
        OutputFormat.jpeg.utType.identifier, OutputFormat.heic.utType.identifier,
    ]

    enum Outcome {
        /// The copy, and the metadata properties it was written from.
        case written(Data, properties: [String: Any])
        /// Re-encode instead, with this note.
        case reencode(note: String)
    }

    /// True when `pipeline` (resolved, without conditions) changes only metadata.
    static func applies(to pipeline: Pipeline) -> Bool {
        guard pipeline.effectiveMetadata.isActive, !pipeline.steps.contains(where: \.isEnabled) else { return false }
        return pipeline.output.compression == .quality || !pipeline.output.format.supportsQuality
    }

    /// Whether the file at `url` would be copied this way (the check of the written copy aside): the pipeline
    /// only changes metadata, the format is the source's and supports it. The quality ladder shows nothing then.
    static func wouldCopy(_ url: URL, pipeline: Pipeline) -> Bool {
        guard applies(to: pipeline),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return support(of: source, for: pipeline) == true
    }

    /// Nil when the source isn't in the output format (an ordinary conversion); false when the format, or a file
    /// with several images, can't be copied with new metadata.
    private static func support(of source: CGImageSource, for pipeline: Pipeline) -> Bool? {
        guard let type = CGImageSourceGetType(source) as String?, type == pipeline.output.format.utType.identifier
        else { return nil }
        return supportedTypes.contains(type) && CGImageSourceGetCount(source) == 1
    }

    /// Writes `url` with `pipeline`'s metadata changes and its image data untouched. Nil when the path doesn't
    /// apply (pixel steps, another format, a size mode): the item is re-encoded as usual, with no note. Throws
    /// what the decode limits throw, so a file the batch would refuse is refused here too.
    static func write(_ url: URL, pipeline: Pipeline, maxPixels: Int) throws -> Outcome? {
        guard applies(to: pipeline) else { return nil }
        let (source, header) = try DecodeLimits.standard.capped(maxPixels: maxPixels).open(url)
        guard let support = support(of: source, for: pipeline) else { return nil }
        guard support, let type = CGImageSourceGetType(source) as String? else { return .reencode(note: unsupportedNote) }
        let sourceXMP = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let properties = pipeline.outputProperties(from: header.properties, metadata: sourceXMP,
                                                   sourceWidth: header.width, sourceHeight: header.height)
        let orientation = header.properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let target = metadata(from: properties, orientation: orientation)
        guard let reference = reference(properties, format: pipeline.output.format) else {
            return .reencode(note: unsupportedNote)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            return .reencode(note: unsupportedNote)
        }
        // No XMP packet where the re-encode writes none (no XMP left, or the options remove it).
        let options: [CFString: Any] = [kCGImageDestinationMetadata: target, kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeXMP: !hasXMPPacket(reference)]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            return .reencode(note: unsupportedNote)
        }
        var written = data as Data
        // A JPEG copy keeps segments ImageIO doesn't know (a Photoshop preview, the EXIF thumbnail, comments):
        // rebuilt from an allowlist, with the re-encode's IPTC block, re-encoded when that isn't possible.
        if type == OutputFormat.jpeg.utType.identifier {
            guard let filtered = JPEGSegments.filtered(written, iptcFrom: reference) else {
                return .reencode(note: notRemovedNote(["JPEG segments"]))
            }
            written = filtered
        }
        let check = check(written, expected: properties, options: pipeline.metadata, reference: reference)
        guard check.left.isEmpty else { return .reencode(note: notRemovedNote(check.left)) }
        guard check.missing.isEmpty else { return .reencode(note: notWrittenNote(check.missing)) }
        return .written(written, properties: properties)
    }

    // MARK: Building the metadata

    /// Property dictionaries written as metadata tags (ImageIO writes them back in their native blocks).
    static let dictionaryKeys: [String] = [
        kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
    ].map { $0 as String }

    /// The output XMP (removals and edits already applied, see `MetadataOps.output`) plus every field of the
    /// property dictionaries, and the source's orientation. Each field is mapped on its own into a scratch tree
    /// and only added where the XMP has no tag at that path: the XMP twins of IPTC and TIFF text fields are kept
    /// in sync by `MetadataOps.xmp`, and setting a plain value over a language alternative leaves a tag ImageIO
    /// can crash on.
    static func metadata(from properties: [String: Any], orientation: Int) -> CGMutableImageMetadata {
        let meta = (properties[MetadataOps.xmpPropertyKey] as? OutputXMP)
            .flatMap { CGImageMetadataCreateMutableCopy($0.metadata) } ?? CGImageMetadataCreateMutable()
        let mapped = CGImageMetadataCreateMutable()
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        let orientationKey = kCGImagePropertyTIFFOrientation as String
        for dictionaryKey in dictionaryKeys {
            guard let fields = properties[dictionaryKey] as? [String: Any] else { continue }
            for (key, value) in fields where !(dictionaryKey == tiffKey && key == orientationKey) {
                CGImageMetadataSetValueMatchingImageProperty(mapped, dictionaryKey as CFString, key as CFString,
                                                             value as AnyObject)
            }
        }
        CGImageMetadataSetValueMatchingImageProperty(mapped, kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        for tag in (CGImageMetadataCopyTags(mapped) as? [CGImageMetadataTag]) ?? [] {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) else {
                continue
            }
            let path = "\(prefix):\(name)" as CFString
            let isOrientation = (prefix as String) == "tiff" && (name as String) == "Orientation"
            if !isOrientation, CGImageMetadataCopyTagWithPath(meta, nil, path) != nil { continue }
            CGImageMetadataSetTagWithPath(meta, nil, path, tag)
        }
        return meta
    }

    // MARK: Checking the result

    /// Fields ImageIO writes from the image data itself, in either path.
    private static let structuralFields: Set<String> = [
        "Orientation", "Compression", "PhotometricInterpretation", "ResolutionUnit", "XResolution", "YResolution",
        "TileWidth", "TileLength", "PlanarConfiguration", "BitsPerSample", "SamplesPerPixel", "RowsPerStrip",
        "ColorSpace", "PixelXDimension", "PixelYDimension", "ExifVersion", "FlashPixVersion", "ComponentsConfiguration",
    ]

    /// Dictionaries describing the file's own encoding, not metadata (the copy keeps the source's).
    private static let formatDictionaries: Set<String> = [kCGImagePropertyJFIFDictionary as String]

    /// XMP namespaces that only mirror the property dictionaries (checked there).
    private static let mirrorNamespaces: Set<String> = Set([
        kCGImageMetadataNamespaceExif, kCGImageMetadataNamespaceExifAux, kCGImageMetadataNamespaceExifEX,
        kCGImageMetadataNamespaceTIFF, "http://ns.apple.com/ImageIO/1.0/" as CFString,
    ].map { $0 as String })

    /// How the copy compares with the re-encode of the same metadata (a tiny reference image, so fields ImageIO
    /// derives count too), by field name. `left`: what the copy holds that the re-encode wouldn't (an embedded
    /// thumbnail, extra images or auxiliary data, a field neither asked for nor in the reference, an XMP tag or
    /// packet the re-encode drops). `missing`: what the re-encode writes that the copy lacks or holds with another
    /// value (kept and set fields; XMP values compared in full, nested items included). Both empty: the copy is
    /// good. The JPEG segments outside ImageIO's property view are handled before, by `JPEGSegments`.
    static func check(_ written: Data, expected: [String: Any], options _: MetadataOptions, reference referenceData: Data)
        -> (left: [String], missing: [String]) {
        let readOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let result = CGImageSourceCreateWithData(written as CFData, readOptions),
              let resultProps = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [String: Any],
              let reference = CGImageSourceCreateWithData(referenceData as CFData, readOptions),
              let referenceProps = CGImageSourceCopyPropertiesAtIndex(reference, 0, nil) as? [String: Any]
        else { return ([], ["metadata"]) }
        // Outputs never carry an embedded thumbnail, extra images or auxiliary data (depth, mattes, gain maps).
        var left = containerLeftovers(written)
        var (fieldsLeft, missing) = compare(resultProps, expected: expected, reference: referenceProps)
        left += fieldsLeft
        let resultValues = xmpValues(CGImageSourceCopyMetadataAtIndex(result, 0, nil))
        let referenceValues = xmpValues(CGImageSourceCopyMetadataAtIndex(reference, 0, nil))
        let resultTags = Set(resultValues.keys)
        let referenceTags = Set(referenceValues.keys)
        var allowedTags = referenceTags.union(xmpTags((expected[MetadataOps.xmpPropertyKey] as? OutputXMP)?.metadata))
        // HEIC copies mirror the EXIF date taken into XMP under this name.
        if (referenceProps[kCGImagePropertyExifDictionary as String] as? [String: Any])?[
            kCGImagePropertyExifDateTimeOriginal as String] != nil {
            allowedTags.insert("XMP photoshop:DateTimeOriginal")
        }
        left += resultTags.subtracting(allowedTags).sorted()
        // Kept and set tags must hold the re-encode's value, nested items included.
        missing += referenceTags.filter { resultValues[$0] != referenceValues[$0] }.sorted()
        if hasXMPPacket(written), !hasXMPPacket(referenceData) { left.append("XMP") }
        return (left, missing)
    }

    private static func hasXMPPacket(_ data: Data) -> Bool {
        data.range(of: Data("x:xmpmeta".utf8)) != nil || data.range(of: Data("x:xapmeta".utf8)) != nil
    }

    /// The property dictionaries of the copy against the reference: every field of the copy must be in the
    /// reference or asked for, and every field of the reference must be in the copy with the same value
    /// (fields ImageIO writes from the image data itself excepted).
    private static func compare(_ result: [String: Any], expected: [String: Any], reference: [String: Any])
        -> (left: [String], missing: [String]) {
        var left: [String] = []
        var missing: [String] = []
        let dictionaries = Set(result.keys).union(reference.keys).filter { $0.hasPrefix("{") }
            .subtracting(formatDictionaries)
        for dictionaryKey in dictionaries.sorted() {
            let fields = result[dictionaryKey] as? [String: Any]
            let referenceFields = reference[dictionaryKey] as? [String: Any]
            guard fields != nil || referenceFields != nil else { continue }
            let wanted = expected[dictionaryKey] as? [String: Any] ?? [:]
            let name = dictionaryKey.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            let allowed = Set(wanted.keys).union((referenceFields ?? [:]).keys).union(structuralFields)
            for key in (fields ?? [:]).keys.sorted() where !allowed.contains(key) { left.append("\(name) \(key)") }
            for (key, value) in (referenceFields ?? [:]).sorted(by: { $0.key < $1.key })
            where !structuralFields.contains(key) && !same(fields?[key], value) {
                missing.append("\(name) \(key)")
            }
        }
        return (left, missing)
    }

    /// Equal values, numbers within rounding (GPS coordinates go through text in XMP).
    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (left as NSNumber, right as NSNumber):
            return abs(left.doubleValue - right.doubleValue) <= 1e-6 * max(1, abs(right.doubleValue))
        case let (left as [Any], right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { same($0, $1) }
        case let (left as NSObject, right as NSObject):
            return left.isEqual(right) || left.description == right.description
        default: return false
        }
    }

    /// The re-encode of `properties` on an 8 x 8 image: what the batch's re-encode would carry.
    static func reference(_ properties: [String: Any], format: OutputFormat) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return nil }
        return try? ImageEncoder.encode(image, properties: properties, settings: .faithful(format))
    }

    /// Top-level XMP tags as "XMP prefix:name", outside the mirror namespaces.
    private static func xmpTags(_ metadata: CGImageMetadata?) -> Set<String> { Set(xmpValues(metadata).keys) }

    /// Top-level XMP tags ("XMP prefix:name", outside the mirror namespaces) with their values written out,
    /// arrays and structures included.
    private static func xmpValues(_ metadata: CGImageMetadata?) -> [String: String] {
        guard let metadata, let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [:] }
        var values: [String: String] = [:]
        for tag in tags {
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                  !mirrorNamespaces.contains(namespace),
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            values["XMP \(prefix):\(name)"] = xmpValue(tag)
        }
        return values
    }

    private static func xmpValue(_ tag: CGImageMetadataTag) -> String {
        switch CGImageMetadataTagCopyValue(tag) {
        case let text as String: return text
        case let items as [CGImageMetadataTag]: return "[" + items.map(xmpValue).joined(separator: ", ") + "]"
        case let fields as [String: CGImageMetadataTag]:
            return "{" + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(xmpValue($0.value))" }
                .joined(separator: ", ") + "}"
        case let other?: return "\(other)"
        case nil: return ""
        }
    }

    // MARK: Container

    /// Auxiliary images a copy could carry over (depth, disparity, mattes, gain maps).
    private static var auxiliaryTypes: [(CFString, String)] {
        var types: [(CFString, String)] = [
            (kCGImageAuxiliaryDataTypeDepth, "Depth data"), (kCGImageAuxiliaryDataTypeDisparity, "Disparity data"),
            (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "Portrait matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, "Skin matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, "Hair matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, "Teeth matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, "Glasses matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, "Sky matte"),
            (kCGImageAuxiliaryDataTypeHDRGainMap, "HDR gain map"),
        ]
        if #available(macOS 15, *) { types.append((kCGImageAuxiliaryDataTypeISOGainMap, "HDR gain map")) }
        return types
    }

    /// What a written file holds besides its one image: more images, an embedded thumbnail (HEIC lists it in the
    /// container, a JPEG's EXIF holds one) and auxiliary data. 1.0 wrote none of these, nor does the re-encode.
    static func containerLeftovers(_ data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return ["Unreadable file"] }
        var found: [String] = []
        if CGImageSourceGetCount(source) > 1 { found.append("Extra images") }
        if PrivacyScanner.embeddedThumbnailSize(in: data) != nil { found.append("Embedded thumbnail") }
        for (type, name) in auxiliaryTypes where !found.contains(name)
            && CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
            found.append(name)
        }
        return found
    }
}
