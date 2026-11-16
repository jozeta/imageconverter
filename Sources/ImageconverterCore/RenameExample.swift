import Foundation

extension RenameContext {
    /// The built-in sample used for the live example when no image is loaded.
    public static func sample(format: OutputFormat, outputSize: (width: Int, height: Int), counter: Int) -> RenameContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? .current
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 13, hour: 14, minute: 5, second: 9))
        return RenameContext(
            name: "IMG_0001", ext: format.fileExtensions.first ?? "", format: format.displayName,
            folder: "Photos", date: date, make: "Apple", model: "iPhone 15 Pro",
            lens: "iPhone 15 Pro back camera 6.765mm f/1.78", iso: 80,
            width: outputSize.width, height: outputSize.height, counter: counter,
            focalLength: 24, aperture: 1.78, exposureTime: 1.0 / 120)
            .withSampleFileFacts(date)
    }

    /// The sample's file dates, extension, labels and seed.
    private func withSampleFileFacts(_ date: Date?) -> RenameContext {
        var context = self
        context.created = date
        context.modified = date
        context.sourceExtension = "heic"
        context.labels = ["dog", "grass"]
        context.seed = "/Photos/IMG_0001.HEIC"
        return context
    }
}

/// The live "Example: ..." for the rename pattern. Pure: the caller reads the file.
public enum RenameExample {
    /// "<base>.<ext>" for the image at `index` in the batch (counter = start + index), or for a built-in sample when there is no `source`.
    /// An unreadable header means a 4032 x 3024 source. `isCopy`: the image is copied unchanged, so `{ext}`,
    /// `{format}` and the extension are the source's own, as in the batch (`RenameRendering`).
    /// `modified` is the file's modification date (`{modified}`); `labels` what `{labels}` gives (the resolved
    /// item's labels; the sample shows "dog" and "grass").
    public static func render(source: URL?, header: ImageHeader?, created: Date?, modified: Date? = nil,
                              pipeline: Pipeline, index: Int = 0, isCopy: Bool = false,
                              labels: [String] = []) -> String {
        let format = pipeline.output.format
        let template = RenameTemplate(pipeline.rename.pattern)
        let counter = pipeline.rename.counter(at: index)
        let upright = header?.uprightSize ?? (width: 4032, height: 3024)
        let output = pipeline.outputSize(sourceWidth: upright.width, sourceHeight: upright.height)
        var context: RenameContext
        if let source {
            context = RenameContext.make(
                source: source, header: header, outputSize: (output.width, output.height), format: format,
                counter: counter, fileCreationDate: template.needsDate ? created : nil,
                fileModificationDate: template.needsDate ? modified : nil)
            context.labels = labels
            if isCopy { RenameRendering.describeCopy(of: source, in: &context) }
        } else {
            context = RenameContext.sample(format: format, outputSize: output, counter: counter)
        }
        context.preset = pipeline.presetName
        return "\(pipeline.rename.render(template, context)).\(context.ext)"
    }
}
