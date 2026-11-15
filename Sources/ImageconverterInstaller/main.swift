import Foundation
import ImageconverterInstallerKit

// The installer XPC service (Contents/XPCServices/io.github.jozeta.imageconverter.installer.xpc): not sandboxed,
// accepts only the containing app (see `InstallerListenerDelegate`). All logic is in ImageconverterInstallerKit.
let delegate = InstallerListenerDelegate(service: InstallerService(environment: .live))
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
