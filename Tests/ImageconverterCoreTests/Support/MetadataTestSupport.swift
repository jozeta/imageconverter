import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ImageconverterCore

/// A converted file, re-read from disk: its property dictionary and its metadata (XMP view).
struct WrittenFile {
    let url: URL
    let data: Data
    let props: [String: Any]
    let meta: CGImageMetadata?

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url), url: url)
    }

    init(data: Data, url: URL) throws {
        self.url = url
        self.data = data
        props = try TestImages.properties(of: data)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        meta = source.flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
    }

    /// An encoded image that was never written to disk.
    static func decode(_ data: Data) throws -> WrittenFile {
        try WrittenFile(data: data, url: URL(fileURLWithPath: "/dev/null"))
    }

    func sub(_ key: CFString) -> [String: Any]? { props[key as String] as? [String: Any] }

    /// A string value at an XMP path; lang-alt values give their default text.
    func xmp(_ path: String) -> String? {
        guard let meta else { return nil }
        if let value = CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) { return value as String }
        return xmpArray(path).first
    }

    /// The items of an XMP array (bag, seq or alt) at `path`.
    func xmpArray(_ path: String) -> [String] {
        guard let meta, let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString),
              let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    /// Whether an embedded thumbnail is present: HEIC lists it in the container, JPEG holds a second
    /// JPEG (another start-of-image marker). ImageIO writes none for TIFF.
    var hasEmbeddedThumbnail: Bool {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let contents = (CGImageSourceCopyProperties(source, nil) as? [String: Any])?["{FileContents}"] as? [String: Any],
           let images = contents["Images"] as? [[String: Any]],
           images.contains(where: { !(($0["ThumbnailImages"] as? [Any]) ?? []).isEmpty }) {
            return true
        }
        let bytes = [UInt8](data)
        let starts = (0..<max(0, bytes.count - 2)).filter {
            bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF
        }
        return starts.count > 1
    }

    func contains(_ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    /// Whether the file holds an XMP packet at all.
    var hasXMPPacket: Bool { contains("x:xmpmeta") || contains("x:xapmeta") }
}

enum MetadataTestSupport {
    /// Writes a 40×20 image with `properties` and, optionally, XMP tags (path → string or [String]).
    static func source(_ url: URL, type: UTType = .jpeg, properties: [String: Any] = [:],
                       xmp: [(String, Any)] = [], thumbnail: Bool = false) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props = properties
        if thumbnail { props[kCGImageDestinationEmbedThumbnail as String] = true }
        let image = TestImages.make(width: 40, height: 20)
        if xmp.isEmpty {
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        } else {
            let meta = CGImageMetadataCreateMutable()
            for (path, value) in xmp { set(path, value, in: meta) }
            CGImageDestinationAddImageAndMetadata(dest, image, meta, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Vendor namespaces the fixtures use (registered so ImageIO accepts their paths).
    private static let vendorNamespaces: [(String, String)] = [
        ("drone-dji", "http://www.dji.com/drone-dji/1.0/"), ("crs", "http://ns.adobe.com/camera-raw-settings/1.0/")
    ]

    private static func set(_ path: String, _ value: Any, in meta: CGMutableImageMetadata) {
        for (prefix, namespace) in vendorNamespaces {
            CGImageMetadataRegisterNamespaceForPrefix(meta, namespace as CFString, prefix as CFString, nil)
        }
        guard let strings = value as? [String] else {
            CGImageMetadataSetValueWithPath(meta, nil, path as CFString, value as CFTypeRef)
            return
        }
        let parts = path.split(separator: ":").map(String.init)
        let namespaces: [String: CFString] = [
            "dc": kCGImageMetadataNamespaceDublinCore, "photoshop": kCGImageMetadataNamespacePhotoshop
        ]
        guard parts.count == 2, let namespace = namespaces[parts[0]],
              let tag = CGImageMetadataTagCreate(namespace, parts[0] as CFString, parts[1] as CFString,
                                                 .arrayOrdered, strings as CFArray) else { return }
        CGImageMetadataSetTagWithPath(meta, nil, path as CFString, tag)
    }

    /// Converts `source` with `options` into a fresh folder under `root` and re-reads the result.
    static func convert(_ source: URL, options: MetadataOptions, format: OutputFormat = .jpeg,
                        quality: Double = 0.85, root: URL) async throws -> WrittenFile {
        let out = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        var pipeline = Pipeline(output: OutputSettings(format: format, quality: quality))
        pipeline.metadata = options
        let report = await BatchRunner.run(InputCollector.collect([source]), pipeline: pipeline,
                                           mode: .newFolder(out))
        guard report.failures.isEmpty, let written = report.written.first else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(report.failures)"])
        }
        return try WrittenFile(url: written)
    }

    /// Formats that hold EXIF, IPTC and XMP and are available here.
    /// The file type and extension for writing a source in `format`.
    static func type(of format: OutputFormat) -> (UTType, String) {
        switch format {
        case .heic: return (.heic, "heic")
        case .png: return (.png, "png")
        case .tiff: return (.tiff, "tiff")
        default: return (.jpeg, "jpg")
        }
    }

    static var richFormats: [OutputFormat] {
        let available = OutputFormat.available()
        return [.jpeg, .heic, .png, .tiff].filter { available.contains($0) }
    }

    static func active() -> MetadataOptions {
        MetadataOptions(isEnabled: true, removeLocation: false)
    }

    enum Removal { case location, camera, author }

    /// An active step that removes only `removal`.
    static func removing(_ removal: Removal) -> MetadataOptions {
        var options = active()
        switch removal {
        case .location: options.location = .remove
        case .camera: options.removeCamera = true
        case .author: options.removeAuthor = true
        }
        return options
    }
}
