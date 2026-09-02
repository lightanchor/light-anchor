import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class FocusLedgerTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }

    // MARK: - 时间账本

    func testPauseAndResumeProduceHonestSegments() throws {
        let (workspace, t0) = makeWorkspace(hour: 9)
        let target = try XCTUnwrap(workspace.createTarget(name: "写周报", now: t0))
        _ = workspace.startEpisode(targetID: target.id, now: t0)
        let episode = try XCTUnwrap(workspace.currentEpisode)
        _ = workspace.pauseEpisode(episode.id, now: t0.addingTimeInterval(30 * 60))
        _ = workspace.resumeEpisode(episode.id, now: t0.addingTimeInterval(40 * 60))
        _ = workspace.endEpisode(episode.id, now: t0.addingTimeInterval(70 * 60))

        let day = calendar.startOfDay(for: t0)
        let durations = workspace.focusDayDurations(now: t0.addingTimeInterval(2 * 3600))
        XCTAssertEqual(durations[day].map { Int($0 / 60) }, 60, "30 + 30 分钟，暂停的 10 分钟不算")

        let summary = workspace.focusPeriodSummary(
            in: DateInterval(start: day, duration: 24 * 3600),
            now: t0.addingTimeInterval(2 * 3600)
        )
        XCTAssertEqual(Int(summary.focusDuration / 60), 60)
        XCTAssertEqual(summary.segmentCount, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.targetStats.first?.targetID, target.id)
    }

    func testOvernightSegmentSplitsAtMidnight() throws {
        let (workspace, evening) = makeWorkspace(hour: 23, minute: 30)
        let target = try XCTUnwrap(workspace.createTarget(name: "夜里赶稿", now: evening))
        _ = workspace.startEpisode(targetID: target.id, now: evening)
        let episode = try XCTUnwrap(workspace.currentEpisode)
        let end = evening.addingTimeInterval(60 * 60) // 次日 00:30
        _ = workspace.pauseEpisode(episode.id, now: end)

        let durations = workspace.focusDayDurations(now: end.addingTimeInterval(600))
        let firstDay = calendar.startOfDay(for: evening)
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        XCTAssertEqual(durations[firstDay].map { Int($0 / 60) }, 30)
        XCTAssertEqual(durations[secondDay].map { Int($0 / 60) }, 30)
    }

    func testSummaryCountsReadyTransitionsAndCaptures() throws {
        let (workspace, t0) = makeWorkspace(hour: 10)
        let target = try XCTUnwrap(workspace.createTarget(name: "修构建", now: t0))
        _ = workspace.startEpisode(targetID: target.id, now: t0)
        let episode = try XCTUnwrap(workspace.currentEpisode)

        _ = workspace.captureText("想法一", now: t0.addingTimeInterval(60))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "等 CI",
            now: t0.addingTimeInterval(120)
        ))
        _ = workspace.completeWaiting(waiting.id, evidence: "CI 绿了", now: t0.addingTimeInterval(600))

        let day = calendar.startOfDay(for: t0)
        let summary = workspace.focusPeriodSummary(
            in: DateInterval(start: day, duration: 24 * 3600),
            now: t0.addingTimeInterval(3600)
        )
        XCTAssertEqual(summary.readyWaitingCount, 1)
        XCTAssertEqual(summary.captureCount, 1)
    }

    func testCurrentEpisodeCountsUpToNow() throws {
        let (workspace, t0) = makeWorkspace(hour: 14)
        let target = try XCTUnwrap(workspace.createTarget(name: "进行中", now: t0))
        _ = workspace.startEpisode(targetID: target.id, now: t0)

        let durations = workspace.focusDayDurations(now: t0.addingTimeInterval(25 * 60))
        XCTAssertEqual(durations[calendar.startOfDay(for: t0)].map { Int($0 / 60) }, 25)
    }



    // MARK: - Helpers

    /// 固定在「昨天 hour:minute」的工作区，避免跨越现在或未来。
    private func makeWorkspace(hour: Int, minute: Int = 0) -> (AttentionWorkspace, Date) {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: yesterday)
        components.hour = hour
        components.minute = minute
        let anchor = calendar.date(from: components) ?? yesterday
        return (workspace, anchor)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusLedgerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.json")
    }
}
