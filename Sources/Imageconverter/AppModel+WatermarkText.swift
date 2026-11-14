import Foundation
import ImageconverterCore

extension AppModel {
    /// The image the watermark editor shows its token text for: the selected one.
    var watermarkSampleSource: URL? { selectedItemIndex.map { items[$0].source } }

    /// `template` with its tokens filled in for `source`, built the way the batch builds it
    /// (`WatermarkTextContext.make` with the header properties and the pipeline's Metadata step). Reads the
    /// file's header off the main actor.
    nonisolated static func watermarkText(_ template: String, source: URL, metadata: MetadataOptions) async -> String {
        await Task.detached(priority: .userInitiated) {
            let properties = ImageLoader.header(of: source)?.properties ?? [:]
            let created = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let context = WatermarkTextContext.make(source: source, properties: properties, metadata: metadata,
                                                    fileCreationDate: created)
            return WatermarkText.render(template, context: context)
        }.value
    }
}
