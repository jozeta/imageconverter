import Foundation

/// What to strip from, and set on, each file's metadata. A nil text field is left as is; a non-nil
/// field is set (an empty string clears it). Every field defaults to "leave as is" (except location
/// removal, which older files had on by default). Removal happens before setting.
public struct MetadataOptions: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Whether the step is part of the pipeline (added from "+ Add step"). Removing it keeps the settings.
    public var isIncluded: Bool
    /// What the batch, preview and estimate use.
    public var isActive: Bool { isIncluded && isEnabled }
    /// Strips everything except `keepWhenRemovingAll`; the other removal switches are then ignored.
    public var removeAll: Bool
    public var keepWhenRemovingAll: Set<KeepField> = []
    public var location: LocationEdit
    public var removeCamera: Bool
    /// EXIF/TIFF Artist, IPTC Byline, BylineTitle and Writer, XMP dc:creator, PNG Author.
    public var removeAuthor = false
    /// No embedded EXIF/JFIF thumbnail is written.
    public var removeThumbnail = false
    /// The whole IPTC dictionary and the IPTC fields in XMP (dc title, creator, description, subject and
    /// rights, photoshop and Iptc4xmp namespaces).
    public var removeIPTC = false
    /// No XMP packet is written where the format allows it (JPEG, TIFF); fields that are set still go to
    /// EXIF/IPTC. Formats that keep EXIF/IPTC inside XMP (PNG, HEIC, GIF) only lose the XMP-only fields.
    public var removeXMP = false
    public var artist: String?
    public var copyright: String?
    public var description: String?
    public var title: String?
    /// Nil leaves keywords as they are.
    public var keywords: [String]?
    public var keywordsMode: KeywordsMode = .add
    public var dateTaken: DateEdit = .keep {
        // Any edit replaces the invalid saved setting, so its note goes away.
        didSet { dateTakenWasInvalid = false }
    }
    /// True when the saved date setting couldn't be read (out of range, unknown mode) and `dateTaken` fell back
    /// to `.keep`; the editor and the batch report say so. Not saved.
    public internal(set) var dateTakenWasInvalid = false
    public static let invalidDateNote = "Saved date setting was invalid and was ignored"
    /// With a location `.set`: also remove the source's IPTC/XMP place names (as `.remove` does). Set only by the
    /// removal floor (`withRemovals(from:)`), when the Metadata step removes the location; not saved.
    public internal(set) var removePlaceNames = false
    /// After writing, the file's creation and modification dates become the resulting date taken, or the
    /// source file's own dates when there is none.
    public var setFileDates = false
    /// Allowlisted EXIF/IPTC/XMP fields, set after everything else.
    public var custom: [MetadataField] = []
    /// Asks Apple's on-device model (macOS 27+) for one sentence of alt text per image, written to XMP
    /// `Iptc4xmpCore:AltTextAccessibility` (see `AltText`).
    public var generateAltText = false
    /// With `generateAltText`: the generated text is also the description (EXIF, IPTC and XMP `dc:description`).
    public var altTextAsDescription = false
    /// The alt text generated for the item being written; set per item by the batch, never saved.
    public internal(set) var generatedAltText: String?

    /// The old on/off switch for location removal; `location` holds the full choice.
    public var removeLocation: Bool {
        get { location == .remove }
        set { location = newValue ? .remove : .keep }
    }

    public init(isEnabled: Bool = false, isIncluded: Bool? = nil, removeAll: Bool = false, removeLocation: Bool = true,
                location: LocationEdit? = nil, removeCamera: Bool = false, artist: String? = nil,
                copyright: String? = nil, description: String? = nil) {
        self.isEnabled = isEnabled
        self.isIncluded = isIncluded ?? isEnabled
        self.removeAll = removeAll
        self.location = location ?? (removeLocation ? .remove : .keep)
        self.removeCamera = removeCamera
        self.artist = artist
        self.copyright = copyright
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, isIncluded, removeAll, keepWhenRemovingAll, location, removeLocation, removeCamera, removeAuthor
        case removeThumbnail, removeIPTC, removeXMP, artist, copyright, description, title, keywords, keywordsMode
        case dateTaken, setFileDates, custom, generateAltText, altTextAsDescription
    }

    /// Lenient: a missing or invalid field takes its default, so older saved pipelines keep loading
    /// (an invalid GPS position becomes `.remove`, an invalid date edit `.keep` with `dateTakenWasInvalid`
    /// set, so the editor and the report say it was ignored); custom fields outside the allowlist are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Older files had no flag: a step that was switched on stays visible, a switched-off one goes away.
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? isEnabled
        removeAll = try container.decodeIfPresent(Bool.self, forKey: .removeAll) ?? false
        let keep = try container.decodeIfPresent([String].self, forKey: .keepWhenRemovingAll) ?? []
        keepWhenRemovingAll = Set(keep.compactMap(KeepField.init(rawValue:)))
        if container.contains(.location) {
            // An invalid position (out of range, unknown mode) falls back to removing the location: the
            // file asked to replace it, so the original must not leak.
            location = (try? container.decode(LocationEdit.self, forKey: .location)) ?? .remove
        } else {
            location = try container.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? true ? .remove : .keep
        }
        removeCamera = try container.decodeIfPresent(Bool.self, forKey: .removeCamera) ?? false
        removeAuthor = try container.decodeIfPresent(Bool.self, forKey: .removeAuthor) ?? false
        removeThumbnail = try container.decodeIfPresent(Bool.self, forKey: .removeThumbnail) ?? false
        removeIPTC = try container.decodeIfPresent(Bool.self, forKey: .removeIPTC) ?? false
        removeXMP = try container.decodeIfPresent(Bool.self, forKey: .removeXMP) ?? false
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords).map(MetadataFields.normalizedKeywords)
        keywordsMode = (try? container.decodeIfPresent(KeywordsMode.self, forKey: .keywordsMode)) ?? .add
        if let date = try? container.decodeIfPresent(DateEdit.self, forKey: .dateTaken) {
            dateTaken = date
        } else {
            dateTaken = .keep
            dateTakenWasInvalid = container.contains(.dateTaken)
        }
        setFileDates = try container.decodeIfPresent(Bool.self, forKey: .setFileDates) ?? false
        let raw = try container.decodeIfPresent([MetadataFields.RawField].self, forKey: .custom) ?? []
        custom = MetadataFields.allowed(raw)
        generateAltText = (try? container.decodeIfPresent(Bool.self, forKey: .generateAltText)) ?? false
        altTextAsDescription = (try? container.decodeIfPresent(Bool.self, forKey: .altTextAsDescription)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isIncluded, forKey: .isIncluded)
        try container.encode(removeAll, forKey: .removeAll)
        try container.encode(KeepField.allCases.filter(keepWhenRemovingAll.contains), forKey: .keepWhenRemovingAll)
        try container.encode(location, forKey: .location)
        try container.encode(removeCamera, forKey: .removeCamera)
        try container.encode(removeAuthor, forKey: .removeAuthor)
        try container.encode(removeThumbnail, forKey: .removeThumbnail)
        try container.encode(removeIPTC, forKey: .removeIPTC)
        try container.encode(removeXMP, forKey: .removeXMP)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(copyright, forKey: .copyright)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encode(keywordsMode, forKey: .keywordsMode)
        try container.encode(dateTaken, forKey: .dateTaken)
        try container.encode(setFileDates, forKey: .setFileDates)
        try container.encode(custom, forKey: .custom)
        // Written only when used, so files that don't use alt text stay as they were.
        if generateAltText { try container.encode(generateAltText, forKey: .generateAltText) }
        if altTextAsDescription { try container.encode(altTextAsDescription, forKey: .altTextAsDescription) }
    }
}

