import Dispatch
import Foundation
import ImageconverterCLIKit
import ImageconverterCore

// Ctrl-C, `kill` (SIGTERM) and a closed terminal (SIGHUP) cancel the batch instead of killing the process, so
// in-flight files finish or are dropped cleanly (no temp files left) and the partial report is printed; the exit
// code is then 130. A second signal exits at once (130) after removing the temp files this process is writing.
let cancel = CancelToken()
let policy = InterruptPolicy(cancel: cancel)
let signalSources: [DispatchSourceSignal] = InterruptPolicy.handledSignals.map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        if case .exitNow(let code) = policy.signalReceived() {
            FileCommitter.removeOwnTemps()
            exit(code)
        }
    }
    source.resume()
    return source
}

exit(await CLIRunner.main(Array(CommandLine.arguments.dropFirst()), environment: .standard(cancel: cancel)))
