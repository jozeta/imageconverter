import Dispatch
import Foundation
import ImageconverterCLIKit

// Ctrl-C cancels the batch instead of killing the process, so in-flight files finish or are dropped cleanly
// (no temp files left) and the partial report is printed; the exit code is then 130.
let cancel = CancelToken()
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler { cancel.cancel() }
interrupt.resume()

exit(await CLIRunner.main(Array(CommandLine.arguments.dropFirst()), environment: .standard(cancel: cancel)))
