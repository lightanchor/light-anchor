import Foundation

#if os(macOS)
import EventKit

// MARK: - 日历读取（EventKit）
//
// 只读：给定时任务「从日历事件选时间」用。不写日历、不订阅变更，
// 每次打开选择器现读一遍即可。权限行走 PrivacyCapability.calendar。

/// 一条可选的日历事件（脱离 EKEvent 的值类型，UI 与测试都不用碰 EventKit）。
struct CalendarEventSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let calendarTitle: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

/// EKEventStore 不是 Sendable；读取都聚在主线程上做，量小（未来两周的事件）。
@MainActor
final class CalendarEventReader {
    private let store = EKEventStore()

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var hasFullAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// 请求完全读取权限（macOS 14+ 的 EventKit 只区分 fullAccess / writeOnly，
    /// 读事件需要 fullAccess）。返回是否已授权。
    func requestAccess() async -> Bool {
        if Self.hasFullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// 未来 `days` 天内的日历事件，按开始时间升序。全天事件放在当天最前。
    func upcomingEvents(
        days: Int = 14,
        limit: Int = 80,
        now: Date = Date()
    ) -> [CalendarEventSummary] {
        guard Self.hasFullAccess else { return [] }
        guard let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: now)
        else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .compactMap { event -> CalendarEventSummary? in
                guard let start = event.startDate else { return nil }
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return CalendarEventSummary(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: title.isEmpty ? tr("untitled_event") : title,
                    calendarTitle: event.calendar?.title ?? "",
                    startDate: start,
                    endDate: event.endDate ?? start,
                    isAllDay: event.isAllDay
                )
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { $0 }
    }
}
#endif
