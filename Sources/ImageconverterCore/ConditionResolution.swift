import Foundation

/// What the batch does with one image after its conditions are resolved.
public enum Disposition: String, Equatable, Sendable {
    case process, copyOriginal, skip
}

/// A pipeline with its condition steps replaced by the branches chosen for one image.
public struct ResolvedPipeline: Equatable, Sendable {
    /// Holds no condition steps.
    public var pipeline: Pipeline
    public var disposition: Disposition
    /// Notes for the report about how this item was resolved (e.g. a copy converted to remove metadata).
    public var notes: [String]
    /// The "Save into subfolder" template (the last one chosen), rendered per file when it is planned.
    public var subfolder: String?
    /// Finder tags to add to the written file.
    public var finderTags: [String]
    /// "Add a note" templates, rendered per file into the report.
    public var noteTemplates: [String]
    /// Labels of extra outputs the planner found no free name for (set by the batch's planning).
    public var unplannedOutputs: [String] = []
    /// What `{labels}` gives for this image (`ImageAnalysis.tokenLabels`): set whenever labels were analysed, for a
    /// Shows check too, and empty when they weren't; only templates that use the token read it.
    public var labels: [String] = []
    /// A note needs attention: a content check's image analysis failed (`ReportEntry.warning`).
    public var warning = false

    public init(pipeline: Pipeline, disposition: Disposition = .process, notes: [String] = [],
                subfolder: String? = nil, finderTags: [String] = [], noteTemplates: [String] = []) {
        self.pipeline = pipeline
        self.disposition = disposition
        self.notes = notes
        self.subfolder = subfolder
        self.finderTags = finderTags
        self.noteTemplates = noteTemplates
    }

    /// What the batch adds to this item's report line: the resolution notes, then a saved date setting that
    /// was invalid and ignored.
    public var runNotes: [String] {
        notes + (pipeline.metadata.isActive && pipeline.metadata.dateTakenWasInvalid
            ? [MetadataOptions.invalidDateNote] : [])
    }

    /// "Skipped by a condition" / "Copied unchanged" / the first resolution note; nil when simply processed.
    public var statusNote: String? {
        switch disposition {
        case .process: return notes.first
        case .copyOriginal: return ConditionalStep.copiedNote
        case .skip: return ConditionalStep.skippedReason
        }
    }
}

extension Pipeline {
    /// True when any enabled step is a condition (only then are a file's facts read).
    public var hasConditions: Bool {
        steps.contains { step in
            if step.isEnabled, case .condition = step.operation { return true }
            return false
        }
    }

    static let emptyLabelsBlocker = "Choose at least one label for each “Shows” condition first"

    /// Why the app's Run stays off for the enabled conditions (a Shows check without labels), or nil.
    public var conditionRunBlocker: String? {
        let incomplete = steps.contains { step in
            guard step.isEnabled, case .condition(let conditional) = step.operation else { return false }
            return conditional.conditions.contains { condition in
                if case .shows(let match) = condition.check { return !match.isComplete }
                return false
            }
        }
        return incomplete ? Self.emptyLabelsBlocker : nil
    }

    /// What reading a file's facts must include: the enabled conditions' needs, plus the labels when the Rename
    /// step's pattern uses `{labels}`.
    var factNeeds: FactNeeds {
        var needs = conditionFactNeeds
        if rename.isActive, RenameTemplate(rename.pattern).usesLabels { needs.insert(.labels) }
        return needs
    }

    /// Whether resolving reads each file's facts: there are conditions, or the file name needs the labels.
    public var needsFacts: Bool { hasConditions || factNeeds.contains(.labels) }

    /// What reading a file's facts must include for the enabled conditions.
    var conditionFactNeeds: FactNeeds {
        steps.reduce(into: FactNeeds()) { needs, step in
            guard step.isEnabled, case .condition(let conditional) = step.operation else { return }
            for condition in conditional.conditions { needs.formUnion(condition.needs) }
            if (conditional.then + conditional.otherwise).contains(where: \.usesLabels) { needs.insert(.labels) }
        }
    }

