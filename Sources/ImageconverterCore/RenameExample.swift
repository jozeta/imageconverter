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
            width: outputSize.width, height: outputSize.height, counter: counter)
    }
}

/// The live "Example: ..." for the rename pattern. Pure: the caller reads the file.
public enum RenameExample {
    /// "<base>.<ext>" for the image at `index` in the batch (counter = start + index), or for a built-in sample when there is no `source`.
    /// An unreadable header means a 4032 x 3024 source.
    public static func render(source: URL?, header: ImageHeader?, created: Date?, pipeline: Pipeline,
                              index: Int = 0) -> String {
        let format = pipeline.output.format
        let template = RenameTemplate(pipeline.rename.pattern)
        let (sum, overflow) = pipeline.rename.counterStart.addingReportingOverflow(max(0, index))
        let counter = overflow ? Int.max : sum
        let upright = header?.uprightSize ?? (width: 4032, height: 3024)
        let output = pipeline.outputSize(sourceWidth: upright.width, sourceHeight: upright.height)
        let context: RenameContext
        if let source {
            context = RenameContext.make(
                source: source, header: header, outputSize: (output.width, output.height), format: format,
                counter: counter, fileCreationDate: template.needsDate ? created : nil)
        } else {
            context = RenameContext.sample(format: format, outputSize: output, counter: counter)
        }
        return "\(template.render(context)).\(context.ext)"
    }
}
