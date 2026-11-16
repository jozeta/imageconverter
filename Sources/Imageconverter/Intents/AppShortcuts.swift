import AppIntents

/// The actions Shortcuts and Spotlight offer without building a shortcut first. Every phrase names the app.
struct ImageconverterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertImagesIntent(),
                    phrases: ["Convert images with \(.applicationName)", "Convert images in \(.applicationName)"],
                    shortTitle: "Convert Images", systemImageName: "photo.on.rectangle.angled")
        AppShortcut(intent: ApplyPresetToFolderIntent(),
                    phrases: ["Apply a preset to a folder with \(.applicationName)"],
                    shortTitle: "Apply Preset to Folder", systemImageName: "folder")
        AppShortcut(intent: RunJobIntent(),
                    phrases: ["Run a job in \(.applicationName)", "Run \(\.$job) in \(.applicationName)"],
                    shortTitle: "Run Job", systemImageName: "play.circle")
        AppShortcut(intent: StripMetadataIntent(),
                    phrases: ["Strip metadata with \(.applicationName)", "Remove metadata with \(.applicationName)"],
                    shortTitle: "Strip Metadata", systemImageName: "eye.slash")
        AppShortcut(intent: ResizeImagesIntent(),
                    phrases: ["Resize images with \(.applicationName)"],
                    shortTitle: "Resize Images", systemImageName: "arrow.up.left.and.arrow.down.right")
        AppShortcut(intent: ConvertFormatIntent(),
                    phrases: ["Convert image format with \(.applicationName)"],
                    shortTitle: "Convert Format", systemImageName: "doc.on.doc")
        AppShortcut(intent: GetImageMetadataIntent(),
                    phrases: ["Get image metadata with \(.applicationName)"],
                    shortTitle: "Get Image Metadata", systemImageName: "info.circle")
    }
}
