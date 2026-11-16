import Foundation

/// Renders the rename template for one item. The batch and the preview both use it, so the
/// preview's file name is always the name the batch would write.
enum RenameRendering {
    /// The base name (no extension) for the item at `index`, or nil when renaming is off. `pipeline` is the
    /// item's resolved pipeline (conditions can change its rename and format), and `index` skips skipped items.
    /// The counter is `RenameOptions.counter(at:)` (start + index × step, saturating, never below 0). The header
    /// and the file dates are only read when the template uses them. `labels` is what `{labels}` gives (the
    /// resolved item's `labels`).
    /// `isCopy`: the item is copied unchanged, so `{ext}` and `{format}` describe the source file itself
    /// (its extension lower-cased; the pipeline of a copy has no image steps, so the size is the source's).
    static func baseName(for item: InputItem, index: Int, pipeline: Pipeline, isCopy: Bool = false,
                         labels: [String] = []) -> String? {
        checkedBaseName(for: item, index: index, pipeline: pipeline, isCopy: isCopy, labels: labels)?.name
    }

    /// As `baseName`, with whether a find-and-replace pattern was stopped for taking too long.
    static func checkedBaseName(for item: InputItem, index: Int, pipeline: Pipeline,
                                isCopy: Bool = false, labels: [String] = []) -> (name: String, timedOut: Bool)? {
        guard pipeline.rename.isActive else { return nil }
        let template = RenameTemplate(pipeline.rename.pattern)
        let context = context(for: item, index: index, pipeline: pipeline, isCopy: isCopy, templates: [template],
                              labels: labels)
        return pipeline.rename.renderChecked(template, context)
    }

    // swiftlint:disable function_parameter_count
    /// The values `templates` can draw on for the item: the header and the file dates are only read when one
    /// of them uses them.
    static func context(for item: InputItem, index: Int, pipeline: Pipeline, isCopy: Bool,
                        templates: [RenameTemplate], labels: [String]) -> RenameContext {
        let header = templates.contains(where: \.needsHeader) ? ImageLoader.header(of: item.source) : nil
        let upright = header?.uprightSize ?? (width: 1, height: 1)
        let size = pipeline.outputSize(sourceWidth: upright.width, sourceHeight: upright.height)
        let dates = templates.contains(where: \.needsDate)
            ? try? item.source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) : nil
        var context = RenameContext.make(
            source: item.source, header: header, outputSize: size, format: pipeline.output.format,
            counter: pipeline.rename.counter(at: index), fileCreationDate: dates?.creationDate,
            fileModificationDate: dates?.contentModificationDate)
        context.preset = pipeline.presetName
        context.labels = labels
        if isCopy { describeCopy(of: item.source, in: &context) }
        return context
    }
    // swiftlint:enable function_parameter_count

    /// The rendered subfolder (folder names, outermost first) and report notes of a resolved item; nothing is
    /// read when it has neither.
    static func extras(for item: InputItem, index: Int, job: ResolvedPipeline) -> (subfolder: [String], notes: [String]) {
        let folder = job.subfolder.map(SubfolderTemplate.parts) ?? []
        let notes = job.noteTemplates.map(RenameTemplate.init)
        guard !folder.isEmpty || !notes.isEmpty else { return ([], []) }
        let context = context(for: item, index: index, pipeline: job.pipeline, isCopy: job.disposition == .copyOriginal,
                              templates: folder + notes, labels: job.labels)
        return (SubfolderTemplate.render(folder, context), notes.map { $0.renderText(context) }.filter { !$0.isEmpty })
    }

    /// The rendered subfolder of each of the item's extra outputs (empty for none); nothing is read when no extra
    /// output has one. Tokens describe the primary output (its size and format).
    static func variantFolders(for item: InputItem, index: Int, job: ResolvedPipeline) -> [[String]] {
        // A `.subfolder` destination's folders come first (inside the original's folder), then the output's own.
        let parts = job.pipeline.extraOutputs.map { variant in
            (variant.destination?.subfolderTemplate.map(SubfolderTemplate.parts) ?? [])
                + (variant.effectiveSubfolder.map(SubfolderTemplate.parts) ?? [])
        }
        guard parts.contains(where: { !$0.isEmpty }) else { return parts.map { _ in [] } }
        let context = context(for: item, index: index, pipeline: job.pipeline, isCopy: false,
                              templates: parts.flatMap { $0 }, labels: job.labels)
        return parts.map { SubfolderTemplate.render($0, context) }
    }

    /// A copy keeps the source's own extension (lower-cased) and format name.
    static func describeCopy(of source: URL, in context: inout RenameContext) {
        let ext = source.pathExtension.lowercased()
        context.ext = ext
        context.format = OutputFormat.allCases.first { $0.fileExtensions.contains(ext) }?.displayName ?? ext.uppercased()
    }
}