    /// The pipeline for one image: each enabled condition step, in order, is replaced in place by the image
    /// steps of the branch its facts choose; output, metadata and rename overrides apply (later ones win);
    /// skip wins over copying the original, and both win over processing. After a "Stop" action no later
    /// condition step is checked. Disabled condition steps are dropped. With no facts (an unreadable file),
    /// conditions are dropped and the file fails as usual later.
    /// The Metadata step's removals are a floor: a metadata override keeps them (`withRemovals(from:)`), and a
    /// copy whose metadata would have to change is converted instead, in the source's own format at the best
    /// quality, with a note. "Apply preset" reads presets from `presets`. A copied original ignores added keywords
    /// and a preset's image steps, with a note; a name pattern stopped for taking too long counts as no match,
    /// with a note. Content checks whose image analysis failed don't match, with a note
    /// (`ImageAnalysis.unavailableNote`); so do macOS 15 checks on an older system (`needsNewerSystemNote`).
    /// `{labels}` in tags and keywords becomes one entry per label.
    public func resolved(for facts: ItemFacts?, presets: PresetLibrary = .standard) -> ResolvedPipeline {
        var state = Resolution(pipeline: self, floor: metadata, presets: presets,
                               labels: facts?.analysis.tokenLabels ?? [])
        state.pipeline.steps = []
        for step in steps {
            guard case .condition(let conditional) = step.operation else {
                state.pipeline.steps.append(step)
                continue
            }
            guard step.isEnabled, let facts, !state.stopped else { continue }
            var timedOut = false
            let branch = conditional.matches(facts, timedOut: &timedOut) ? conditional.then : conditional.otherwise
            if timedOut, !state.notes.contains(BoundedRegex.timeoutNote) { state.notes.append(BoundedRegex.timeoutNote) }
            for action in branch { state.apply(action) }
        }
        var result = state.pipeline
        var disposition = state.disposition
        var notes = state.notes + analysisNotes(facts)
        // Extra outputs are made from the processed image: a copy (or a skip) has none, nor has an image whose
        // branch said so.
        if state.skipExtras || disposition != .process { result.extraOutputs = [] }
        if disposition == .copyOriginal,
           Self.convertsCopy(&result, format: facts?.format, presetSteps: state.presetSteps, notes: &notes) {
            disposition = .process
        }
        if disposition == .copyOriginal {
            // A copy is the unchanged source: no image steps (so `{width}`/`{height}` give its own size), and
            // its own format where the app knows it (the rename context takes the extension from the file).
            result.steps = []
            if let format = facts?.format { result.output.format = format }
            let ignored = [(state.addedKeywords, "added keywords"), (state.addedPresetSteps, "the preset's image steps")]
                .filter(\.0).map(\.1)
            if !ignored.isEmpty { notes.append(ConditionalStep.ignoredForCopyPrefix + ignored.joined(separator: ", ")) }
        }
        var resolved = ResolvedPipeline(pipeline: result, disposition: disposition, notes: notes,
                                        subfolder: state.subfolder, finderTags: FinderTags.normalized(state.tags),
                                        noteTemplates: state.noteTemplates)
        resolved.labels = state.labels
        resolved.warning = analysisFailed(facts)
        return resolved
    }

    /// Only the Redact steps run on a converted copy: the note naming a preset's other steps, or nil.
    private static func notAppliedNote(_ presetSteps: [PipelineStep]) -> String? {
        var seen = Set<String>()
        let names = presetSteps.filter { $0.operation.kind != .redact }.map(\.operation.kind.displayName)
            .filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return nil }
        return ConditionalStep.notAppliedToConversionPrefix + "the preset's " + names.joined(separator: ", ")
            + (names.count == 1 ? " step" : " steps")
    }

    /// Whether a copied original must be converted instead, set up for that: a byte copy would show what an enabled
    /// Redact step hides (Redact is a floor like the Metadata step: only the Redact steps run) or keep what the
    /// Metadata step removes (nothing else runs). In the source's own format, with a note. False: copy it.
    /// Image steps a branch's preset added that don't run then are named in a note.
    private static func convertsCopy(_ result: inout Pipeline, format: OutputFormat?, presetSteps: [PipelineStep],
                                     notes: inout [String]) -> Bool {
        let redactions = result.steps.filter { $0.isEnabled && $0.operation.kind == .redact }
        let hidesMetadata = result.metadata.hidesSourceData
        // The metadata panel's changes are for this image's outputs, a copy included.
        let editsMetadata = !result.metadataOverrides.isEmpty
        guard !redactions.isEmpty || hidesMetadata || editsMetadata else { return false }
        result.steps = redactions
        result.output = .faithful(format ?? result.output.format)
        if !redactions.isEmpty { notes.append(Redaction.convertedToRedactNote) }
        if hidesMetadata { notes.append(ConditionalStep.convertedForPrivacyNote) }
        if editsMetadata, !hidesMetadata { notes.append(ConditionalStep.convertedForMetadataEditsNote) }
        if let note = notAppliedNote(presetSteps) { notes.append(note) }
        return true
    }

    /// True when content checks needed an image analysis that failed: the report flags that file.
    private func analysisFailed(_ facts: ItemFacts?) -> Bool {
        guard let facts, !factNeeds.isDisjoint(with: .analysis) else { return false }
        return facts.analysis.failure != nil
    }

    /// Why content checks couldn't be answered for `facts` (the analysis failed, or needs macOS 15).
    private func analysisNotes(_ facts: ItemFacts?) -> [String] {
        guard let facts, !factNeeds.isDisjoint(with: .analysis) else { return [] }
        if let failure = facts.analysis.failure { return [ImageAnalysis.unavailableNote(failure)] }
        // The flag may come from an earlier, cached read for an aesthetics check this pipeline no longer has.
        return facts.analysis.needsNewerSystem && conditionFactNeeds.contains(.aesthetics)
            ? [ImageAnalysis.needsNewerSystemNote] : []
    }

    /// Resolves for the file at `url`, reading its facts only when there are conditions (and only what they
    /// need: the transparency scan, XMP, frame count, image analysis from `analysis`), with the transparency scan
    /// and the analysis only within `maxPixels`.
    public func resolved(forSource url: URL, maxPixels: Int = ImageLoader.defaultMaxPixels,
                         presets: PresetLibrary = .standard, analysis: ImageAnalysisCache = .shared) -> ResolvedPipeline {
        guard needsFacts else { return ResolvedPipeline(pipeline: withoutConditions) }
        let facts = ItemFacts.read(url, needs: factNeeds, maxPixels: maxPixels, analysis: analysis)
        return resolved(for: facts, presets: presets)
    }

    /// This pipeline without its (disabled) condition steps, so a resolved pipeline never holds one.
    var withoutConditions: Pipeline {
        var copy = self
        copy.steps.removeAll { step in
            if case .condition = step.operation { return true }
            return false
        }
        return copy
    }
}

