import Foundation
import ImageconverterCore

// MARK: - Rename example

extension AppModel {

    /// What the live example depends on; when it changes the example is recomputed.
    var renameExampleKey: RenameExampleKey {
        RenameExampleKey(
            exampleItem: selectedItemIndex.map { items[$0].source }, index: selectedItemIndex ?? 0, pattern: pipeline.rename.pattern,
            counterStart: pipeline.rename.counterStart,
            replacements: pipeline.rename.replacements,
            prefix: pipeline.rename.prefix, suffix: pipeline.rename.suffix, removeSpaces: pipeline.rename.removeSpaces,
            specialCharacters: pipeline.rename.specialCharacters, replacement: pipeline.rename.replacement,
            caseStyle: pipeline.rename.caseStyle,
            format: pipeline.output.format, steps: pipeline.steps)
    }

    /// Renders the rename pattern for the selected image (the first by default, or a built-in sample when there are none).
    /// The file is read off the main actor; the header is kept per file and the result per key.
    func refreshRenameExample() async {
        let key = renameExampleKey
        if let cached = exampleCache, cached.key == key {
            renameExample = cached.text
            return
        }
        var pipeline = self.pipeline
        var index = key.index
        var skipped = false
        var isCopy = false
        var fromCondition = false
        // With conditions the example uses this image's branch (its rename, format and copy) and its counter
        // number in the batch, exactly like the preview's output name.
        if pipeline.hasConditions, let selected = selectedItemIndex,
           let conditions = await factsCache.preview(of: selected, in: items, pipeline: pipeline) {
            guard !Task.isCancelled else { return }
            index = conditions.counterIndex
            skipped = conditions.resolved.disposition == .skip
            isCopy = conditions.resolved.disposition == .copyOriginal
            fromCondition = conditions.resolved.pipeline.rename != pipeline.rename
            pipeline = conditions.resolved.pipeline
        }
        let known = exampleSource.flatMap { $0.url == key.exampleItem ? $0.info : nil }
        let (info, rendered) = await Task.detached(priority: .userInitiated) { [pipeline, index, isCopy] in
            Self.renderExample(url: key.exampleItem, known: known, pipeline: pipeline, index: index, isCopy: isCopy)
        }.value
        let text = skipped ? "\(ConditionalStep.skippedReason): this image isn't written"
            : (fromCondition ? "\(rendered) (a condition's rename)" : rendered)
        guard !Task.isCancelled else { return }
        if let url = key.exampleItem, let info { exampleSource = (url, info) }
        exampleCache = (key, text)
        renameExample = text
    }

    /// Reads the header and creation date only when the template uses them (cached per file once read).
    nonisolated private static func renderExample(
        url: URL?, known: RenameSource?, pipeline: Pipeline, index: Int, isCopy: Bool
    ) -> (RenameSource?, String) {
        let template = RenameTemplate(pipeline.rename.pattern)
        var info = known
        if let url, known == nil, template.needsHeader || template.needsDate {
            info = RenameSource(
                header: ImageLoader.header(of: url),
                created: (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
        }
        let name = RenameExample.render(source: url, header: info?.header, created: info?.created, pipeline: pipeline,
                                        index: index, isCopy: isCopy)
        return (info, "Example: \(name)")
    }
}

/// The part of a source image the rename example needs; read once per file.
struct RenameSource: @unchecked Sendable {
    let header: ImageHeader?
    let created: Date?
}

struct RenameExampleKey: Equatable {
    let exampleItem: URL?
    let index: Int
    let pattern: String
    let counterStart: Int
    let replacements: [ReplacementRule]
    let prefix: String
    let suffix: String
    let removeSpaces: Bool
    let specialCharacters: SpecialCharacters
    let replacement: String
    let caseStyle: CaseStyle
    let format: OutputFormat
    let steps: [PipelineStep]
}
