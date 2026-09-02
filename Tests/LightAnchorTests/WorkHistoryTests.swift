import Foundation
import XCTest
@testable import LightAnchor

final class WorkHistoryTests: XCTestCase {
    func testBuildsReadableTraceFromEpisodeWaitAndScene() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let target = AttentionTarget(name: "修复同步", note: "检查冲突处理", createdAt: start, updatedAt: start)
        let episode = AttentionEpisode(
            targetID: target.id,
            startedAt: start,
            updatedAt: start,
            state: .active
        )
        let waitingID = UUID()
        let waiting = WaitingItem(
            id: waitingID,
            episodeID: episode.id,
            description: "等待测试",
            startedAt: start.addingTimeInterval(240),
            completedAt: start.addingTimeInterval(420),
            status: .ready,
            evidence: "全部测试通过"
        )
        let scene = SceneSnapshot(
            targetID: target.id,
            episodeID: episode.id,
            items: [
                SceneItem(
                    kind: .file,
                    title: "Sync.swift",
                    address: "file:///tmp/Sync.swift",
                    sourceApplication: "Xcode"
                )
            ],
            returnCue: "继续检查错误路径",
            capturedAt: start.addingTimeInterval(600)
        )
        var ended = episode
        ended.state = .ended
        ended.updatedAt = start.addingTimeInterval(600)
        ended.endedAt = start.addingTimeInterval(600)
        ended.endedReason = .completed
        let events: [AttentionEvent] = [
            .targetChanged(target, at: start),
            .episodeChanged(episode, at: start),
            .waitingChanged(waiting, at: start.addingTimeInterval(420)),
            .episodeChanged(ended, at: start.addingTimeInterval(600)),
            .sceneSnapshotChanged(scene, at: start.addingTimeInterval(601))
        ]
        let snapshot = AttentionSnapshot.replay(events)
        let interval = DateInterval(start: start, end: start.addingTimeInterval(24 * 3600))

        let traces = WorkHistoryBuilder.traces(
            events: events,
            snapshot: snapshot,
            interval: interval,
            now: start.addingTimeInterval(700)
        )

        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.targetTitle, "修复同步")
        XCTAssertEqual(trace.summary, "全部测试通过")
        XCTAssertEqual(trace.nextCue, "继续检查错误路径")
        XCTAssertEqual(trace.statusTitle, "已完成")
        XCTAssertEqual(trace.focusDuration, 600, accuracy: 0.001)
        XCTAssertEqual(trace.applications, ["Xcode"])
        XCTAssertEqual(trace.sceneSnapshot?.id, scene.id)
    }

    func testSceneEpisodeIdentifierKeepsSameTargetSessionsSeparate() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let target = AttentionTarget(name: "同一目标", createdAt: start, updatedAt: start)
        let first = AttentionEpisode(
            targetID: target.id,
            startedAt: start,
            updatedAt: start.addingTimeInterval(60),
            state: .paused
        )
        let second = AttentionEpisode(
            targetID: target.id,
            startedAt: start.addingTimeInterval(120),
            updatedAt: start.addingTimeInterval(180),
            state: .paused
        )
        let firstScene = SceneSnapshot(
            targetID: target.id,
            episodeID: first.id,
            items: [SceneItem(kind: .file, title: "first.md", address: "file:///tmp/first.md")],
            capturedAt: start.addingTimeInterval(181)
        )
        let secondScene = SceneSnapshot(
            targetID: target.id,
            episodeID: second.id,
            items: [SceneItem(kind: .file, title: "second.md", address: "file:///tmp/second.md")],
            capturedAt: start.addingTimeInterval(182)
        )
        let events: [AttentionEvent] = [
            .targetChanged(target, at: start),
            .episodeChanged(first, at: start.addingTimeInterval(60)),
            .episodeChanged(second, at: start.addingTimeInterval(180)),
            .sceneSnapshotChanged(firstScene, at: start.addingTimeInterval(181)),
            .sceneSnapshotChanged(secondScene, at: start.addingTimeInterval(182))
        ]
        let snapshot = AttentionSnapshot.replay(events)
        let traces = WorkHistoryBuilder.traces(
            events: events,
            snapshot: snapshot,
            interval: DateInterval(start: start, end: start.addingTimeInterval(3600)),
            now: start.addingTimeInterval(300)
        )

        XCTAssertEqual(
            traces.first(where: { $0.episodeID == first.id })?.sceneSnapshot?.id,
            firstScene.id
        )
        XCTAssertEqual(
            traces.first(where: { $0.episodeID == second.id })?.sceneSnapshot?.id,
            secondScene.id
        )
    }
}
