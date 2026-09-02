import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class WaitingPresentationTests: XCTestCase {
    /// 等待行报的是「结果多久没来」，不是「你放下了多久」。原来这里写的是
    /// 「18 分钟前放下」——一件正在等外部结果的事，用户并没有放下它。
    /// 这两句话分属两个概念，共用一套措辞正是等待与稍后混成一页的起点。
    func testWaitedAgeSaysHowLongTheResultHasBeenMissing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            UserFacingCopy.waitedAge(of: now.addingTimeInterval(-30), now: now),
            tr("waited_just_now")
        )
        let eighteenMinutes = UserFacingCopy.waitedAge(
            of: now.addingTimeInterval(-18 * 60), now: now
        )
        XCTAssertEqual(eighteenMinutes, "已等 18 分钟")
        XCTAssertFalse(eighteenMinutes.contains("放下"), "等待不是放下")

        XCTAssertEqual(
            UserFacingCopy.waitedAge(of: now.addingTimeInterval(-3 * 86_400), now: now),
            "已等 3 天"
        )
    }

    func testWaitingSurfacePutsReadyResultsBeforeActiveWaits() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "等待状态测试"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let ready = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "先完成的结果"
        ))
        let active = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "仍在等待的结果"
        ))
        XCTAssertTrue(workspace.completeWaiting(ready.id, evidence: "完成依据"))

        let projection = WaitingSurfaceSnapshot.make(
            from: workspace.snapshot,
            now: Date(timeIntervalSince1970: 500),
            limit: 2
        )

        XCTAssertEqual(projection.waitingCount, 1)
        XCTAssertEqual(projection.readyCount, 1)
        XCTAssertEqual(projection.items.map(\.id), [ready.id, active.id])
        XCTAssertEqual(projection.items.first?.detail, "已完成 · 完成依据")
        XCTAssertEqual(projection.summary, "1 项结果可返回")
    }

    func testWaitingSurfaceUsesFallbackTargetName() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "稍后删除的目标"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "保留等待记录"
        ))

        let snapshot = workspace.snapshot
        var altered = snapshot
        altered.targets.removeValue(forKey: target.id)
        let projection = WaitingSurfaceSnapshot.make(from: altered)

        XCTAssertEqual(projection.items.first?.id, waiting.id)
        XCTAssertEqual(projection.items.first?.targetTitle, "未命名目标")
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorWaitingPresentationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events.json")
    }
}
