import AppKit
import Observation
import ImageconverterCore

/// Update state for the About window and the update sheets. Nothing goes online before the user says so: at the
/// first launch it asks once whether to check when the app starts (`updateCheckOnLaunch`, absent until answered);
/// Check Now always works. A launch check is silent when up to date or on an error; Check Now reports both.
@MainActor @Observable
final class UpdateController {
    static let shared = UpdateController(defaults: AppDefaults.store)
    static let launchKey = "updateCheckOnLaunch"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(AppVersion)
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case failed(String)
    }

    /// What the main window shows as its update sheet (one at a time, never over the interrupted-batch sheet).
    enum MainSheet: String, Identifiable {
        case launchQuestion, offer
        var id: String { rawValue }
    }

    private(set) var status: Status = .idle
    /// The release offered in the update sheet.
    private(set) var offer: UpdateRelease?
    /// Where the offer sheet is shown: the About window after Check Now, else the main window.
    private(set) var offerInAbout = false
    var showsLaunchQuestion = false
    /// Set by the app: whether a batch or a job is running (installing is refused then).
    @ObservationIgnored var isRunning: () -> Bool = { false }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var workFolder: URL?
    @ObservationIgnored private var launched = false

    /// The stored answer; nil until the first-launch question was answered.
    private(set) var launchAnswer: Bool?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        launchAnswer = defaults.object(forKey: Self.launchKey) as? Bool
    }

    /// The About window's checkbox.
    var checkOnLaunch: Bool {
        get { launchAnswer ?? false }
        set {
            launchAnswer = newValue
            defaults.set(newValue, forKey: Self.launchKey)
        }
    }

    /// The main window's update sheet right now.
    var mainSheet: MainSheet? {
        if showsLaunchQuestion { return .launchQuestion }
        return offer != nil && !offerInAbout ? .offer : nil
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    // MARK: Launch

    /// Once per launch, when the main window appears: ask, check silently, or nothing.
    func launch() {
        guard !launched else { return }
        launched = true
        UpdateVerifier.removeStaleFolders()
        switch UpdateInstallPlan.shouldCheckOnLaunch(answer: launchAnswer) {
        case .ask: showsLaunchQuestion = true
        case .check: check(reporting: false)
        case .skip: break
        }
    }

    func answerLaunchQuestion(_ yes: Bool) {
        checkOnLaunch = yes
        showsLaunchQuestion = false
        if yes { check(reporting: false) }
    }

    // MARK: Check

    func checkNow() { check(reporting: true) }

    private func check(reporting: Bool) {
        guard !isBusy else { return }
        guard let current = AppVersion(AppInfo.version) else {
            if reporting { status = .failed("This build's version (\(AppInfo.version)) can't be compared.") }
            return
        }
        status = .checking
        task = Task {
            do {
                let release = try await UpdateClient.latestRelease(current: current)
                guard !Task.isCancelled else { return }
                if let release {
                    status = .available(release.version)
                    offer = release
                    offerInAbout = reporting
                } else {
                    status = reporting ? .upToDate(current.description) : .idle
                }
            } catch is CancellationError {
                status = .idle
            } catch {
                status = reporting ? .failed(Self.message(error)) : .idle
            }
        }
    }

    // MARK: Install

    /// Install and Relaunch: download, check, replace, relaunch. Refused up front outside the app bundle or while
    /// something runs; any failure leaves the installed app as it was and deletes the download.
    func install() {
        guard let release = offer, !isBusy else { return }
        do {
            try UpdateInstaller.checkAllowed(isRunning: isRunning())
        } catch {
            status = .failed(Self.message(error))
            return
        }
        status = .downloading(received: 0, total: Int64(-1))
        task = Task {
            var work: URL?
            do {
                let folder = try UpdateVerifier.makeWorkFolder()
                work = folder
                workFolder = folder
                let download = try await UpdateClient.download(release, into: folder) { received, total in
                    Task { @MainActor in self.progress(received: received, total: total) }
                }
                try Task.checkCancellation()
                status = .verifying
                let app = try await UpdateVerifier.verify(zip: download.zip, sha256: download.sha256, version: release.version,
                                                          in: folder)
                // Later while checking: the check itself can't be stopped, but nothing is installed.
                try Task.checkCancellation()
                status = .installing
                try await UpdateInstaller.install(app, isRunning: isRunning)
                UpdateVerifier.remove(folder)
                UpdateInstaller.relaunch { message in self.status = .failed(message) }
            } catch is CancellationError {
                UpdateVerifier.remove(work)
                status = .available(release.version)
            } catch {
                UpdateVerifier.remove(work)
                status = .failed(Self.message(error))
            }
            workFolder = nil
        }
    }

    private func progress(received: Int64, total: Int64) {
        guard case .downloading = status else { return }
        status = .downloading(received: received, total: total)
    }

    /// Later: closes the sheet; a download in progress is stopped and deleted.
    func later() {
        if case .installing = status { return }
        task?.cancel()
        task = nil
        UpdateVerifier.remove(workFolder)
        workFolder = nil
        if let offer { status = .available(offer.version) }
        offer = nil
    }

    // MARK: Wording

    var statusText: String? {
        switch status {
        case .idle: nil
        case .checking: "Checking…"
        case .upToDate(let version): "You're up to date (\(version))."
        case .available(let version): "Version \(version) is available."
        case let .downloading(received, total):
            total > 0 ? "Downloading… \(Self.bytes(received)) of \(Self.bytes(total))" : "Downloading… \(Self.bytes(received))"
        case .verifying: "Checking the download…"
        case .installing: "Installing…"
        case .failed(let message): message
        }
    }

    var isFailure: Bool {
        if case .failed = status { return true }
        return false
    }

    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private static func message(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }
}
