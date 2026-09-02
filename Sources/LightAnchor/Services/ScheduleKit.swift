import Foundation

@preconcurrency import UserNotifications

// MARK: - 定时任务调度
//
// 与等待同一套驱动方式：每个排定中的任务一个 in-process Task.sleep，
// 5 秒维护循环兜底补启（应用重启、日志重放后由 startMonitoringScheduledTasks
// 重新装载）。到点由 workspace.fireScheduledTask 记账并发系统通知；
// 应用没在跑的时段不补发错过的中间场次，重启后只把下一场滚到未来。

@MainActor
final class ScheduledTaskCoordinator {
    private weak var workspace: AttentionWorkspace?
    /// fireAt 一起存：编辑改了时间要换检测器，同一场则保持原样。
    private var tasks: [UUID: (fireAt: Date, task: Task<Void, Never>)] = [:]

    init(workspace: AttentionWorkspace) {
        self.workspace = workspace
    }

    deinit {
        tasks.values.forEach { $0.task.cancel() }
    }

    func startMonitoring(_ scheduled: ScheduledTask, now: Date = Date()) {
        guard scheduled.status == .scheduled else {
            cancelMonitoring(scheduled.id)
            return
        }
        if scheduled.fireAt <= now {
            guard let reconciled = workspace?.skipMissedScheduledTask(scheduled.id, now: now) else {
                cancelMonitoring(scheduled.id)
                return
            }
            startMonitoring(reconciled, now: now)
            return
        }
        if let existing = tasks[scheduled.id] {
            guard existing.fireAt != scheduled.fireAt else { return }
            existing.task.cancel()
        }
        let fireAt = scheduled.fireAt
        let taskID = scheduled.id
        tasks[taskID] = (fireAt, Task { [weak self] in
            let interval = fireAt.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled else { return }
            self?.workspace?.fireScheduledTask(taskID)
            if self?.tasks[taskID]?.fireAt == fireAt {
                self?.tasks.removeValue(forKey: taskID)
            }
        })
    }

    func startMonitoringScheduledTasks(now: Date = Date()) {
        workspace?.snapshot.upcomingScheduledTasks.forEach { task in
            startMonitoring(task, now: now)
        }
    }

    func cancelMonitoring(_ taskID: UUID) {
        tasks.removeValue(forKey: taskID)?.task.cancel()
    }

    func cancelAllMonitoring() {
        tasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
    }
}

struct ScheduledTaskNotificationService {
    /// 到点通知：不弹窗不抢前台，与等待通知同一姿态。
    /// 附带现场的任务在正文里说一句，点开应用即可一键恢复。
    func notifyFired(_ task: ScheduledTask, firedAt: Date) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("scheduled_task_time_arrived")
            var body = task.title
            if !task.note.isEmpty {
                body += "：\(task.note)"
            }
            if task.collectSceneOnFire {
                body += "\n" + tr("scene_saved_open_to_restore")
            }
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "light-anchor.scheduled.\(task.id.uuidString)."
                    + "\(Int(firedAt.timeIntervalSinceReferenceDate))",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - 定时任务时间线投影（纯函数，无 UI）

/// 时间线上的一格：某个任务的一次触发（将来或已发生）。
struct ScheduleTimelineEntry: Identifiable, Equatable {
    let id: String
    let taskID: UUID
    let title: String
    let note: String
    let date: Date
    let repeatRule: ScheduledTaskRepeatRule
    /// 即将到来的格子：到点会收现场；历史格子：当时收到了现场。
    let collectsScene: Bool
    /// 历史格子里挂着的现场检查点（点开可看当时的现场）。
    let sceneSnapshotID: UUID?
    let calendarEventTitle: String?
}

/// 按天分的一组即将到来的触发。
struct ScheduleTimelineDay: Identifiable, Equatable {
    let day: Date
    let title: String
    let entries: [ScheduleTimelineEntry]

    var id: Date { day }
}

/// 定时任务页的全部展示数据：即将到来（按天分组）+ 最近已提醒。
struct ScheduleTimeline: Equatable {
    let upcomingDays: [ScheduleTimelineDay]
    let pastEntries: [ScheduleTimelineEntry]
    let upcomingCount: Int

    static func make(
        from snapshot: AttentionSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        pastLimit: Int = 60,
        filterTaskID: UUID? = nil,
        scenesOnly: Bool = false
    ) -> Self {
        let upcoming = snapshot.upcomingScheduledTasks
            .filter { filterTaskID == nil || $0.id == filterTaskID }
        var groups: [Date: [ScheduleTimelineEntry]] = [:]
        for task in upcoming {
            let entry = ScheduleTimelineEntry(
                id: "task-\(task.id.uuidString)",
                taskID: task.id,
                title: task.title,
                note: task.note,
                date: task.fireAt,
                repeatRule: task.repeatRule,
                collectsScene: task.collectSceneOnFire,
                sceneSnapshotID: nil,
                calendarEventTitle: task.calendarEventTitle
            )
            // 已经过点还没触发的（协调器马上会补火）归到今天。
            let day = calendar.startOfDay(for: max(task.fireAt, now))
            groups[day, default: []].append(entry)
        }
        let upcomingDays = groups.keys.sorted().map { day in
            ScheduleTimelineDay(
                day: day,
                title: dayTitle(day, now: now, calendar: calendar),
                entries: groups[day]!.sorted { $0.date < $1.date }
            )
        }

        // 历史从触发记录铺：任务删掉后历史仍在（标题冗余在 fire 上）。
        let past = snapshot.allScheduledFires
            .filter { filterTaskID == nil || $0.taskID == filterTaskID }
            .filter { !scenesOnly || $0.sceneSnapshotID != nil }
            .prefix(pastLimit)
            .map { fire in
                let task = snapshot.scheduledTasks[fire.taskID]
                return ScheduleTimelineEntry(
                    id: "fire-\(fire.id.uuidString)",
                    taskID: fire.taskID,
                    title: fire.taskTitle.isEmpty ? (task?.title ?? "") : fire.taskTitle,
                    note: "",
                    date: fire.firedAt,
                    repeatRule: task?.repeatRule ?? .once,
                    collectsScene: fire.sceneSnapshotID != nil,
                    sceneSnapshotID: fire.sceneSnapshotID,
                    calendarEventTitle: nil
                )
            }

        return Self(
            upcomingDays: upcomingDays,
            pastEntries: Array(past),
            upcomingCount: upcoming.count
        )
    }

    /// 今天 / 明天 / 「1月28日 周三」式的组头。
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return tr("today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return tr("tomorrow")
        }
        return day.formatted(.dateTime.month().day().weekday(.abbreviated))
    }
}
