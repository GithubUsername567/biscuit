import Foundation
import UserNotifications

/// Schedules local notifications for reminders and timers. Uses
/// UserNotifications so they fire even if Biscuit is in the background.
enum ReminderService {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Notification auth error: \(error.localizedDescription)") }
            else { NSLog("Notification auth granted: \(granted)") }
        }
    }

    /// Schedules a notification `seconds` from now. Returns a user-facing
    /// confirmation string for the model to relay.
    static func schedule(title: String, body: String, seconds: TimeInterval) async -> String {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            return "Reminders need notification permission — enable Biscuit in System Settings → Notifications."
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        do {
            try await center.add(request)
            return "Set for \(friendlyDuration(seconds)) from now."
        } catch {
            return "Couldn't set the reminder: \(error.localizedDescription)"
        }
    }

    private static func friendlyDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) second\(s == 1 ? "" : "s")" }
        let minutes = s / 60
        let remainder = s % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes) minute\(minutes == 1 ? "" : "s")"
                                  : "\(minutes) min \(remainder) sec"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours) hour\(hours == 1 ? "" : "s")" : "\(hours) hr \(mins) min"
    }
}
