import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class AutoWaitTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testAgentStartedCreatesBackgroundWaitAndCompletionMakesItReady() throws {
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .agent, kind: .started,
                    correlation: "claude-a", title: "Claude Code · light-anchor", at: base)
        route(inbox, into: workspace)

        let waiting = try XCTUnwrap(workspace.snapshot.waitingItems.values.first)
        XCTAssertEqual(waiting.kind, .agent)
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.description, "Claude Code · light-anchor")
        XCTAssertEqual(waiting.monitor?.eventAutoManaged, true)

        let target = try XCTUnwrap(workspace.snapshot.targets[AutoWaitHub.agentTargetID])
        XCTAssertEqual(target.name, "Agent 会话")
        let episode = try XCTUnwrap(workspace.snapshot.episodes[waiting.episodeID])
        XCTAssertTrue(episode.isBackground)
        XCTAssertNil(workspace.snapshot.currentEpisodeID, "自动等待不能占据当前工作")

        try publish(inbox, source: .agent, kind: .completed,
                    correlation: "claude-a", title: "Claude Code · light-anchor",
                    detail: "回合结束，等你回看", at: base.addingTimeInterval(60))
        route(inbox, into: workspace)

        let ready = try XCTUnwrap(workspace.snapshot.waitingItems[waiting.id])
        XCTAssertEqual(ready.status, .ready)
        XCTAssertTrue(ready.evidence.contains("回合结束"))
        XCTAssertEqual(workspace.snapshot.readyWaitingItems.map(\.id), [waiting.id])
    }

    func testFailedAgentTurnBecomesReadyNotCancelled() throws {
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .agent, kind: .started, correlation: "claude-b",
                    title: "Claude Code · demo", at: base)
        try publish(inbox, source: .agent, kind: .failed, correlation: "claude-b",
                    title: "Claude Code · demo", detail: "构建失败", at: base.addingTimeInterval(30))
        route(inbox, into: workspace)

        let waiting = try XCTUnwrap(workspace.snapshot.waitingItems.values.first)
        XCTAssertEqual(waiting.status, .ready, "失败是需要回去看的结果，不是取消")
        XCTAssertTrue(waiting.evidence.contains("失败"))
    }

    func testNewTurnReopensTheSameWait() throws {
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .agent, kind: .started, correlation: "claude-c",
                    title: "Claude Code · 回合一", at: base)
        try publish(inbox, source: .agent, kind: .completed, correlation: "claude-c",
                    title: "Claude Code · 回合一", detail: "回合结束", at: base.addingTimeInterval(60))
        try publish(inbox, source: .agent, kind: .started, correlation: "claude-c",
                    title: "Claude Code · 回合二", at: base.addingTimeInterval(120))
        route(inbox, into: workspace)

        XCTAssertEqual(workspace.snapshot.waitingItems.count, 1, "同一会话复用同一个等待")
        let waiting = try XCTUnwrap(workspace.snapshot.waitingItems.values.first)
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.description, "Claude Code · 回合二")
        XCTAssertNil(waiting.completedAt)

        try publish(inbox, source: .agent, kind: .completed, correlation: "claude-c",
                    detail: "第二回合结束", at: base.addingTimeInterval(180))
        route(inbox, into: workspace)
        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .ready)
    }

    func testReplayFromScratchIsIdempotent() throws {
        let storeURL = temporaryFileURL()
        let inbox = temporaryFileURL("external-events.jsonl")
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: storeURL),
            externalEventInboxURL: inbox
        )
        try publish(inbox, source: .agent, kind: .started, correlation: "claude-d",
                    title: "Claude Code · d", at: base)
        try publish(inbox, source: .agent, kind: .completed, correlation: "claude-d",
                    detail: "回合结束", at: base.addingTimeInterval(60))
        route(inbox, into: workspace)
        let firstPass = workspace.snapshot.waitingItems

        // 重启：新工作区 + 新路由器（游标归零），重放整个收件箱。
        let reopened = AttentionWorkspace(
            store: LocalEventStore(fileURL: storeURL),
            externalEventInboxURL: inbox
        )
        route(inbox, into: reopened)
        XCTAssertEqual(reopened.snapshot.waitingItems, firstPass, "重放不得翻旧账或复制等待")
    }

    func testDeclaredWaitWithSameCorrelationIsLeftAlone() throws {
        let (workspace, inbox) = makeWorkspace()
        _ = workspace.createTarget(name: "查文档")
        let episode = try XCTUnwrap(workspace.currentEpisode ?? startEpisode(workspace))
        let declared = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            kind: .download,
            description: "下载报告",
            monitor: WaitingMonitorConfiguration(
                kind: .event,
                eventCorrelationID: "shared-x",
                eventSources: [.download]
            )
        ))

        try publish(inbox, source: .agent, kind: .started, correlation: "shared-x",
                    title: "Claude Code · x", at: base)
        route(inbox, into: workspace)

        XCTAssertEqual(workspace.snapshot.waitingItems.count, 1)
        XCTAssertEqual(workspace.snapshot.waitingItems[declared.id]?.kind, .download)
    }

    /// 自动归集的来源只有 agent 和 terminal，由 `AutoWaitHub.descriptor` 一处决定。
    /// 设置里曾有第二个总闸（设置 → 接收 的两个开关），和「连接」页的接入/移除
    /// 重复且会静默丢事件，已经删掉——这条守住「没有第二个真相」。
    func testSourcesWithoutAHubAreIgnored() throws {
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .calendar, kind: .started, correlation: "cal-e",
                    title: "日程", at: base)
        route(inbox, into: workspace)
        XCTAssertTrue(workspace.snapshot.waitingItems.isEmpty)

        try publish(inbox, source: .agent, kind: .started, correlation: "claude-e",
                    title: "Claude Code · e", at: base.addingTimeInterval(1))
        route(inbox, into: workspace)
        XCTAssertEqual(workspace.snapshot.waitingItems.count, 1, "有中枢的来源照常归集")
    }

    func testCompletionOnlyToolReopensTheSameWaitPerTurn() throws {
        // Codex 的 notify 只有 agent-turn-complete：没有 started，
        // 每个回合都是一条更新的 completed。
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .agent, kind: .completed, correlation: "codex-t1",
                    title: "Codex · demo", detail: "第一回合结束", at: base)
        route(inbox, into: workspace)

        let waiting = try XCTUnwrap(workspace.snapshot.waitingItems.values.first)
        XCTAssertEqual(waiting.status, .ready)

        // 用户确认后，下一回合的完成事件要重开同一项并再次就绪。
        XCTAssertTrue(workspace.acknowledgeWaitingResult(waiting.id, now: base.addingTimeInterval(30)))
        try publish(inbox, source: .agent, kind: .completed, correlation: "codex-t1",
                    title: "Codex · demo", detail: "第二回合结束", at: base.addingTimeInterval(120))
        route(inbox, into: workspace)

        XCTAssertEqual(workspace.snapshot.waitingItems.count, 1, "同一线程复用同一个等待")
        let reopened = try XCTUnwrap(workspace.snapshot.waitingItems[waiting.id])
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertTrue(reopened.evidence.contains("第二回合结束"))

        // 重放旧事件不得翻账。
        route(inbox, into: workspace)
        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .ready)
        XCTAssertTrue(
            workspace.snapshot.waitingItems[waiting.id]?.evidence.contains("第二回合结束") == true
        )
    }

    func testBrandIsDerivedFromCorrelationPrefix() throws {
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .agent, kind: .started, correlation: "claude-x",
                    title: "Claude Code · x", at: base)
        try publish(inbox, source: .agent, kind: .completed, correlation: "codex-y",
                    title: "Codex · y", at: base)
        try publish(inbox, source: .agent, kind: .completed, correlation: "pi-42",
                    title: "PI · demo", at: base)
        try publish(inbox, source: .agent, kind: .completed, correlation: "dsh-42-main",
                    title: "dsh · demo", at: base)
        try publish(inbox, source: .terminal, kind: .completed, correlation: "sh-1-1",
                    title: "make build", at: base)
        route(inbox, into: workspace)

        let waits = workspace.snapshot.waitingItems.values
        XCTAssertEqual(
            IntegrationBrand.forAutoWait(try XCTUnwrap(
                waits.first { $0.monitor?.eventCorrelationID == "claude-x" }
            )),
            .claudeCode
        )
        XCTAssertEqual(
            IntegrationBrand.forAutoWait(try XCTUnwrap(
                waits.first { $0.monitor?.eventCorrelationID == "codex-y" }
            )),
            .codex
        )
        XCTAssertEqual(
            IntegrationBrand.forAutoWait(try XCTUnwrap(
                waits.first { $0.monitor?.eventCorrelationID == "pi-42" }
            )),
            .pi
        )
        XCTAssertEqual(
            IntegrationBrand.forAutoWait(try XCTUnwrap(
                waits.first { $0.monitor?.eventCorrelationID == "dsh-42-main" }
            )),
            .dsh
        )
        XCTAssertEqual(
            IntegrationBrand.forAutoWait(try XCTUnwrap(
                waits.first { $0.monitor?.eventCorrelationID == "sh-1-1" }
            )),
            .terminal
        )
        // 非自动等待不贴牌子。
        _ = workspace.createTarget(name: "普通事", now: base)
        let episode = try XCTUnwrap(startEpisode(workspace))
        let manual = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id, kind: .manual, description: "等回复", now: base
        ))
        XCTAssertNil(IntegrationBrand.forAutoWait(manual))
    }

    func testTerminalCompletionWithoutStartStillSurfacesResult() throws {
        let (workspace, inbox) = makeWorkspace()
        try publish(inbox, source: .terminal, kind: .completed, correlation: "sh-1-42",
                    title: "swift test", detail: "退出码 0", at: base)
        route(inbox, into: workspace)

        let waiting = try XCTUnwrap(workspace.snapshot.waitingItems.values.first)
        XCTAssertEqual(waiting.kind, .command)
        XCTAssertEqual(waiting.status, .ready)
        XCTAssertEqual(waiting.description, "swift test")
        XCTAssertEqual(
            workspace.snapshot.targets[AutoWaitHub.terminalTargetID]?.name,
            "终端命令"
        )
    }

    func testAcknowledgeResolvesWithoutTouchingCurrentWork() throws {
        let (workspace, inbox) = makeWorkspace()
        _ = workspace.createTarget(name: "写周报")
        let mine = try XCTUnwrap(startEpisode(workspace))

        try publish(inbox, source: .agent, kind: .started, correlation: "claude-f",
                    title: "Claude Code · f", at: base)
        try publish(inbox, source: .agent, kind: .completed, correlation: "claude-f",
                    detail: "回合结束", at: base.addingTimeInterval(30))
        route(inbox, into: workspace)

        let waiting = try XCTUnwrap(
            workspace.snapshot.waitingItems.values.first { $0.monitor?.eventAutoManaged == true }
        )
        XCTAssertTrue(workspace.acknowledgeWaitingResult(waiting.id, now: base.addingTimeInterval(60)))
        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .resolved)
        XCTAssertEqual(workspace.snapshot.currentEpisodeID, mine.id)
        XCTAssertEqual(workspace.snapshot.episodes[mine.id]?.state, .active)
        XCTAssertEqual(
            workspace.snapshot.episodes[waiting.episodeID]?.state,
            .paused,
            "确认后后台 episode 收起为暂停"
        )
    }

    // MARK: - Helpers

    private func makeWorkspace() -> (AttentionWorkspace, URL) {
        let inbox = temporaryFileURL("external-events.jsonl")
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: temporaryFileURL()),
            externalEventInboxURL: inbox
        )
        return (workspace, inbox)
    }

    private func route(_ inbox: URL, into workspace: AttentionWorkspace) {
        AutoWaitRouter(inboxURL: inbox).route(into: workspace)
    }

    private func publish(
        _ inbox: URL,
        source: ExternalEventSource,
        kind: ExternalEventKind,
        correlation: String,
        title: String = "",
        detail: String = "",
        at date: Date
    ) throws {
        try ExternalEventStore(fileURL: inbox).publish(ExternalEvent(
            source: source,
            kind: kind,
            correlationID: correlation,
            title: title,
            detail: detail,
            occurredAt: date
        ))
    }

    private func startEpisode(_ workspace: AttentionWorkspace) -> AttentionEpisode? {
        guard let target = workspace.snapshot.targets.values.first else { return nil }
        return workspace.startEpisode(targetID: target.id, now: base)
    }

    private func temporaryFileURL(_ name: String = "events.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoWaitTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}
