import Foundation
import SOSync
import UserNotifications

/// The iOS half of notifications: UNUserNotificationCenter and nothing else.
///
/// Every decision about WHETHER to send lives in the Kit
/// (`NotificationGatekeeper`), where it is Linux-tested and cannot drift into
/// a view. This file only carries the message across, and it is deliberately
/// dull for that reason.
///
/// LOCAL ONLY, for now. Remote push needs an APNs signing key and the
/// `aps-environment` entitlement, both of which need an Apple Developer
/// account that does not exist yet. When it does, the transport changes and
/// `NotificationScheduling` does not — the policy above it never learns which
/// of the two delivered.
final class SystemNotificationScheduler: NotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Asked ONCE, and never on launch. iOS gives an app exactly one chance
    /// at this prompt, so it is spent at the moment the driver has just
    /// finished a drive and is waiting on a score — when the answer to
    /// "why does this want to notify me" is on the screen in front of them.
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A refusal is a legitimate answer, not an error to surface.
            return false
        }
    }

    func schedule(_ notification: DriverNotification, after seconds: Double) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if notification.isTimeSensitive {
            content.interruptionLevel = .timeSensitive
        }

        // A nil trigger fires immediately; UNTimeIntervalNotificationTrigger
        // rejects an interval below 1 second, which is a real crash if a
        // caller passes 0.
        let trigger: UNNotificationTrigger? = seconds >= 1
            ? UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            : nil

        // The identifier is what makes scheduling idempotent: iOS replaces a
        // pending request with the same one rather than stacking, so nine
        // unsent runs stay one notification that says nine.
        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    func cancel(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
