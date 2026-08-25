import Foundation

#if os(macOS)
@preconcurrency import UserNotifications

struct WaitingNotificationService {
    func notifyIfAllowed(_ waiting: WaitingItem, isTransition: Bool = false) {
        guard waiting.restorePolicy == .notify
            || (isTransition && waiting.restorePolicy == .nextTransition)
        else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("a_result_you_were_waiting_for_arrived")
            content.body = waiting.evidence.isEmpty
                ? waiting.description
                : "\(waiting.description)：\(waiting.evidence)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "light-anchor.waiting.\(waiting.id.uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}
#endif
