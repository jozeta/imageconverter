import Foundation

/// Renders the rename template for one item. The batch and the preview both use it, so the
/// preview's file name is always the name the batch would write.
enum RenameRendering {
    /// The base name (no extension) for the item at `index`, or nil when renaming is off. `pipeline` is the
    /// item's resolved pipeline (conditions can change its rename and format), and `index` skips skipped items.
    /// The counter is `counterStart + index`, saturating. The header and creation date are only
    /// read when the template uses them.
    /// `isCopy`: the item is copied unchanged, so `{ext}` and `{format}` describe the source file itself
    /// (its extension lower-cased; the pipeline of a copy has no image steps, so the size is the source's).
    static func baseName(for item: InputItem, index: Int, pipeline: Pipeline, isCopy: Bool = false) -> String? {
        guard pipeline.rename.isActive else { return nil }
        let template = RenameTemplate(pipeline.rename.pattern)
        let header = template.needsHeader ? ImageLoader.header(of: item.source) : nil
        let upright = header?.uprightSize ?? (width: 1, height: 1)
        let size = pipeline.outputSize(sourceWidth: upright.width, sourceHeight: upright.height)
        let created = template.needsDate
            ? (try? item.source.resourceValues(forKeys: [.creationDateKey]))?.creationDate : nil
        let (counter, overflow) = pipeline.rename.counterStart.addingReportingOverflow(index)
        var context = RenameContext.make(
            source: item.source, header: header, outputSize: size, format: pipeline.output.format,
            counter: overflow ? Int.max : counter, fileCreationDate: created)
        if isCopy { describeCopy(of: item.source, in: &context) }
        return pipeline.rename.render(template, context)
    }

    /// A copy keeps the source's own extension (lower-cased) and format name.
    static func describeCopy(of source: URL, in context: inout RenameContext) {
        let ext = source.pathExtension.lowercased()
        context.ext = ext
        context.format = OutputFormat.allCases.first { $0.fileExtensions.contains(ext) }?.displayName ?? ext.uppercased()
    }
}
