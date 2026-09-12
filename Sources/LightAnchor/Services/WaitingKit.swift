import Foundation

/// 期限守望：盯着押了日期的事（你自己的和别人欠你的），在**还来得及的时候**
/// 开口一次。
///
/// 它以前干的是另一件事——睡到约定时刻，然后把等待标成「结果到了」，推一条
/// 「你在等的一个结果到了」。可什么都没到，只是闹钟响了。软件看不见你的邮箱，
/// 就永远判断不了结果到没到；但它只要一块表，就能百分百判断快到期了。
/// 所以这里只做后者：到期催你，不替你宣布结果。
@MainActor
final class WaitingCoordinator {
    private weak var workspace: AttentionWorkspace?
    /// 下一次醒来的闹钟。只留一个：每次落盘后重算最近的那个期限。
    private var wakeUp: Task<Void, Never>?

    init(workspace: AttentionWorkspace) {
        self.workspace = workspace
    }

    deinit {
        wakeUp?.cancel()
    }

    /// 把该催的催掉，然后睡到下一个期限进入窗口的时刻。
    func startMonitoringDueDates(now: Date = Date()) {
        guard let workspace else { return }
        workspace.deliverDueNudges(now: now)

        wakeUp?.cancel()
        wakeUp = nil
        guard let next = workspace.nextNudgeDate(after: now) else { return }
        let interval = max(1, next.timeIntervalSince(now))
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.startMonitoringDueDates()
        }
    }

    func cancelAllMonitoring() {
        wakeUp?.cancel()
        wakeUp = nil
    }
}
