import Foundation
import ImageIO

/// Face and person regions in XMP: they name and locate the people a Redact step hides, so they go too.
extension MetadataOps {
    /// Whole namespaces that only hold regions: MWG regions, Microsoft Photo regions, Apple's face info.
    static let faceRegionNamespaces: Set<String> = [
        "http://www.metadataworkinggroup.com/schemas/regions/",
        "http://ns.microsoft.com/photo/1.2/t/RegionInfo#",
        "http://ns.microsoft.com/photo/1.2/t/Region#",
        "http://ns.apple.com/faceinfo/1.0/",
    ]
    /// Region and person tags inside broader namespaces, by namespace URI and property name: a file may give a
    /// namespace any prefix, so the prefix is never compared.
    static let faceRegionProperties: [String: Set<String>] = [
        "http://ns.microsoft.com/photo/1.2/": ["RegionInfo"],
        "http://iptc.org/std/Iptc4xmpExt/2008-02-29/": ["PersonInImage", "PersonInImageWDetails", "ImageRegion"],
    ]

    /// `properties` with every face or person region removed from the XMP they carry (`xmpPropertyKey`), and whether
    /// anything was removed.
    static func removingFaceRegions(from properties: [String: Any]) -> (properties: [String: Any], removed: Bool) {
        guard let xmp = properties[xmpPropertyKey] as? OutputXMP,
              let meta = CGImageMetadataCreateMutableCopy(xmp.metadata) else { return (properties, false) }
        let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] ?? []
        let paths = tags.compactMap { tag -> String? in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let isRegion = faceRegionNamespaces.contains(namespace) || faceRegionProperties[namespace]?.contains(name) == true
            // Removed by the path in this metadata's own prefix.
            return isRegion ? "\(prefix):\(name)" : nil
        }
        guard !paths.isEmpty else { return (properties, false) }
        for path in paths { CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) }
        var result = properties
        result[xmpPropertyKey] = OutputXMP(metadata: meta)
        return (result, true)
    }
}

extension Pipeline {
    /// True when an enabled Redact step hides faces.
    var redactsFaces: Bool {
        steps.contains { step in
            guard step.isEnabled, case .redact(let options) = step.operation else { return false }
            return options.target.includesFaces
        }
    }
}
