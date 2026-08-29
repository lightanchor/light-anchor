import Foundation

// MARK: - 定时任务（Scheduled Task）
//
// 定时任务是「到点来找你」的另一半：等待盯的是结果什么时候来，
// 定时盯的是你自己定下的时刻。支持单次闹钟和按天/工作日/周/月重复；
// 到点除了提醒，还可以收集触发那一刻的现场（检查点，与当时在做什么无关）。
// 每次触发落一条 ScheduledTaskFire——回顾页的定时视角按它铺时间线。

/// 重复规则。`once` 是单次闹钟：触发一次就完成。
enum ScheduledTaskRepeatRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case once
    case daily
    case weekdays
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: tr("repeat_once")
        case .daily: tr("repeat_daily")
        case .weekdays: tr("repeat_weekdays")
        case .weekly: tr("repeat_weekly")
        case .monthly: tr("repeat_monthly")
        }
    }

    /// 从 `previous` 出发、严格晚于 `reference` 的下一次触发时刻。
    /// 单次任务返回 nil。应用可能停了很多天——循环步进直到跨过 reference，
    /// 错过的中间场次不补发。
    func nextFireDate(
        after reference: Date,
        previous: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard self != .once else { return nil }
        var next = previous
        // 上限只是保险丝：按天步进覆盖 8 年也用不完。
        for _ in 0..<3000 {
            guard let stepped = advance(next, calendar: calendar) else { return nil }
            next = stepped
            if next > reference, self != .weekdays || calendar.isWeekday(next) {
                return next
            }
        }
        return nil
    }

    private func advance(_ date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .once: nil
        case .daily, .weekdays: calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

private extension Calendar {
    func isWeekday(_ date: Date) -> Bool {
        let weekday = component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }
}

enum ScheduledTaskStatus: String, Codable, Equatable, Sendable {
    /// 已排定，等着到点。
    case scheduled
    /// 已结束：单次任务触发过，或用户主动标记完成。
    case done
    /// 用户取消，不再触发（保留在历史里）。
    case cancelled
}

struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var note: String
    /// 下一次触发时刻。重复任务每次触发后滚到下一场。
    var fireAt: Date
    var repeatRule: ScheduledTaskRepeatRule
    var status: ScheduledTaskStatus
    /// 到点时收集一份现场检查点（触发那一刻屏幕上的一切，与目标无关）。
    var collectSceneOnFire: Bool
    /// 时间取自哪个日历事件（EventKit eventIdentifier），仅溯源展示用。
    var calendarEventID: String?
    var calendarEventTitle: String?
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case note
        case fireAt
        case repeatRule
        case status
        case collectSceneOnFire
        case calendarEventID
        case calendarEventTitle
        case createdAt
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        fireAt: Date,
        repeatRule: ScheduledTaskRepeatRule = .once,
        status: ScheduledTaskStatus = .scheduled,
        collectSceneOnFire: Bool = false,
        calendarEventID: String? = nil,
        calendarEventTitle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fireAt = fireAt
        self.repeatRule = repeatRule
        self.status = status
        self.collectSceneOnFire = collectSceneOnFire
        self.calendarEventID = calendarEventID
        self.calendarEventTitle = calendarEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            note: try container.decodeIfPresent(String.self, forKey: .note) ?? "",
            fireAt: try container.decode(Date.self, forKey: .fireAt),
            repeatRule: try container.decodeIfPresent(
                ScheduledTaskRepeatRule.self,
                forKey: .repeatRule
            ) ?? .once,
            status: try container.decodeIfPresent(
                ScheduledTaskStatus.self,
                forKey: .status
            ) ?? .scheduled,
            collectSceneOnFire: try container.decodeIfPresent(
                Bool.self,
                forKey: .collectSceneOnFire
            ) ?? false,
            calendarEventID: try container.decodeIfPresent(String.self, forKey: .calendarEventID),
            calendarEventTitle: try container.decodeIfPresent(
                String.self,
                forKey: .calendarEventTitle
            ),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }

    var isValid: Bool {
        !title.isEmpty
    }

    /// 一次触发后的任务状态：重复任务滚到下一场，单次任务标记完成。
    /// 触发本身记在独立的 ScheduledTaskFire 里，不在任务身上滚数组。
    func firing(at now: Date, calendar: Calendar = .current) -> ScheduledTask {
        var fired = self
        fired.updatedAt = now
        if let next = repeatRule.nextFireDate(after: now, previous: fireAt, calendar: calendar) {
            fired.fireAt = next
        } else {
            fired.status = .done
        }
        return fired
    }
}

// MARK: - 触发记录（Fire）

/// 一次触发一条，回放成全量触发史——回顾页的定时时间线按它铺开，
/// 收到的现场检查点也挂在这里。taskTitle 冗余一份：任务删掉后历史仍可读。
struct ScheduledTaskFire: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    var taskTitle: String
    let firedAt: Date
    /// 触发时收集的现场检查点；采集是异步的，先落触发再补现场。
    var sceneSnapshotID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case taskTitle
        case firedAt
        case sceneSnapshotID
    }

    init(
        id: UUID = UUID(),
        taskID: UUID,
        taskTitle: String,
        firedAt: Date,
        sceneSnapshotID: UUID? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.firedAt = firedAt
        self.sceneSnapshotID = sceneSnapshotID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            taskID: try container.decode(UUID.self, forKey: .taskID),
            taskTitle: try container.decodeIfPresent(String.self, forKey: .taskTitle) ?? "",
            firedAt: try container.decode(Date.self, forKey: .firedAt),
            sceneSnapshotID: try container.decodeIfPresent(UUID.self, forKey: .sceneSnapshotID)
        )
    }
}
