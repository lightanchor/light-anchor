import Foundation
import XCTest
@testable import LightAnchor

/// 应用内工作记忆：检索层（时间词/关键词/事实行）与「问记忆」引擎语义。
final class MemoryRecallTests: XCTestCase {
    private let calendar = Calendar.current

    // MARK: - 时间词解析

    func testParsedPeriodRecognizesRelativeDays() throws {
        let now = Date(timeIntervalSince1970: 1_755_850_000)

        let today = try XCTUnwrap(MemoryRecall.parsedPeriod(question: "我今天专注了多久", now: now, calendar: calendar))
        XCTAssertEqual(today.title, "今天")
        XCTAssertEqual(today.interval.start, calendar.startOfDay(for: now))

        let yesterday = try XCTUnwrap(MemoryRecall.parsedPeriod(question: "昨天做了什么", now: now, calendar: calendar))
        XCTAssertEqual(yesterday.title, "昨天")
        let expectedYesterday = calendar.startOfDay(
            for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        )
        XCTAssertEqual(yesterday.interval.start, expectedYesterday)

        let lastWeek = try XCTUnwrap(MemoryRecall.parsedPeriod(question: "上周主要在忙什么", now: now, calendar: calendar))
        XCTAssertEqual(lastWeek.title, "上周")

        let thisMonth = try XCTUnwrap(MemoryRecall.parsedPeriod(question: "本月完成了几件事", now: now, calendar: calendar))
        XCTAssertEqual(thisMonth.title, "本月")
    }

