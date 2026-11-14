import Foundation

/// Renders the rename template for one item. The batch and the preview both use it, so the
/// preview's file name is always the name the batch would write.
enum RenameRendering {
    /// The base name (no extension) for the item at `index`, or nil when renaming is off.
    /// The counter is `counterStart + index`, saturating. The header and creation date are only
    /// read when the template uses them.
    static func baseName(for item: InputItem, index: Int, pipeline: Pipeline) -> String? {
        guard pipeline.rename.isActive else { return nil }
        let template = RenameTemplate(pipeline.rename.pattern)
        let header = template.needsHeader ? ImageLoader.header(of: item.source) : nil
        let upright = header?.uprightSize ?? (width: 1, height: 1)
        let size = pipeline.outputSize(sourceWidth: upright.width, sourceHeight: upright.height)
        let created = template.needsDate
            ? (try? item.source.resourceValues(forKeys: [.creationDateKey]))?.creationDate : nil
        let (counter, overflow) = pipeline.rename.counterStart.addingReportingOverflow(index)
        let context = RenameContext.make(
            source: item.source, header: header, outputSize: size, format: pipeline.output.format,
            counter: overflow ? Int.max : counter, fileCreationDate: created)
        return pipeline.rename.render(template, context)
    }
}