/// One find-and-replace rule of the Rename step.
public struct ReplacementRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var find: String
    public var replace: String
    public var useRegex: Bool

    public init(id: UUID = UUID(), find: String = "", replace: String = "", useRegex: Bool = false) {
        self.id = id
        self.find = find
        self.replace = replace
        self.useRegex = useRegex
    }

    private enum CodingKeys: String, CodingKey { case id, find, replace, useRegex }

    static let fallbackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A fixed id keeps two decodes of the same old file equal (preset change tracking compares them).
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? Self.fallbackID
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        replace = try container.decodeIfPresent(String.self, forKey: .replace) ?? ""
        useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
    }
}

/// How output files are named.
public struct RenameOptions: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Whether the step is part of the pipeline (added from "+ Add step").
    public var isIncluded: Bool
    public var isActive: Bool { isIncluded && isEnabled }
    public var pattern: String
    public var counterStart: Int
    /// What `{counter}` adds per image (default 1). Never 0 (read as 1); negative counts down, never below 0.
    public var counterStep: Int
    /// Find and replace rules, applied in order to the rendered name; a rule with an empty `find` does nothing.
    public var replacements: [ReplacementRule]
    /// Text put before and after the rendered name (after find and replace).
    public var prefix: String
    public var suffix: String
    public var removeSpaces: Bool
    public var specialCharacters: SpecialCharacters
    /// What `.replace` writes for other characters: `-`, `_`, `.` or empty.
    public var replacement: String
    public var caseStyle: CaseStyle

    /// The counter start is limited to 0...999_999_999 when decoded.
    public static let counterRange = 0...999_999_999
    /// The counter step is limited to this range (and 0 becomes 1) when decoded or set through `init`.
    public static let counterStepRange = -999_999...999_999
    /// At most this many rules are kept when decoded.
    public static let maxReplacements = 20

    public init(isEnabled: Bool = false, isIncluded: Bool? = nil, pattern: String = "{name}", counterStart: Int = 1,
                counterStep: Int = 1, replacements: [ReplacementRule] = [], prefix: String = "", suffix: String = "",
                removeSpaces: Bool = false, specialCharacters: SpecialCharacters = .keep,
                replacement: String = "-", caseStyle: CaseStyle = .keep) {
        self.isEnabled = isEnabled
        self.isIncluded = isIncluded ?? isEnabled
        self.pattern = pattern
        self.counterStart = counterStart
        self.counterStep = Self.validStep(counterStep)
        self.replacements = replacements
        self.prefix = prefix
        self.suffix = suffix
        self.removeSpaces = removeSpaces
        self.specialCharacters = specialCharacters
        self.replacement = NameTransforms.allowedReplacements.contains(replacement) ? replacement : "-"
        self.caseStyle = caseStyle
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, isIncluded, pattern, counterStart, counterStep, replacements
        case prefix, suffix, removeSpaces, specialCharacters, replacement, caseStyle
    }

    /// The single-rule keys of older files; read, never written.
    private enum LegacyKeys: String, CodingKey { case findText, replaceText, useRegex }

    /// Lenient: a missing field takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Older files had no flag: a step that was switched on stays visible, a switched-off one goes away.
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? isEnabled
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? "{name}"
        let start = try container.decodeIfPresent(Int.self, forKey: .counterStart) ?? 1
        counterStart = min(max(start, Self.counterRange.lowerBound), Self.counterRange.upperBound)
        counterStep = Self.validStep((try? container.decodeIfPresent(Int.self, forKey: .counterStep)) ?? 1)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        removeSpaces = try container.decodeIfPresent(Bool.self, forKey: .removeSpaces) ?? false
        specialCharacters = (try? container.decodeIfPresent(SpecialCharacters.self, forKey: .specialCharacters)) ?? .keep
        let decodedReplacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? "-"
        replacement = NameTransforms.allowedReplacements.contains(decodedReplacement) ? decodedReplacement : "-"
        caseStyle = (try? container.decodeIfPresent(CaseStyle.self, forKey: .caseStyle)) ?? .keep
        if let rules = try container.decodeIfPresent([ReplacementRule].self, forKey: .replacements) {
            replacements = Array(rules.prefix(Self.maxReplacements))
            // Rules without an id all got the same fallback; give repeats a position-based id (ForEach needs unique ids).
            var seen = Set<UUID>()
            for index in replacements.indices where !seen.insert(replacements[index].id).inserted {
                replacements[index].id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            }
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let find = try legacy.decodeIfPresent(String.self, forKey: .findText) ?? ""
            let replace = try legacy.decodeIfPresent(String.self, forKey: .replaceText) ?? ""
            let regex = try legacy.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
            replacements = find.isEmpty ? [] : [ReplacementRule(id: ReplacementRule.fallbackID, find: find, replace: replace,
                                                                useRegex: regex)]
        }
    }
}

extension RenameOptions {
    /// `step` within `counterStepRange`, with 0 (no step at all) read as 1.
    static func validStep(_ step: Int) -> Int {
        step == 0 ? 1 : min(max(step, counterStepRange.lowerBound), counterStepRange.upperBound)
    }

    /// The `{counter}` value of the image at `index` (skipped images take no number): start + index × step,
    /// saturating instead of overflowing, and never below 0 (a counting-down step stops there).
    public func counter(at index: Int) -> Int {
        let step = Self.validStep(counterStep)
        let (offset, multiplyOverflow) = max(0, index).multipliedReportingOverflow(by: step)
        if multiplyOverflow { return step > 0 ? Int.max : 0 }
        let (sum, addOverflow) = counterStart.addingReportingOverflow(offset)
        if addOverflow { return offset > 0 ? Int.max : 0 }
        return max(sum, 0)
    }
}
