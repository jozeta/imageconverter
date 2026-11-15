import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Notifications for background job runs. Permission is asked once, when a watch job is first switched on;
/// a refusal (or no answer) just means no notifications, never a blocked job.
@MainActor
final class JobNotifier {
    /// The app's one notifier (jobs and manual runs).
    static let shared = JobNotifier(defaults: AppDefaults.store)
    /// `userInfo["kind"]` values, read by `NotificationRouter`.
    nonisolated static let kindKey = "kind"
    nonisolated static let runKind = "run"
    nonisolated static let jobKind = "job"
    private let defaults: UserDefaults
    private static let askedKey = "jobNotificationsAsked"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `UNUserNotificationCenter` needs an app bundle; `swift run` has none (and would crash on `current()`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestPermissionIfNeeded(completion: (@Sendable () -> Void)? = nil) {
        guard !defaults.bool(forKey: Self.askedKey), let center else { completion?(); return }
        defaults.set(true, forKey: Self.askedKey)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in completion?() }
    }

    /// True when the user has refused notifications for the app (or turned them off in System Settings).
    func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    /// Posts when allowed; silently does nothing otherwise.
    func post(title: String, body: String, kind: String = JobNotifier.jobKind) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.kindKey: kind]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            center.add(request) { _ in }
        }
    }
}

/// Clicks on notifications: a manual run's brings the main window forward with its report open; a job's just
/// brings the app forward. Set once at launch.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    @MainActor static func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo[JobNotifier.kindKey] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                if kind == JobNotifier.runKind {
                    for window in NSApp.windows where window.canBecomeMain && window.isVisible == false { window.deminiaturize(nil) }
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                    ExternalActions.shared.model?.reportRequest += 1
                }
            }
            completionHandler()
        }
    }
}
