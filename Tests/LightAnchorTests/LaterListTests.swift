import Foundation
import XCTest
@testable import LightAnchor

/// 稍后清单的两组：可以动 / 等着别人。分组只问「下一步在谁手里」——
/// 这几条断言守的就是那条分界线不会被状态漂移、被重影、被排序悄悄抹掉。
@MainActor
final class LaterListTests: XCTestCase {
    /// 核心分界：一件在等外部结果的事进「等着别人」，一件自己放下的事进
    /// 「可以动」。哪怕两件事此刻的状态在数据里长得一模一样（都是 paused）。
    func testBlockedAndActionableSplitByWhoseCourtTheBallIsIn() throws {
        let workspace = makeWorkspace()
        let blockedTarget = try XCTUnwrap(workspace.createTarget(name: "等客户签合同"))
        let blockedEpisode = try XCTUnwrap(workspace.startEpisode(targetID: blockedTarget.id))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: blockedEpisode.id,
            description: "客户确认合同"
        ))

        let ownTarget = try XCTUnwrap(workspace.createTarget(name: "重构解析器"))
        let ownEpisode = try XCTUnwrap(workspace.startEpisode(targetID: ownTarget.id))
        XCTAssertTrue(workspace.pauseEpisode(ownEpisode.id))

        // 两段工作此刻都不是 active：一段被切换挤成 paused，一段被自己放下。
        // 状态一样，分组必须不一样。
        let list = workspace.snapshot.laterList
        XCTAssertEqual(list.blocked.map(\.waiting.id), [waiting.id])
        XCTAssertEqual(list.blocked.first?.target.id, blockedTarget.id)
        XCTAssertEqual(list.actionable.map(\.target.id), [ownTarget.id])
        XCTAssertEqual(list.total, 2)
    }

    /// 被别的事挤下去之后 episode 会漂成「放下」，可 CI 还在跑——
    /// 分组看的是「有没有一条还没等到的结果」，不是那段工作此刻的状态。
    func testDisplacedWaitStaysBlockedEvenAfterItsEpisodeDriftsToPaused() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "等 CI"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        XCTAssertNotNil(workspace.beginWaiting(episodeID: episode.id, description: "CI 跑完"))

        let other = try XCTUnwrap(workspace.createTarget(name: "写周报"))
        XCTAssertNotNil(workspace.startEpisode(targetID: other.id))

        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .paused, "前提：状态确实漂了")
        let list = workspace.snapshot.laterList
        XCTAssertEqual(list.blocked.first?.target.id, target.id, "漂成放下不代表它不再等结果")
        XCTAssertTrue(list.actionable.isEmpty)
    }

    /// 结果到了 = 「可以动」里排最上面的一条，不单开一组，也不留在「等着别人」。
    func testArrivedResultThawsToTheTopOfActionable() throws {
        let workspace = makeWorkspace()
        let stale = try XCTUnwrap(workspace.createTarget(name: "早就放下的事"))
        let staleEpisode = try XCTUnwrap(workspace.startEpisode(targetID: stale.id))
        XCTAssertTrue(workspace.pauseEpisode(staleEpisode.id))

        let thawing = try XCTUnwrap(workspace.createTarget(name: "等法务回复"))
        let thawingEpisode = try XCTUnwrap(workspace.startEpisode(targetID: thawing.id))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: thawingEpisode.id,
            description: "法务回复"
        ))
        // 换去别的事，好让这件事离开「现在」页。
        let elsewhere = try XCTUnwrap(workspace.createTarget(name: "别的事"))
        XCTAssertNotNil(workspace.startEpisode(targetID: elsewhere.id))
        XCTAssertTrue(workspace.completeWaiting(waiting.id, evidence: "邮件里回了"))

        let list = workspace.snapshot.laterList
        XCTAssertTrue(list.blocked.isEmpty, "已到的结果不该还挂在等着别人那组")
        XCTAssertEqual(list.actionable.first?.target.id, thawing.id, "刚解冻的排最上面")
        XCTAssertEqual(list.actionable.first?.readyWaiting?.id, waiting.id)
        XCTAssertTrue(try XCTUnwrap(list.actionable.first).isThawed)
        XCTAssertEqual(list.actionable.map(\.target.id), [thawing.id, stale.id])
    }

    /// 正占着「现在」的那件事不进稍后：它就在眼前，列两遍是重影。
    func testCurrentWorkNeverAppearsInEitherGroup() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "手上这件"))
        XCTAssertNotNil(workspace.startEpisode(targetID: target.id))

        let list = workspace.snapshot.laterList
        XCTAssertTrue(list.blocked.isEmpty)
        XCTAssertTrue(list.actionable.isEmpty)
        XCTAssertEqual(list.total, 0)
    }

    /// 交出去的那一刻它就离开「现在」页——你在等的时候一定在做别的，
    /// 把它按在现在页上，那一页就成了一件你并没有在做的事。
    func testStartingAWaitMovesTheWorkOffTheNowPage() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "等客户签合同"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        XCTAssertNotNil(workspace.beginWaiting(episodeID: episode.id, description: "等回信"))

        XCTAssertNil(workspace.currentEpisode, "球在别人手里，它不该还占着现在页")
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .paused)
        let list = workspace.snapshot.laterList
        XCTAssertEqual(list.blocked.map(\.target.id), [target.id])
        XCTAssertTrue(list.actionable.isEmpty)
    }

    /// 折起来那行报的是等得最久的一条：不打开也得知道里面有没有火。
    func testBlockedLeadIsTheLongestWaitingOne() throws {
        let workspace = makeWorkspace()
        let old = try XCTUnwrap(workspace.createTarget(name: "等得久的"))
        let oldEpisode = try XCTUnwrap(workspace.startEpisode(targetID: old.id))
        let oldWaiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: oldEpisode.id,
            description: "五天前就在等",
            now: Date(timeIntervalSince1970: 1_000_000)
        ))

        let recent = try XCTUnwrap(workspace.createTarget(name: "刚开始等的"))
        let recentEpisode = try XCTUnwrap(workspace.startEpisode(targetID: recent.id))
        XCTAssertNotNil(workspace.beginWaiting(
            episodeID: recentEpisode.id,
            description: "刚交出去",
            now: Date(timeIntervalSince1970: 9_000_000)
        ))
        // 让两件事都离开「现在」页。
        let elsewhere = try XCTUnwrap(workspace.createTarget(name: "别的事"))
        XCTAssertNotNil(workspace.startEpisode(targetID: elsewhere.id))

        let list = workspace.snapshot.laterList
        XCTAssertEqual(list.blockedLead?.id, oldWaiting.id)
        XCTAssertEqual(list.blocked.count, 2)
    }

    /// 「不再等待」把球交回你手里：这条从「等着别人」挪进「可以动」。
    func testStoppingAWaitMovesItBackToActionable() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "不等了"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "等不到的东西"
        ))
        let elsewhere = try XCTUnwrap(workspace.createTarget(name: "别的事"))
        XCTAssertNotNil(workspace.startEpisode(targetID: elsewhere.id))
        XCTAssertEqual(workspace.snapshot.laterList.blocked.count, 1)

        XCTAssertTrue(workspace.cancelWaiting(waiting.id))

        let list = workspace.snapshot.laterList
        XCTAssertTrue(list.blocked.isEmpty)
        XCTAssertEqual(list.actionable.map(\.target.id), [target.id])
        XCTAssertFalse(try XCTUnwrap(list.actionable.first).isThawed)
    }

    /// 一件事同时等好几个结果时就是好几条——「结果到了」得落在具体哪一条上。
    func testOneTargetWithSeveralWaitsKeepsARowPerWait() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "等两样东西"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let first = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "等报价",
            now: Date(timeIntervalSince1970: 1_000_000)
        ))
        let second = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "等排期",
            now: Date(timeIntervalSince1970: 2_000_000)
        ))
        let elsewhere = try XCTUnwrap(workspace.createTarget(name: "别的事"))
        XCTAssertNotNil(workspace.startEpisode(targetID: elsewhere.id))

        XCTAssertEqual(workspace.snapshot.laterList.blocked.map(\.waiting.id), [first.id, second.id])

        // 其中一个到了：整件事跟着解冻进「可以动」，另一条不再单独占位——
        // 有东西到了就该去看它。
        XCTAssertTrue(workspace.completeWaiting(first.id, evidence: "报价来了"))
        let list = workspace.snapshot.laterList
        XCTAssertEqual(list.actionable.map(\.target.id), [target.id])
        XCTAssertEqual(list.actionable.first?.readyWaiting?.id, first.id)
        XCTAssertTrue(list.blocked.isEmpty)
    }

    /// 结束一件事，它连同没解决的等待一起离场，不在清单上留孤儿。
    func testFinishedWorkLeavesBothGroups() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "做完了"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        XCTAssertNotNil(workspace.beginWaiting(episodeID: episode.id, description: "不再需要的结果"))

        XCTAssertTrue(workspace.endEpisode(episode.id))

        let list = workspace.snapshot.laterList
        XCTAssertTrue(list.blocked.isEmpty)
        XCTAssertTrue(list.actionable.isEmpty)
    }

    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorLaterListTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events", isDirectory: true)
    }
}
