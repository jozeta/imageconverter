import Foundation
import ImageconverterCore

/// Fixed rules of the installer service.
public enum InstallerPolicy {
    /// Who may connect: only the containing app, signed with the developer's Developer ID. A build made with
    /// `swift build -Xswiftc -DUPDATE_E2E` (only for the end-to-end test of an ad hoc build with the bundle identifier
    /// `io.github.jozeta.imageconverter.updatetest`) accepts that identifier instead. There is no runtime override.
    #if UPDATE_E2E
    public static let clientRequirement = "identifier \"io.github.jozeta.imageconverter.updatetest\""
    #else
    public static let clientRequirement = "anchor apple generic and identifier \"\(UpdatePolicy.bundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(UpdatePolicy.teamIdentifier)\""
    #endif

    /// The service's own temporary folders.
    public static let workFolderPrefix = "imageconverter-installer-"
    /// The app's download folders in its container's `tmp` (`UpdateVerifier.folderPrefix` in the app).
    public static let clientFolderPrefix = "imageconverter-update-"
}
