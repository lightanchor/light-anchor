import Foundation
import XCTest
@testable import LightAnchor

/// 回场简报 / 收件箱清理台 / 叙事回顾：启发式引擎行为与工作区组装、应用逻辑。
@MainActor
final class IntelligenceCapabilityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NarrativeStore.storageKey)
        super.tearDown()
    }

    // MARK: - 启发式引擎

    func testHeuristicBriefingComposesFromFacts() async throws {
        let engine = HeuristicIntelligenceEngine()
        let generated = await engine.generateReturnBriefing(ReturnBriefingInput(
            targetName: "修构建",
            targetNote: "",
            returnCue: "重跑 swift test",
            awayMinutes: 25,
            waitingEvidence: "CI 绿了",
            sceneItems: [SceneItem(kind: .file, title: "Build.swift", address: "file:///b")],
            capturesWhileAway: ["[文本] 想起要写文档"]
        ))
        let briefing = try XCTUnwrap(generated)
        XCTAssertTrue(briefing.whereYouWere.contains("Build.swift"))
        XCTAssertTrue(briefing.whatHappened.contains("CI 绿了"))
        XCTAssertTrue(briefing.whatHappened.contains("25 分钟"))
        XCTAssertEqual(briefing.firstStep, "重跑 swift test")
    }

    func testHeuristicTriageNeverGuesses() async {
        let engine = HeuristicIntelligenceEngine()
        let items = [
            InboxTriageItem(
                captureID: UUID(), kind: .link, summary: "一篇文章", ageDays: 1, tags: [],
                historyHint: "过去 30 天同域名 5 条：4 条存了资料"
            ),
            InboxTriageItem(captureID: UUID(), kind: .text, summary: "老想法", ageDays: 20, tags: []),
            InboxTriageItem(captureID: UUID(), kind: .text, summary: "新想法", ageDays: 1, tags: [])
        ]
        let proposals = await engine.triageInbox(items: items, recentTargets: [])
        // 类别/久放先验已取消：一律「先留着」，历史证据只转述、不定夺。
        XCTAssertTrue(proposals.allSatisfy { $0.action == .keep })
        XCTAssertEqual(proposals.map(\.captureID), items.map(\.captureID))
        XCTAssertEqual(proposals[0].reason, "过去 30 天同域名 5 条：4 条存了资料")
        XCTAssertFalse(proposals[1].reason.isEmpty)
    }

    func testHeuristicNarrativeJoinsFactsAndRefusesEmpty() async {
        let engine = HeuristicIntelligenceEngine()
        let text = await engine.generateNarrative(NarrativeInput(
            periodTitle: "本周",
            factLines: ["专注了 3 小时", "完成了 2 件事"]
        ))
        XCTAssertEqual(text, "本周：专注了 3 小时；完成了 2 件事。")
        let empty = await engine.generateNarrative(NarrativeInput(periodTitle: "本周", factLines: []))
        XCTAssertNil(empty)
    }

    // MARK: - 工作区组装

    func testReturnBriefingInputCollectsAwayFacts() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "写方案", now: base))
        _ = workspace.startEpisode(targetID: target.id, now: base)
        let episode = try XCTUnwrap(workspace.currentEpisode)
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            kind: .manual,
            description: "等反馈",
            now: base.addingTimeInterval(600)
        ))
        _ = workspace.captureText("离开期间的想法", now: base.addingTimeInterval(900))
        _ = workspace.completeWaiting(waiting.id, evidence: "反馈到了", now: base.addingTimeInterval(1200))

        let input = try XCTUnwrap(workspace.makeReturnBriefingInput(
            episodeID: episode.id,
            waitingID: waiting.id,
            now: base.addingTimeInterval(1800)
        ))
        XCTAssertEqual(input.targetName, "写方案")
        XCTAssertEqual(input.waitingEvidence, "反馈到了")
        XCTAssertEqual(input.awayMinutes, 20, "从开始等待到现在")
        XCTAssertEqual(input.capturesWhileAway.count, 1)
        XCTAssertTrue(input.capturesWhileAway[0].contains("离开期间的想法"))
    }

    func testApplyTriageProposalsRoutesAndSkips() throws {
        let workspace = makeWorkspace()
        let toArchive = try XCTUnwrap(workspace.captureText("过期想法", now: base))
        let toReference = try XCTUnwrap(workspace.captureText("好资料", now: base))
        let toWait = try XCTUnwrap(workspace.captureText("等回复", now: base))
        let toKeep = try XCTUnwrap(workspace.captureText("先留着", now: base))

        // 没有当前工作：convertToWaiting 必须被跳过而不是失败。
        let outcome = workspace.applyInboxTriageProposals([
            InboxTriageProposal(captureID: toArchive.id, action: .archive, reason: ""),
            InboxTriageProposal(captureID: toReference.id, action: .saveReference, reason: ""),
            InboxTriageProposal(captureID: toWait.id, action: .convertToWaiting, reason: ""),
            InboxTriageProposal(captureID: toKeep.id, action: .keep, reason: "")
        ], now: base.addingTimeInterval(60))

        XCTAssertEqual(outcome.applied, 2)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(workspace.snapshot.captures[toArchive.id]?.status, .archived)
        XCTAssertEqual(workspace.snapshot.captures[toReference.id]?.status, .reference)
        XCTAssertEqual(workspace.snapshot.captures[toWait.id]?.status, .inbox)
        XCTAssertEqual(workspace.snapshot.captures[toKeep.id]?.status, .inbox)
    }

    func testStartTargetProposalCreatesTargetWithoutSwitching() throws {
        let workspace = makeWorkspace()
        let mine = try XCTUnwrap(workspace.createTarget(name: "手头的事", now: base))
        _ = workspace.startEpisode(targetID: mine.id, now: base)
        let capture = try XCTUnwrap(workspace.captureText("值得做的新事", now: base))

        let outcome = workspace.applyInboxTriageProposals([
            InboxTriageProposal(captureID: capture.id, action: .startTarget, reason: "")
        ], now: base.addingTimeInterval(60))

        XCTAssertEqual(outcome.applied, 1)
        let newTarget = try XCTUnwrap(
            workspace.snapshot.targets.values.first { $0.name == "值得做的新事" }
        )
        XCTAssertEqual(
            workspace.currentEpisode?.targetID,
            mine.id,
            "批量整理不能把当前工作切走"
        )
        XCTAssertNotNil(newTarget)
        XCTAssertEqual(workspace.snapshot.captures[capture.id]?.status, .archived)
    }

    func testNarrativeInputSpeaksInFacts() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "写周报", now: base))
        _ = workspace.startEpisode(targetID: target.id, now: base)
        let episode = try XCTUnwrap(workspace.currentEpisode)
        _ = workspace.endEpisode(episode.id, now: base.addingTimeInterval(45 * 60))

        var period = ReviewPeriod(unit: .day, offset: 0)
        // 测试基准日在过去：直接用包含 base 的自然日。
        let interval = DateInterval(
            start: Calendar.current.startOfDay(for: base),
            duration: 24 * 3600
        )
        let summary = workspace.focusPeriodSummary(in: interval, now: base.addingTimeInterval(3600))
        XCTAssertEqual(summary.completedCount, 1)

        period.offset = 0
        let input = workspace.makeNarrativeInput(for: period, now: base.addingTimeInterval(3600))
        XCTAssertTrue(input.factLines.contains { $0.contains("45 分钟") })
        XCTAssertTrue(input.factLines.contains { $0.contains("写周报") })
        XCTAssertTrue(input.factLines.contains { $0.contains("完成了 1 件事") })
    }

    // MARK: - 叙事缓存

    func testNarrativeStoreRoundTripAndCapacity() {
        let key = NarrativeStore.key(for: ReviewPeriod(unit: .week, offset: 0), now: base)
        XCTAssertTrue(key.hasPrefix("week-"))
        NarrativeStore.save("第一版", forKey: key)
        XCTAssertEqual(NarrativeStore.text(forKey: key), "第一版")
        NarrativeStore.save("第二版", forKey: key)
        XCTAssertEqual(NarrativeStore.text(forKey: key), "第二版")
    }

    // MARK: - Helpers

    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IntelligenceCapabilityTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.json")
    }
}