/// The pipeline being resolved for one image, with what its actions have chosen so far.
private struct Resolution {
    var pipeline: Pipeline
    let floor: MetadataOptions
    let presets: PresetLibrary
    /// What `{labels}` gives for this image.
    let labels: [String]
    var disposition = Disposition.process
    var notes: [String] = []
    var subfolder: String?
    var tags: [String] = []
    var noteTemplates: [String] = []
    var stopped = false
    var skipExtras = false
    /// What a copied original ignores (for its note).
    var addedKeywords = false
    /// The image steps "Apply preset" added, in order.
    var presetSteps: [PipelineStep] = []
    var addedPresetSteps: Bool { !presetSteps.isEmpty }

    init(pipeline: Pipeline, floor: MetadataOptions, presets: PresetLibrary, labels: [String]) {
        self.pipeline = pipeline
        self.floor = floor
        self.presets = presets
        self.labels = labels
    }

    // One case per action.
    // swiftlint:disable:next cyclomatic_complexity
    mutating func apply(_ action: ConditionalAction) {
        switch action {
        case .step(let inner):
            // Nesting is rejected on load; one built in code is ignored too.
            if case .condition = inner.operation { return }
            pipeline.steps.append(inner)
        case .output(let settings): pipeline.output = settings
        case .metadata(let options): setMetadata(options)
        case .rename(let options): setRename(options)
        case .copyOriginal: if disposition == .process { disposition = .copyOriginal }
        case .skip: disposition = .skip
        case .subfolder(let template): subfolder = template
        case .finderTags(let new): tags += LabelToken.expand(new, labels: labels)
        case .preset(let link): applyPreset(link)
        case .addKeywords(let keywords): addKeywords(keywords)
        case .stop: stopped = true
        case .note(let text): noteTemplates.append(text)
        case .skipExtraOutputs: skipExtras = true
        }
    }

    private mutating func setMetadata(_ options: MetadataOptions) {
        var options = options
        options.isIncluded = true
        options.isEnabled = true
        pipeline.metadata = options.withRemovals(from: floor)
    }

    private mutating func setRename(_ options: RenameOptions) {
        var options = options
        options.isIncluded = true
        options.isEnabled = true
        pipeline.rename = options
    }

    /// The preset's enabled image steps (never its conditions) go in here; its output always applies, and its
    /// Metadata and Rename steps when they are on. A preset that is gone only leaves a note.
    private mutating func applyPreset(_ link: PresetLink) {
        guard let preset = presets.preset(id: link.id) else {
            notes.append(link.missingNote)
            return
        }
        let applied = preset.pipeline
        let steps = applied.steps.filter { step in
            if case .condition = step.operation { return false }
            return step.isEnabled
        }
        pipeline.steps += steps
        presetSteps += steps
        pipeline.output = applied.output
        if applied.metadata.isActive { setMetadata(applied.metadata) }
        if applied.rename.isActive { setRename(applied.rename) }
    }

    /// Adds to the keywords the metadata settings already set (or to the file's own, in add mode); switches
    /// the Metadata step on with nothing else changed when it was off. The removals stay as they are.
    private mutating func addKeywords(_ keywords: [String]) {
        let added = LabelToken.expand(keywords, labels: labels)
        // Nothing to add (only `{labels}` and no labels): the Metadata step stays as it is.
        guard !added.isEmpty else { return }
        if !pipeline.metadata.isActive {
            var options = MetadataOptions(isEnabled: true, location: .keep)
            options.keywordsMode = .add
            pipeline.metadata = options.withRemovals(from: floor)
        }
        pipeline.metadata.keywords = MetadataFields.normalizedKeywords((pipeline.metadata.keywords ?? []) + added)
        addedKeywords = true
    }
}
