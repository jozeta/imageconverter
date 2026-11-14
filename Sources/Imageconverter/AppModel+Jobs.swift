import Foundation
import ImageconverterCore

extension AppModel {
    /// A new job with a copy of the pipeline being edited and the main window's Save to setting; no folders yet.
    /// A preset that is selected and unmodified is linked instead, so later edits to it reach the job.
    func newJobDraft(settings: AppSettings, existingNames: [String]) -> Job {
        let base = session.selected.map { "\($0.name) job" } ?? "New job"
        var name = base
        var number = 2
        let taken = Set(existingNames.map { $0.lowercased() })
        while taken.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        let linked = session.isModified ? nil : session.selected?.id
        let output = settings.outputMode ?? .sameFolder(suffix: settings.sameFolderSuffix)
        return Job(name: name, pipeline: pipeline, presetID: linked, output: output, trigger: .watch, report: .csv)
    }
}
