import Foundation

@preconcurrency import UserNotifications

/// 到期通知。说的话里必须有**日期**和**后果**——「已等 5 天」只是在陈述过去，
/// 里面没有任何东西在逼你；「周五要用，今天不催就赶不上了」自己就把动作算出来了。
///
/// 两套话，因为到期时要做的事根本不同：你的事到期要腾出一块时间去做，
/// 别人的事到期只要发一条消息去催。一个催自己，一个催别人。
struct DueNudgeNotification {
    enum Kind {
        /// 你自己的事：去做。
        case ownWork
        /// 别人欠你的：去催。
        case waitingOnOthers
    }

    let kind: Kind
    let title: String
    /// 期限那天的人话写法（「周五」「9 月 8 日」）。
    let dueLabel: String
    let countdown: DueCountdown

    var body: String {
        let template: String
        switch (kind, countdown.isOverdue) {
        case (.ownWork, false): template = tr("nudge_own_work")
        case (.ownWork, true): template = tr("nudge_own_work_overdue")
        case (.waitingOnOthers, false): template = tr("nudge_waiting")
        case (.waitingOnOthers, true): template = tr("nudge_waiting_overdue")
        }
        return String(format: template, title, dueLabel)
    }

    func post(identifier: String) {
        // 未打包运行（swift run）时没有通知中心身份，直接跳过。
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let body = body
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("nudge_title")
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        }
    }
}
