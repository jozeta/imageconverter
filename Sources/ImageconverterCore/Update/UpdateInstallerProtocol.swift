import Foundation

/// The XPC interface of the installer service (`Contents/XPCServices/io.github.jozeta.imageconverter.installer.xpc`),
/// which unpacks, checks and installs an update outside the App Sandbox (files a sandboxed process creates are
/// quarantined so that they can't be opened). Minimal on purpose; the service trusts none of its arguments.
@objc public protocol UpdateInstallerProtocol {
    /// Installs the zip at `zipPath` (in the app's container) if it matches `expectedSHA256` and holds a correctly
    /// signed and notarized `imageconverter.app` of `version`. `reply(nil)` on success, else a message for the user.
    func install(zipPath: String, expectedSHA256: String, version: String, reply: @escaping (String?) -> Void)
    /// Removes the service's temporary folders and leftovers of an interrupted install.
    func cleanUp(reply: @escaping () -> Void)
}

/// The installer service's names.
public enum UpdateInstallerService {
    public static let name = "io.github.jozeta.imageconverter.installer"
    public static let bundleName = name + ".xpc"
}