    func testParsedPeriodRecognizesRecentDaysSpan() throws {
        let now = Date(timeIntervalSince1970: 1_755_850_000)
        let recent = try XCTUnwrap(MemoryRecall.parsedPeriod(question: "最近 3 天在做什么", now: now, calendar: calendar))
        XCTAssertEqual(recent.title, "最近 3 天")
        let expectedStart = calendar.startOfDay(
            for: try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now))
        )
        XCTAssertEqual(recent.interval.start, expectedStart)
        XCTAssertEqual(recent.interval.end, now)
    }

    func testParsedPeriodReturnsNilWithoutTimeWords() {
        XCTAssertNil(MemoryRecall.parsedPeriod(question: "轻锚的重构进展", now: Date(), calendar: calendar))
    }

    // MARK: - 关键词提取

    func testSearchFragmentsStripStopPhrasesAndKeepEntities() {
        let fragments = MemoryRecall.searchFragments(question: "我上周在忙什么？轻锚重构的进展如何")
        XCTAssertTrue(fragments.contains("轻锚重构"), "实体词应保留，实际：\(fragments)")
        XCTAssertFalse(fragments.contains("上周"))
        XCTAssertFalse(fragments.contains { $0.contains("如何") })
    }

    func testSearchFragmentsCapAtFour() {
        let fragments = MemoryRecall.searchFragments(
            question: "alpha beta gamma delta epsilon zeta"
        )
        XCTAssertEqual(fragments.count, 4)
    }

    // MARK: - 问答检索（经 workspace 组装）

    /// 生产路径的同步事实拼装：事件日志从 workspace 落盘的 store 重新读回，
    /// 快照取 workspace 当前投影（与 makeChatQuestionContext 拼装账本/目标事实同源）。
    @MainActor
    private func questionContext(
        _ question: String,
        store: LocalEventStore,
        workspace: AttentionWorkspace
    ) throws -> MemoryQuestionContext {
        MemoryRecall.questionContext(
            question: question,
            events: try store.load(),
            snapshot: workspace.snapshot
        )
    }

    @MainActor
    func testQuestionContextCarriesNowLedgerAndTargetHistory() throws {
        let store = LocalEventStore(directoryURL: temporaryEventsDirectoryURL())
        let workspace = AttentionWorkspace(store: store)
        let start = Date(timeIntervalSinceNow: -1800)
        let target = try XCTUnwrap(workspace.createTarget(name: "写周报", now: start))
        XCTAssertNotNil(workspace.startEpisode(targetID: target.id, now: start))

        let context = try questionContext("写周报花了多久", store: store, workspace: workspace)

        let labels = Set(context.facts.map(\.label))
        XCTAssertTrue(labels.contains("现在"), "缺当前状态行：\(context.factLines)")
        XCTAssertTrue(labels.contains("账本"), "缺账本行：\(context.factLines)")
        let targetFact = context.facts.first { $0.label == "目标" }
        XCTAssertNotNil(targetFact, "问题点名了目标，应有全程纵深：\(context.factLines)")
        XCTAssertTrue(targetFact?.text.contains("写周报") ?? false)
        XCTAssertEqual(context.periodTitle, "最近 7 天")
        XCTAssertLessThanOrEqual(context.facts.count, MemoryRecall.maximumFacts)
    }

    @MainActor
    func testQuestionContextFindsCapturesByKeyword() throws {
        let store = LocalEventStore(directoryURL: temporaryEventsDirectoryURL())
        let workspace = AttentionWorkspace(store: store)
        _ = workspace.captureText("蓝点重构要先改侧栏动画", now: Date(timeIntervalSinceNow: -600))

        let context = try questionContext("蓝点重构记过什么想法", store: store, workspace: workspace)
        let captureFacts = context.facts.filter { $0.label == "捕获" }
        XCTAssertFalse(captureFacts.isEmpty, "关键词应命中捕获：\(context.factLines)")
        XCTAssertTrue(captureFacts.contains { $0.text.contains("蓝点重构") })
    }

    // MARK: - 引擎语义

    func testHeuristicAnswerIsDeterministicRestatement() async {
        let engine = HeuristicIntelligenceEngine()

        let empty = await engine.answerMemoryQuestion(
            MemoryQuestionInput(question: "上周在干嘛", periodTitle: "上周", factLines: [])
        )
        XCTAssertEqual(empty, "记忆里没有上周的记录。")

        let answered = await engine.answerMemoryQuestion(
            MemoryQuestionInput(
                question: "上周在干嘛",
                periodTitle: "上周",
                factLines: ["[账本] 上周共专注 3 小时 20 分，5 段"]
            )
        )
        XCTAssertEqual(answered, "按上周的记录：\n· [账本] 上周共专注 3 小时 20 分，5 段")
    }

    func testCloudEngineThrowsInsteadOfSilentFallbackWhenUnavailable() async {
        // 云端没配端点/模型：问记忆必须抛错并说清原因，绝不静默兜底（用户定）。
        // Key 留空不算「没配置」——免鉴权网关就是这么连的，所以这里缺的是模型。
        let engine = CloudIntelligenceEngine(
            apiKey: "",
            endpoint: "https://example.com/v1/chat/completions",
            model: ""
        )
        do {
            _ = try await engine.answerMemoryQuestion(
                MemoryQuestionInput(question: "q", periodTitle: "今天", factLines: ["[账本] x"])
            )
            XCTFail("未配置的云端引擎应该抛错")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("还没配置好"),
                "错误要说清原因：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - 目标纵深

    @MainActor
    func testTargetHistoryDigestAccumulatesAcrossEpisodes() throws {
        let store = LocalEventStore(directoryURL: temporaryEventsDirectoryURL())
        let workspace = AttentionWorkspace(store: store)
        let dayAgo = Date(timeIntervalSinceNow: -86_400)
        let target = try XCTUnwrap(workspace.createTarget(name: "整理照片", now: dayAgo))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: dayAgo))
        XCTAssertTrue(workspace.endEpisode(episode.id, now: dayAgo.addingTimeInterval(1200)))

        let context = try questionContext("整理照片这件事做到哪了", store: store, workspace: workspace)
        let digest = context.facts.first { $0.label == "目标" }
        XCTAssertNotNil(digest)
        XCTAssertTrue(digest?.text.contains("累计专注") ?? false, "\(String(describing: digest))")
    }

    // MARK: - 历史纵深（F4）

    @MainActor
    func testBriefingInputCarriesTargetHistoryLine() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86_400)
        let target = try XCTUnwrap(workspace.createTarget(name: "整理书房", now: twoDaysAgo))
        let first = try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: twoDaysAgo))
        XCTAssertTrue(workspace.endEpisode(first.id, now: twoDaysAgo.addingTimeInterval(1800)))
        let second = try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: Date(timeIntervalSinceNow: -600)))

        let input = try XCTUnwrap(workspace.makeReturnBriefingInput(episodeID: second.id))
        XCTAssertTrue(input.targetHistoryLine.contains("整理书房"), input.targetHistoryLine)
        XCTAssertTrue(input.targetHistoryLine.contains("累计专注"), input.targetHistoryLine)

        let heroLine = workspace.currentTargetHistoryLine()
        XCTAssertNotNil(heroLine, "两段历史应出现在 hero 小字")
        XCTAssertTrue(heroLine?.contains("累计") ?? false)
    }

    @MainActor
    func testTriageItemsCarryDispositionHintFromSameHostHistory() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
        // 两条同域名链接已定去向（资料），第三条新链接应得到历史提示。
        for index in 0..<2 {
            let capture = try XCTUnwrap(workspace.captureLink(
                URL(string: "https://developer.apple.com/doc\(index)")!,
                title: "文档 \(index)",
                now: Date(timeIntervalSinceNow: Double(-3600 * (index + 2)))
            ))
            XCTAssertTrue(workspace.saveCaptureAsReference(capture.id))
        }
        _ = workspace.captureLink(
            URL(string: "https://developer.apple.com/doc-new")!,
            title: "新文档",
            now: Date(timeIntervalSinceNow: -60)
        )

        let items = workspace.makeInboxTriageItems()
        let hinted = items.first { !$0.historyHint.isEmpty }
        XCTAssertNotNil(hinted, "同域名历史 ≥2 条应给提示：\(items.map(\.historyHint))")
        XCTAssertTrue(hinted?.historyHint.contains("developer.apple.com") ?? false)
        XCTAssertTrue(hinted?.historyHint.contains("存了资料") ?? false)
    }

    @MainActor
    func testNarrativeInputAppendsPeriodComparison() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
        let calendar = Calendar.current
        let now = Date()
        // 上周与本周各一段，叙事事实应出现对比句。
        let lastWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: now))
        let target = try XCTUnwrap(workspace.createTarget(name: "对比测试", now: lastWeek))
        let previous = try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: lastWeek))
        XCTAssertTrue(workspace.endEpisode(previous.id, now: lastWeek.addingTimeInterval(3600)))
        let current = try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: now.addingTimeInterval(-1800)))
        XCTAssertTrue(workspace.endEpisode(current.id, now: now))

        let input = workspace.makeNarrativeInput(for: ReviewPeriod(unit: .week, offset: 0), now: now)
        XCTAssertTrue(
            input.factLines.contains { $0.contains("专注了") && ($0.contains("比上周") || $0.contains("基本持平")) },
            "缺对比句：\(input.factLines)"
        )
    }

    // MARK: - 归档投影（F7）

    @MainActor
    func testArchivedCapturesProjectionAndSearchability() throws {
        let store = LocalEventStore(directoryURL: temporaryEventsDirectoryURL())
        let workspace = AttentionWorkspace(store: store)
        let capture = try XCTUnwrap(workspace.captureText("过期的灵感碎片", now: Date(timeIntervalSinceNow: -300)))
        XCTAssertTrue(workspace.archiveCapture(capture.id))

        XCTAssertEqual(workspace.snapshot.archivedCaptures.map(\.id), [capture.id])
        XCTAssertTrue(workspace.snapshot.inbox.isEmpty)

        // 归档也进问答检索（scope 全量）。
        let context = try questionContext("灵感碎片去哪了", store: store, workspace: workspace)
        XCTAssertTrue(
            context.facts.contains { $0.label == "捕获" && $0.text.contains("归档") },
            context.factLines.joined(separator: "\n")
        )
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-recall-tests-\(UUID().uuidString)")
            .appendingPathComponent("events", isDirectory: true)
    }
}

