import Foundation
import XCTest
@testable import LightAnchor

/// 期限：押的是**截止日期**，不是「几点提醒我」。软件永远判断不了「结果到了」，
/// 但能百分百判断「快到期了」——这几条守的就是这条线不被越过。
@MainActor
final class DueDateTests: XCTestCase {
    private let calendar = Calendar.current

    private func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    // MARK: - 倒计时

    /// 数字要**倒着走**。这个软件里别的数字都在往上加（放下 6 天、已等 5 天），
    /// 往上加的数字只在描述过去；倒着走的自己会喊人。
    func testCountdownRunsBackwardsInCalendarDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DueCountdown(due: day(2, from: now), now: now).days, 2)
        XCTAssertTrue(DueCountdown(due: now, now: now).isToday)
        XCTAssertEqual(DueCountdown(due: day(-3, from: now), now: now).daysOverdue, 3)
        XCTAssertTrue(DueCountdown(due: day(-3, from: now), now: now).isOverdue)
    }

    /// 「还有两天」说的是两个日历天，不是 48 小时——人是这么说话的。
    func testCountdownIsCalendarDaysNotHours() {
        let tonight = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        let tomorrowMorning = calendar.date(byAdding: .hour, value: 2, to: tonight)!
        XCTAssertEqual(DueCountdown(due: tomorrowMorning, now: tonight).days, 1, "跨了午夜就是明天")
    }

    /// 到期那天才响已经晚了：不管去做还是去催都要时间，所以提前一天进窗口。
    func testTheWindowOpensWhileThereIsStillTimeToAct() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(DueCountdown(due: day(2, from: now), now: now).isPressing)
        XCTAssertTrue(DueCountdown(due: day(1, from: now), now: now).isPressing)
        XCTAssertTrue(DueCountdown(due: now, now: now).isPressing)
        XCTAssertTrue(DueCountdown(due: day(-1, from: now), now: now).isPressing)
    }

    // MARK: - 谁有资格打扰你

    /// **只有你亲口押了期限的事才有资格打断你。** 留空的只是一笔账。
    func testWorkWithoutADeadlineNeverNudges() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "没期限的事"))
        XCTAssertNil(target.countdown())
        XCTAssertFalse(target.needsNudge())

        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(
            workspace.beginWaiting(episodeID: episode.id, description: "等财务打款")
        )
        XCTAssertNil(waiting.countdown())
        XCTAssertFalse(waiting.needsNudge())

        workspace.deliverDueNudges()
        XCTAssertNil(workspace.snapshot.waitingItems[waiting.id]?.nudgedAt, "没押期限就不该被碰")
    }

    /// 一件事到期**只说一次**，说完就过去了——不累积愧疚，不隔天又冒出来。
    func testEachDeadlineIsNudgedOnlyOnce() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(
            workspace.createTarget(name: "周报", dueAt: day(-1, from: Date()))
        )
        XCTAssertTrue(target.needsNudge())

        workspace.deliverDueNudges()
        let first = try XCTUnwrap(workspace.snapshot.targets[target.id]?.nudgedAt)

        workspace.deliverDueNudges()
        workspace.deliverDueNudges()
        XCTAssertEqual(workspace.snapshot.targets[target.id]?.nudgedAt, first, "催过就不再催")
        XCTAssertFalse(try XCTUnwrap(workspace.snapshot.targets[target.id]).needsNudge())
    }

    /// 改期 = 新的承诺，到点该重新开口一次。
    func testReschedulingEarnsAFreshNudge() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(
            workspace.createTarget(name: "周报", dueAt: day(-1, from: Date()))
        )
        workspace.deliverDueNudges()
        XCTAssertNotNil(workspace.snapshot.targets[target.id]?.nudgedAt)

        XCTAssertTrue(workspace.setTargetDueDate(target.id, to: day(5, from: Date())))
        XCTAssertNil(workspace.snapshot.targets[target.id]?.nudgedAt, "改期把「催过了」一并清掉")
        XCTAssertFalse(
            try XCTUnwrap(workspace.snapshot.targets[target.id]).needsNudge(),
            "新期限还早，现在不该响"
        )
    }

    /// 「算了」撤掉的是**期限**，不是这件事——它掉回没期限那一档，安静待着，
    /// 而且真的不会隔天又冒出来。
    func testNeverMindDropsTheDeadlineNotTheWork() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(
            workspace.createTarget(name: "周报", dueAt: day(0, from: Date()))
        )
        XCTAssertTrue(workspace.setTargetDueDate(target.id, to: nil))

        XCTAssertNotNil(workspace.snapshot.targets[target.id], "事情还在")
        XCTAssertNil(workspace.snapshot.targets[target.id]?.dueAt)
        XCTAssertTrue(workspace.snapshot.dueTargets().isEmpty)
        XCTAssertFalse(try XCTUnwrap(workspace.snapshot.targets[target.id]).needsNudge())
    }

    // MARK: - 那句不许再说的话

    /// **到期只负责催你，绝不替你宣布结果到了。** 软件看不见你的邮箱。
    func testADeadlineNeverDeclaresTheResultArrived() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "等客户签合同"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "客户确认合同",
            dueAt: day(-2, from: Date())
        ))

        workspace.deliverDueNudges()

        let stored = try XCTUnwrap(workspace.snapshot.waitingItems[waiting.id])
        XCTAssertEqual(stored.status, .waiting, "过期两天也还是没到——只有你知道它到没到")
        XCTAssertTrue(stored.evidence.isEmpty, "软件不该替你编一句凭据")
        XCTAssertNotNil(stored.nudgedAt)
    }

    /// 「结果到了」只能由人确认，凭据是人给的。
    func testOnlyAPersonCanConfirmTheResultArrived() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "等回信"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(
            workspace.beginWaiting(episodeID: episode.id, description: "客户回信")
        )

        XCTAssertTrue(workspace.completeWaiting(waiting.id, evidence: "邮件里看到签好的 PDF"))
        let stored = try XCTUnwrap(workspace.snapshot.waitingItems[waiting.id])
        XCTAssertEqual(stored.status, .ready)
        XCTAssertEqual(stored.evidence, "邮件里看到签好的 PDF")
    }

    // MARK: - 两条轴各管各的

    /// 期限回答「什么时候」，球在谁手里回答「到时候干什么」。四个格子都住着人：
    /// 你自己的事一样会有硬期限，那一格恰恰最容易出事。
    func testDeadlinesLiveOnOwnWorkAndOnWaitsAlike() throws {
        let workspace = makeWorkspace()
        let own = try XCTUnwrap(
            workspace.createTarget(name: "周报", dueAt: day(1, from: Date()))
        )
        XCTAssertTrue(workspace.pauseEpisode(
            try XCTUnwrap(workspace.startEpisode(targetID: own.id)).id
        ))

        let blocked = try XCTUnwrap(workspace.createTarget(name: "等客户签合同"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: blocked.id))
        XCTAssertNotNil(workspace.beginWaiting(
            episodeID: episode.id,
            description: "客户确认合同",
            dueAt: day(1, from: Date())
        ))

        XCTAssertEqual(workspace.snapshot.dueTargets().map(\.id), [own.id])
        XCTAssertEqual(workspace.snapshot.dueWaitingItems().map(\.description), ["客户确认合同"])

        // 分组仍然只看归属，跟日期无关——两条轴不能压成一条。
        let list = workspace.snapshot.laterList
        XCTAssertEqual(list.actionable.map(\.target.id), [own.id])
        XCTAssertEqual(list.blocked.map(\.target.id), [blocked.id])
    }

    /// 押了期限的往上排、没押的往下沉：日期不是分组条件，只管顺序。
    func testDeadlinesOnlyDecideOrderWithinAGroup() throws {
        let workspace = makeWorkspace()
        let loose = try XCTUnwrap(workspace.createTarget(name: "没期限的"))
        XCTAssertTrue(workspace.pauseEpisode(
            try XCTUnwrap(workspace.startEpisode(targetID: loose.id)).id
        ))
        let urgent = try XCTUnwrap(
            workspace.createTarget(name: "周五要交的", dueAt: day(4, from: Date()))
        )
        XCTAssertTrue(workspace.pauseEpisode(
            try XCTUnwrap(workspace.startEpisode(targetID: urgent.id)).id
        ))

        XCTAssertEqual(
            workspace.snapshot.laterList.actionable.map(\.target.id),
            [urgent.id, loose.id]
        )
    }

    func testWaitingRoundTripsWithAndWithoutDeadline() throws {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for dueAt in [nil, Optional(now.addingTimeInterval(86_400))] {
            let waiting = WaitingItem(
                episodeID: UUID(),
                description: "等客户回信",
                completionCondition: "收到签名",
                startedAt: now,
                completedAt: now.addingTimeInterval(60),
                status: .ready,
                evidence: "已收到回信",
                dueAt: dueAt,
                nudgedAt: now,
                originalContext: ContextCapsule(note: "合同", capturedAt: now)
            )
            let data = try JSONEncoder().encode(waiting)
            XCTAssertEqual(try JSONDecoder().decode(WaitingItem.self, from: data), waiting)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(raw["monitor"])
            XCTAssertNil(raw["restorePolicy"])
        }
    }

    func testReminderFieldDoesNotBecomeADeadline() throws {
        let current = WaitingItem(episodeID: UUID(), description: "等客户回信")
        var raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(current))
                as? [String: Any]
        )
        raw.removeValue(forKey: "dueAt")
        raw["restorePolicy"] = "notify"
        raw["monitor"] = ["kind": "date", "date": 700_086_400.0]

        let waiting = try JSONDecoder().decode(
            WaitingItem.self,
            from: try JSONSerialization.data(withJSONObject: raw)
        )
        XCTAssertNil(waiting.dueAt)
        XCTAssertFalse(waiting.needsNudge())
        XCTAssertEqual(waiting.description, "等客户回信")
    }

    func testCurrentEpisodeStatesRoundTrip() throws {
        let states: [AttentionEpisodeState] = [.active, .paused, .returning, .ended]
        for state in states {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(AttentionEpisodeState.self, from: data), state)
        }
    }

    func testUnsupportedEpisodeStatesAreRejected() {
        for raw in ["waiting", "unknown"] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                AttentionEpisodeState.self, from: Data("\"\(raw)\"".utf8)
            )) { error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorDueDateTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events", isDirectory: true)
    }
}
