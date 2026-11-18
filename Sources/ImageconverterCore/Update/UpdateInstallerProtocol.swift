import Foundation

/// The XPC interface of the installer service (`Contents/XPCServices/io.github.jozeta.imageconverter.installer.xpc`),
/// which unpacks, checks and installs an update outside the App Sandbox (files a sandboxed process creates are
/// quarantined so that they can't be opened). Minimal on purpose; the service trusts none of its arguments.
@objc public protocol UpdateInstallerProtocol {
    /// Installs the zip at `zipPath` (in the app's container) if it matches `expectedSHA256` and holds a correctly
    /// signed and notarized `imageconverter.app` of `version`. The reply is `(error, note)`: `error` is nil on
    /// success, else a message for the user; `note` is set when the install worked but needs telling (the old
    /// version could not be removed and is still on disk).
    func install(zipPath: String, expectedSHA256: String, version: String, reply: @escaping (String?, String?) -> Void)
    /// Removes the service's temporary folders and leftovers of an interrupted install.
    func cleanUp(reply: @escaping () -> Void)
}

/// The installer service's names.
public enum UpdateInstallerService {
    public static let name = "io.github.jozeta.imageconverter.installer"
    public static let bundleName = name + ".xpc"
}