/// 「对话」页的本地存档：宽容解码、容量上限、坏档不致命。
final class MemoryChatStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let store = MemoryChatStore(fileURL: temporaryFileURL())
        // 日期编码走 millisecondsSince1970，构造毫秒整的时间保证往返相等。
        let asked = Date(timeIntervalSince1970: 1_755_850_000.123)
        let messages = [
            MemoryChatMessage(role: .user, text: "我今天专注了多久？", createdAt: asked),
            MemoryChatMessage(
                role: .assistant,
                text: "今天共专注 2 小时。",
                createdAt: asked.addingTimeInterval(2),
                engineName: "启发式（离线）",
                thinkingSeconds: 1.2,
                factLines: ["[账本] 今天共专注 2 小时，3 段"],
                periodTitle: "今天"
            )
        ]
        try store.save(messages)
        let loaded = try store.load()
        XCTAssertEqual(loaded, messages)
    }

    func testSaveTrimsToMaximumKeepingNewest() throws {
        let store = MemoryChatStore(fileURL: temporaryFileURL())
        let messages = (0..<(MemoryChatStore.maximumMessages + 10)).map {
            MemoryChatMessage(role: .user, text: "第 \($0) 条")
        }
        try store.save(messages)
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, MemoryChatStore.maximumMessages)
        XCTAssertEqual(loaded.last?.text, messages.last?.text)
        XCTAssertEqual(loaded.first?.text, "第 10 条")
    }

    func testInterruptedFlagSurvivesRoundTrip() throws {
        // 半截回答的「已中断」标记要能存下来——重开 app 后它仍不能伪装成完整回答。
        let store = MemoryChatStore(fileURL: temporaryFileURL())
        let partial = MemoryChatMessage(
            role: .assistant,
            text: "答到一半",
            createdAt: Date(timeIntervalSince1970: 1_755_850_000),
            wasInterrupted: true
        )
        try store.save([partial])
        XCTAssertEqual(try store.load().first?.wasInterrupted, true)
    }

    /// 存档坏了要抛出来给「对话」页显示。曾经是静默从空开始——用户看到的是
    /// 历史凭空消失，而盘上那份还在。
    func testLoadThrowsOnCorruptFileInsteadOfSilentlyStartingEmpty() throws {
        let fileURL = temporaryFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not json".data(using: .utf8)!.write(to: fileURL)
        let store = MemoryChatStore(fileURL: fileURL)

        XCTAssertThrowsError(try store.load())
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-chat-tests-\(UUID().uuidString)")
            .appendingPathComponent("memory-chat.json")
    }
}
