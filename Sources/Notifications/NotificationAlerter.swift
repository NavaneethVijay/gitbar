import AppKit
import UserNotifications

/// macOS system alerts for new inbox items, and routing a click on one back
/// into the app. Owns the `UNUserNotificationCenter` delegate, so it must
/// exist from launch for clicks on alerts posted in an earlier run to land.
@MainActor
final class NotificationAlerter: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the clicked alert's inbox entry id (see `post`).
    var onOpen: ((_ entryID: String, _ fallbackURL: URL?) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuthorization = false

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks once per launch; macOS itself only ever prompts the user once.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func post(_ entry: NotificationStore.Entry) {
        let content = UNMutableNotificationContent()
        content.title = "\(entry.item.reason.label) · \(entry.item.repoPath)"
        content.body = entry.item.title
        content.sound = .default
        content.threadIdentifier = entry.item.repoPath
        content.userInfo = ["entryID": entry.id, "url": entry.item.webURL?.absoluteString ?? ""]
        center.add(UNNotificationRequest(identifier: entry.id, content: content, trigger: nil))
    }

    /// The alert for a thread that's been read — no point leaving it around.
    func removeDelivered(entryIDs: [String]) {
        guard !entryIDs.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: entryIDs)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// gitbar never counts as "in the foreground" in a way that should hide
    /// alerts — show them as banners regardless.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let entryID = info["entryID"] as? String ?? response.notification.request.identifier
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        Task { @MainActor in
            self.onOpen?(entryID, url)
            completionHandler()
        }
    }
}
