import Foundation

/// One entry of the Rename step's Insert menu: what it is called and the token it adds.
public struct RenameTokenItem: Equatable, Sendable {
    public let title: String
    public let token: String

    init(_ title: String, _ token: String) {
        self.title = title
        self.token = token
    }
}

/// A group of the Insert menu.
public struct RenameTokenSection: Equatable, Sendable {
    public let title: String
    public let items: [RenameTokenItem]
}

extension RenameTemplate {
    /// The Insert menu, grouped. Every known token appears at least once (a test checks it); formatted tokens carry
    /// an example argument. Dates are wall clocks: the date taken (or the file's creation date when there is none),
    /// and the file's own creation and modification dates.
    public static let tokenMenu: [RenameTokenSection] = [
        RenameTokenSection(title: "File", items: [
            RenameTokenItem("Original name", "{name}"),
            RenameTokenItem("Output extension", "{ext}"),
            RenameTokenItem("Original extension", "{srcext}"),
            RenameTokenItem("Output format", "{format}"),
            RenameTokenItem("Parent folder name", "{folder}"),
            RenameTokenItem("Preset name", "{preset}"),
        ]),
        RenameTokenSection(title: "Date taken", items: [
            RenameTokenItem("Date taken (2026-11-13)", "{date:yyyy-MM-dd}"),
            RenameTokenItem("Date taken (20261113)", "{date:yyyyMMdd}"),
            RenameTokenItem("Date taken (13.11.2026)", "{date:dd.MM.yyyy}"),
            RenameTokenItem("Year taken", "{date:yyyy}"),
            RenameTokenItem("Month taken (11)", "{date:MM}"),
            RenameTokenItem("Month name taken", "{date:MMMM}"),
            RenameTokenItem("Time taken (140509)", "{time:HHmmss}"),
            RenameTokenItem("Date and time taken", "{datetime}"),
        ]),
        RenameTokenSection(title: "File dates", items: [
            RenameTokenItem("Date modified", "{modified:yyyy-MM-dd}"),
            RenameTokenItem("Date and time modified", "{modified:yyyy-MM-dd_HHmmss}"),
            RenameTokenItem("File created", "{created:yyyy-MM-dd}"),
            RenameTokenItem("File created, with time", "{created:yyyy-MM-dd_HHmmss}"),
        ]),
        RenameTokenSection(title: "Camera", items: [
            RenameTokenItem("Camera model", "{camera}"),
            RenameTokenItem("Camera make", "{make}"),
            RenameTokenItem("Lens", "{lens}"),
            RenameTokenItem("ISO", "{iso}"),
            RenameTokenItem("Focal length", "{focal}"),
            RenameTokenItem("Aperture", "{aperture}"),
            RenameTokenItem("Shutter speed", "{shutter}"),
        ]),
        RenameTokenSection(title: "Image", items: [
            RenameTokenItem("Width", "{width}"),
            RenameTokenItem("Height", "{height}"),
            RenameTokenItem("Megapixels", "{megapixels}"),
            RenameTokenItem("Orientation", "{orientation}"),
            RenameTokenItem("What the image shows (analysed on this Mac)", "{labels:-}"),
        ]),
        RenameTokenSection(title: "Counter and unique", items: [
            RenameTokenItem("Counter", "{counter}"),
            RenameTokenItem("Counter, 2 digits", "{counter:00}"),
            RenameTokenItem("Counter, 3 digits", "{counter:000}"),
            RenameTokenItem("Counter, 4 digits", "{counter:0000}"),
            RenameTokenItem("Sequence (same as counter)", "{seq}"),
            RenameTokenItem("Random, 4 characters", "{random:4}"),
            RenameTokenItem("Random, 8 characters", "{random:8}"),
            RenameTokenItem("UUID", "{uuid}"),
        ]),
    ]
}
