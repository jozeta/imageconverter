import Foundation

/// The removal floor: what the main Metadata step (or the CLI's `--strip-gps`/`--strip-all`, or the Privacy
/// panel's "Remove these") hides from the output, no condition may bring back. A condition's metadata override
/// may add removals and set fields, never turn a removal off.
extension MetadataOptions {
    /// True when the options remove or replace something the source holds (a copy of the source would keep it).
    public var hidesSourceData: Bool {
        guard isActive else { return false }
        return removeAll || location != .keep || removeCamera || removeAuthor || removeThumbnail || removeIPTC
            || removeXMP || dateTaken != .keep
    }

    /// True when these (active) options remove the location with its place names: `.remove`, or "remove all"
    /// without keeping the location.
    var removesLocationEntirely: Bool {
        isActive && (location == .remove || removeAll && !keepWhenRemovingAll.contains(.location))
    }

    /// These options with `floor`'s removals added (when `floor` is active): every removal switch ORed, a
    /// location or date the floor removes or replaces wins over "keep", and with "remove all" only what both
    /// keep is kept.
    public func withRemovals(from floor: MetadataOptions) -> MetadataOptions {
        guard floor.isActive else { return self }
        var merged = self
        if floor.removeAll {
            merged.keepWhenRemovingAll = removeAll ? keepWhenRemovingAll.intersection(floor.keepWhenRemovingAll)
                                                   : floor.keepWhenRemovingAll
            merged.removeAll = true
        }
        merged.removeCamera = removeCamera || floor.removeCamera
        merged.removeAuthor = removeAuthor || floor.removeAuthor
        merged.removeThumbnail = removeThumbnail || floor.removeThumbnail
        merged.removeIPTC = removeIPTC || floor.removeIPTC
        merged.removeXMP = removeXMP || floor.removeXMP
        if location == .keep { merged.location = floor.location }
        // Replacing only the coordinates would keep the real place names the floor removes.
        if floor.removesLocationEntirely, case .set = merged.location { merged.removePlaceNames = true }
        // A shift of the real date reveals it; the floor's fixed date wins over it.
        switch (dateTaken, floor.dateTaken) {
        case (.keep, _), (.shift, .set): merged.dateTaken = floor.dateTaken
        default: break
        }
        if merged.removeAll {
            // A removal the override asks for also drops that field from the floor's keep list.
            if merged.location == .remove || merged.removePlaceNames { merged.keepWhenRemovingAll.remove(.location) }
            if merged.removeCamera { merged.keepWhenRemovingAll.remove(.cameraInfo) }
            if merged.removeAuthor { merged.keepWhenRemovingAll.remove(.author) }
        }
        return merged
    }
}

extension OutputSettings {
    /// The source's own format at the best quality it allows (lossless where the format is), for a copy that
    /// has to be converted to remove metadata.
    static func faithful(_ format: OutputFormat) -> OutputSettings {
        OutputSettings(format: format, quality: 1, tiffCompression: .lzw, progressive: false, optimizePNG: false,
                       compression: .quality)
    }
}
