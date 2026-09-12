import Foundation

// MARK: - 期限
//
// 目标（你自己的事）和等待（别人欠你的东西）共用这一套。两条轴各管各的：
// **期限回答「什么时候」，球在谁手里回答「到时候干什么」**——你的事到期是
// 「今天得动了」，别人的事到期是「今天不催就来不及」。
//
// 押的是日期不是时长。「三天」是你对别人耐心的估计，是编的，响起来没分量；
// 「周五」是你自己日程上的硬点。而且日期能倒着算：周五要用、催一趟要一天，
// 那今天就得动——时长模型里没有终点，倒不回来。

/// 一个期限到此刻还剩多少，按**日历天**算——人说的「还有两天」是两个日历天，
/// 不是 48 小时。
struct DueCountdown: Equatable {
    /// 还剩几个日历天：正数 = 还有几天，0 = 就是今天，负数 = 过期几天。
    let days: Int

    var isOverdue: Bool { days < 0 }
    var isToday: Bool { days == 0 }
    /// 过期了几天（非负）。
    var daysOverdue: Int { max(0, -days) }

    /// 该开始喊了。到期那天才响已经晚了——不管是去做还是去催，都要时间，
    /// 所以默认提前一天进入这个窗口。
    var isPressing: Bool { days <= Self.leadDays }

    /// 提前几天开始喊。
    static let leadDays = 1

    init(due: Date, now: Date = Date(), calendar: Calendar = .current) {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: due)
        days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }
}

extension Date {
    func countdown(now: Date = Date()) -> DueCountdown {
        DueCountdown(due: self, now: now)
    }
}

extension AttentionTarget {
    /// 这件事的期限还剩多少。没押日期就没有倒计时——它只是一笔账。
    func countdown(now: Date = Date()) -> DueCountdown? {
        dueAt.map { DueCountdown(due: $0, now: now) }
    }

    /// 该催你了吗：押了日期、进了那个窗口、而且还没为这个期限催过。
    /// 「催过就不再催」——一件事到期只说一次，说完就过去了，不累积愧疚。
    func needsNudge(now: Date = Date()) -> Bool {
        guard let dueAt, retiredAt == nil else { return false }
        guard DueCountdown(due: dueAt, now: now).isPressing else { return false }
        return nudgedAt.map { $0 < dueAt.addingTimeInterval(-Double(DueCountdown.leadDays) * 86_400) }
            ?? true
    }
}

extension WaitingItem {
    func countdown(now: Date = Date()) -> DueCountdown? {
        dueAt.map { DueCountdown(due: $0, now: now) }
    }

    func needsNudge(now: Date = Date()) -> Bool {
        guard let dueAt, status == .waiting else { return false }
        guard DueCountdown(due: dueAt, now: now).isPressing else { return false }
        return nudgedAt.map { $0 < dueAt.addingTimeInterval(-Double(DueCountdown.leadDays) * 86_400) }
            ?? true
    }
}
