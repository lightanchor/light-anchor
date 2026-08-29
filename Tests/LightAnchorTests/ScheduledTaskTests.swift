import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class ScheduledTaskTests: XCTestCase {
    // MARK: - 辅助

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorScheduledTaskTests-\(UUID().uuidString).json")
    }

    private func makeWorkspace(
        fileURL: URL? = nil,
        contextCapture: ((IntelligencePreferences, SceneCapturePreferences) -> ContextCapsule)? = nil
    ) -> AttentionWorkspace {
        AttentionWorkspace(
            store: LocalEventStore(fileURL: fileURL ?? temporaryFileURL()),
            contextCapture: contextCapture
        )
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 9, _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    // MARK: - 重复规则

    func testOnceHasNoNextFireDate() {
        let previous = date(2026, 8, 28, 9)
        XCTAssertNil(
            ScheduledTaskRepeatRule.once.nextFireDate(after: previous, previous: previous)
        )
    }

    func testDailyRollsPastTheReference() {
        let previous = date(2026, 8, 20, 9)
        // 应用停了一周：下一场必须严格晚于 reference，不补发错过的场次。
        let reference = date(2026, 8, 28, 10)
        let next = ScheduledTaskRepeatRule.daily.nextFireDate(after: reference, previous: previous)
        XCTAssertEqual(next, date(2026, 8, 29, 9))
    }

    func testWeekdaysSkipsTheWeekend() {
        // 2026-08-28 是周五。
        let friday = date(2026, 8, 28, 9)
        let next = ScheduledTaskRepeatRule.weekdays.nextFireDate(after: friday, previous: friday)
        // 下一个工作日是周一 8/31。
        XCTAssertEqual(next, date(2026, 8, 31, 9))
    }

    func testMonthlyKeepsTheTimeOfDay() {
        let previous = date(2026, 8, 28, 14, 30)
        let next = ScheduledTaskRepeatRule.monthly.nextFireDate(after: previous, previous: previous)
        XCTAssertEqual(next, date(2026, 9, 28, 14, 30))
    }

    // MARK: - 触发后的任务状态

    func testFiringAOneOffMarksItDone() {
        let fireAt = date(2026, 8, 28, 9)
        let task = ScheduledTask(title: "回来继续改脚本", fireAt: fireAt)
        let fired = task.firing(at: fireAt.addingTimeInterval(2))
        XCTAssertEqual(fired.status, .done)
    }

    func testFiringARepeatingTaskRollsForward() {
        let fireAt = date(2026, 8, 28, 9)
        let task = ScheduledTask(title: "每天理一遍收件箱", fireAt: fireAt, repeatRule: .daily)
        let fired = task.firing(at: fireAt.addingTimeInterval(2))
        XCTAssertEqual(fired.status, .scheduled)
        XCTAssertEqual(fired.fireAt, date(2026, 8, 29, 9))
    }

    // MARK: - 数据模型兼容

    func testScheduledTaskDecodesLegacyPayloadWithoutNewFields() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "旧数据",
            "fireAt": 778208400
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let task = try decoder.decode(ScheduledTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.title, "旧数据")
        XCTAssertEqual(task.repeatRule, .once)
        XCTAssertEqual(task.status, .scheduled)
        XCTAssertFalse(task.collectSceneOnFire)
    }

    func testScheduledFireDecodesWithoutOptionalFields() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "taskID": "\(UUID().uuidString)",
            "firedAt": 778208400
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fire = try decoder.decode(ScheduledTaskFire.self, from: Data(json.utf8))
        XCTAssertEqual(fire.taskTitle, "")
        XCTAssertNil(fire.sceneSnapshotID)
    }

    // MARK: - 事件回放与持久化

    func testCreateEditAndDeletePersistAcrossReload() throws {
        let fileURL = temporaryFileURL()
        let workspace = makeWorkspace(fileURL: fileURL)
        let fireAt = Date().addingTimeInterval(3600)

        let created = try XCTUnwrap(workspace.createScheduledTask(
            title: "去开会",
            note: "带上评审记录",
            fireAt: fireAt,
            repeatRule: .weekly,
            collectSceneOnFire: true,
            calendarEventTitle: "周会"
        ))
        XCTAssertEqual(workspace.snapshot.upcomingScheduledTasks.count, 1)

        var edited = created
        edited.title = "去开周会"
        XCTAssertTrue(workspace.updateScheduledTask(edited))

        let reloaded = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        let persisted = try XCTUnwrap(reloaded.snapshot.scheduledTasks[created.id])
        XCTAssertEqual(persisted.title, "去开周会")
        XCTAssertEqual(persisted.calendarEventTitle, "周会")
        XCTAssertTrue(persisted.collectSceneOnFire)

        XCTAssertTrue(reloaded.deleteScheduledTask(created.id))
        let reloadedAgain = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        XCTAssertNil(reloadedAgain.snapshot.scheduledTasks[created.id])
    }

    func testFireScheduledTaskWritesAFireRecordAndRolls() throws {
        let workspace = makeWorkspace()
        let fireAt = Date().addingTimeInterval(600)

        let oneOff = try XCTUnwrap(workspace.createScheduledTask(title: "单次", fireAt: fireAt))
        let repeating = try XCTUnwrap(workspace.createScheduledTask(
            title: "每天", fireAt: fireAt, repeatRule: .daily
        ))

        // 还没到点：不触发。
        workspace.fireScheduledTask(oneOff.id, now: fireAt.addingTimeInterval(-30))
        XCTAssertTrue(workspace.snapshot.scheduledFires.isEmpty)

        let now = fireAt.addingTimeInterval(1)
        workspace.fireScheduledTask(oneOff.id, now: now)
        workspace.fireScheduledTask(repeating.id, now: now)

        XCTAssertEqual(workspace.snapshot.scheduledTasks[oneOff.id]?.status, .done)
        let rolled = try XCTUnwrap(workspace.snapshot.scheduledTasks[repeating.id])
        XCTAssertEqual(rolled.status, .scheduled)
        XCTAssertGreaterThan(rolled.fireAt, now)

        // 每次触发一条记录，标题冗余在记录上。
        let fires = workspace.snapshot.allScheduledFires
        XCTAssertEqual(fires.count, 2)
        XCTAssertEqual(Set(fires.map(\.taskTitle)), ["单次", "每天"])
        XCTAssertEqual(fires.map(\.firedAt), [fireAt, fireAt])
    }

    func testFireHistorySurvivesTaskDeletion() throws {
        let workspace = makeWorkspace()
        let fireAt = Date().addingTimeInterval(600)
        let task = try XCTUnwrap(workspace.createScheduledTask(title: "会被删的", fireAt: fireAt))
        workspace.fireScheduledTask(task.id, now: fireAt.addingTimeInterval(1))
        XCTAssertTrue(workspace.deleteScheduledTask(task.id))
        XCTAssertEqual(workspace.snapshot.allScheduledFires.map(\.taskTitle), ["会被删的"])
    }

    // MARK: - 检查点现场

    func testCheckpointSceneCapturesWithoutAnEpisode() async throws {
        let workspace = makeWorkspace(contextCapture: { _, _ in
            ContextCapsule(
                applications: ["VS Code"],
                files: [URL(fileURLWithPath: "/tmp/build.sh")]
            )
        })
        // 没有任何目标/工作段也能收：检查点与目标无关。
        let scene = try XCTUnwrap(await workspace.captureCheckpointScene())
        XCTAssertNil(scene.targetID)
        XCTAssertEqual(scene.filterMode, .saveAll)
        XCTAssertFalse(scene.items.isEmpty)
        XCTAssertNotNil(workspace.snapshot.sceneSnapshots[scene.id])
    }

    func testFiringWithCollectSceneAttachesACheckpoint() async throws {
        let workspace = makeWorkspace(contextCapture: { _, _ in
            ContextCapsule(applications: ["Safari"])
        })
        let fireAt = Date().addingTimeInterval(600)
        let task = try XCTUnwrap(workspace.createScheduledTask(
            title: "收现场的",
            fireAt: fireAt,
            collectSceneOnFire: true
        ))
        workspace.fireScheduledTask(task.id, now: fireAt.addingTimeInterval(1))

        // 现场是异步补挂的：轮询等它落上来。
        var fire: ScheduledTaskFire?
        for _ in 0..<100 {
            fire = workspace.snapshot.allScheduledFires.first
            if fire?.sceneSnapshotID != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sceneID = try XCTUnwrap(fire?.sceneSnapshotID)
        XCTAssertNotNil(workspace.snapshot.sceneSnapshots[sceneID])
    }

    // MARK: - 时间线投影

    func testTimelineGroupsUpcomingByDayAndListsFires() {
        let now = date(2026, 8, 28, 8)
        var snapshot = AttentionSnapshot()

        let todayTask = ScheduledTask(title: "今天的", fireAt: date(2026, 8, 28, 15))
        let tomorrowTask = ScheduledTask(title: "明天的", fireAt: date(2026, 8, 29, 9))
        snapshot.apply(.scheduledTaskChanged(todayTask))
        snapshot.apply(.scheduledTaskChanged(tomorrowTask))
        snapshot.apply(.scheduledFireChanged(ScheduledTaskFire(
            taskID: todayTask.id,
            taskTitle: "今天的",
            firedAt: date(2026, 8, 27, 9)
        )))

        let timeline = ScheduleTimeline.make(from: snapshot, now: now)
        XCTAssertEqual(timeline.upcomingCount, 2)
        XCTAssertEqual(timeline.upcomingDays.map(\.title), ["今天", "明天"])
        XCTAssertEqual(timeline.upcomingDays[0].entries.map(\.title), ["今天的"])
        XCTAssertEqual(timeline.pastEntries.map(\.title), ["今天的"])
        XCTAssertEqual(timeline.pastEntries[0].date, date(2026, 8, 27, 9))
    }

    func testTimelineFiltersByTaskAndScenes() {
        let now = date(2026, 8, 28, 8)
        var snapshot = AttentionSnapshot()
        let taskA = ScheduledTask(title: "A", fireAt: date(2026, 8, 29, 9))
        snapshot.apply(.scheduledTaskChanged(taskA))
        snapshot.apply(.scheduledFireChanged(ScheduledTaskFire(
            taskID: taskA.id, taskTitle: "A", firedAt: date(2026, 8, 27, 9)
        )))
        snapshot.apply(.scheduledFireChanged(ScheduledTaskFire(
            taskID: UUID(), taskTitle: "B", firedAt: date(2026, 8, 26, 9),
            sceneSnapshotID: UUID()
        )))

        let byTask = ScheduleTimeline.make(from: snapshot, now: now, filterTaskID: taskA.id)
        XCTAssertEqual(byTask.pastEntries.map(\.title), ["A"])
        XCTAssertEqual(byTask.upcomingCount, 1)

        let scenesOnly = ScheduleTimeline.make(from: snapshot, now: now, scenesOnly: true)
        XCTAssertEqual(scenesOnly.pastEntries.map(\.title), ["B"])
    }

    func testTimelinePutsOverdueUnfiredTasksUnderToday() {
        let now = date(2026, 8, 28, 8)
        var snapshot = AttentionSnapshot()
        // 昨天就该响、应用一直没开：显示在今天组，协调器随后会补火。
        snapshot.apply(.scheduledTaskChanged(
            ScheduledTask(title: "迟到的", fireAt: date(2026, 8, 27, 20))
        ))
        let timeline = ScheduleTimeline.make(from: snapshot, now: now)
        XCTAssertEqual(timeline.upcomingDays.count, 1)
        XCTAssertEqual(timeline.upcomingDays[0].title, "今天")
    }
}
