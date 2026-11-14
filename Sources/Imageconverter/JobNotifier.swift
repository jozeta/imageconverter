import Foundation
@preconcurrency import UserNotifications

/// Notifications for background job runs. Permission is asked once, when a watch job is first switched on;
/// a refusal (or no answer) just means no notifications, never a blocked job.
@MainActor
final class JobNotifier {
    private let defaults: UserDefaults
    private static let askedKey = "jobNotificationsAsked"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `UNUserNotificationCenter` needs an app bundle; `swift run` has none (and would crash on `current()`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestPermissionIfNeeded() {
        guard !defaults.bool(forKey: Self.askedKey), let center else { return }
        defaults.set(true, forKey: Self.askedKey)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts when allowed; silently does nothing otherwise.
    func post(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            center.add(request) { _ in }
        }
    }
}
