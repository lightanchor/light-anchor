import Foundation
import XCTest
@testable import LightAnchor

/// 这一段的总结（「上次做到哪」）。
///
/// 守的是三件事：事实只来自这一段自己的采集；两小节的骨架不许走形；
/// 用户改过的那份不被自动重写覆盖。
@MainActor
final class EpisodeSummaryTests: XCTestCase {
    private var savedPreferences: Data?

    override func setUp() {
        super.setUp()
        // 偏好落在共用的标准域里，跑完还原，别把这台机器的真实设置带走。
        savedPreferences = UserDefaults.standard.data(forKey: IntelligencePreferences.storageKey)
    }

    override func tearDown() {
        if let savedPreferences {
            UserDefaults.standard.set(savedPreferences, forKey: IntelligencePreferences.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: IntelligencePreferences.storageKey)
        }
        super.tearDown()
    }

    // MARK: - 事实组装

    func testSummaryInputCollectsOnlyThisSegmentsFacts() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "整理访谈材料", note: "先摘要点"))
        let episode = try XCTUnwrap(workspace.startEpisode(
            targetID: target.id,
            context: ContextCapsule(
                applications: ["Obsidian"],
                applicationBundleIdentifiers: ["md.obsidian"],
                files: [URL(fileURLWithPath: "/tmp/访谈提纲 v3.md")],
                links: [URL(string: "https://example.com/interview-notes")!]
            ),
            returnCue: "第 4 题问得太宽"
        ))
        // 另一件事的段：它的事实一条都不许混进来。
        let other = try XCTUnwrap(workspace.createTarget(name: "别的事"))
        _ = workspace.startEpisode(
            targetID: other.id,
            context: ContextCapsule(files: [URL(fileURLWithPath: "/tmp/无关.md")])
        )

        let input = try XCTUnwrap(workspace.makeEpisodeSummaryInput(episodeID: episode.id))
        XCTAssertEqual(input.targetName, "整理访谈材料")
        XCTAssertEqual(input.returnCue, "第 4 题问得太宽")
        XCTAssertFalse(input.periodTitle.isEmpty)
        XCTAssertTrue(input.factLines.contains { $0.contains("访谈提纲 v3.md") })
        XCTAssertFalse(input.factLines.contains { $0.contains("无关.md") })
    }

    func testSegmentWithoutFactsGetsNoSummary() async throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "什么都还没动"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        XCTAssertNil(workspace.makeEpisodeSummaryInput(episodeID: episode.id))
        let wrote = await workspace.summarizeEpisode(episode.id)
        XCTAssertFalse(wrote, "无话可说时不该生出一段像模像样的空话")
        XCTAssertNil(workspace.snapshot.episodes[episode.id]?.summary)
    }

    // MARK: - 不许冒名降级

    /// 启发式引擎**不写总结**：把事实按序拼成两小节读起来像总结，其实一个字
    /// 也没提炼，署上名就是假的。宁可没有，也不要一份假的（用户定）。
    func testHeuristicEngineRefusesToFakeASummary() async {
        let engine = HeuristicIntelligenceEngine()
        do {
            _ = try await engine.summarizeEpisode(EpisodeSummaryInput(
                targetName: "整理访谈材料",
                targetNote: "",
                periodTitle: "9 月 6 日 15:30 那一段 · 专注 28 分",
                returnCue: "第 4 题问得太宽",
                factLines: ["[文件] 访谈提纲 v3.md", "这一段专注 28 分钟"]
            ))
            XCTFail("启发式引擎不该给出总结")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                tr("episode_summary_needs_an_engine")
            )
        }
    }

    /// 引擎失败时如实记下原因，不落任何总结。
    func testFailureIsReportedNotPaperedOver() async throws {
        let workspace = makeWorkspace(engine: FailingEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))

        let wrote = await workspace.summarizeEpisode(episode.id)
        XCTAssertFalse(wrote)
        XCTAssertNil(workspace.snapshot.episodes[episode.id]?.summary, "失败不许留下一份假总结")
        XCTAssertEqual(workspace.summaryFailures[episode.id], FailingEngine.message)
        XCTAssertTrue(workspace.summarizingEpisodeIDs.isEmpty)
    }

    /// 没配引擎（云端没 Key）时同样只记原因。
    func testNoEngineMeansNoSummary() async throws {
        let workspace = makeWorkspace()
        let episode = try XCTUnwrap(seedSegment(in: workspace))

        let wrote = await workspace.summarizeEpisode(episode.id)
        XCTAssertFalse(wrote)
        XCTAssertNil(workspace.snapshot.episodes[episode.id]?.summary)
        XCTAssertNotNil(workspace.summaryFailures[episode.id])
    }

    /// 下一次成功要把上次那条失败原因清掉。
    func testASuccessfulRunClearsTheFailure() async throws {
        let workspace = makeWorkspace(engine: FailingEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))
        _ = await workspace.summarizeEpisode(episode.id)
        XCTAssertNotNil(workspace.summaryFailures[episode.id])

        let ok = makeWorkspace(engine: StubEngine())
        // 换一套能用的引擎：同一段重跑一次（用另一份工作区，语义一样）。
        let good = try XCTUnwrap(seedSegment(in: ok))
        let wrote = await ok.summarizeEpisode(good.id)
        XCTAssertTrue(wrote)
        XCTAssertNil(ok.summaryFailures[good.id])
    }

    /// 设置里的「ADHD 友好输出」管所有生成的文字，总结也算。
    func testAdhdFriendlyOutputShapesTheSummaryInstructions() {
        let shaped = IntelligencePrompts.styled(
            IntelligencePrompts.episodeSummaryInstructions,
            adhdFriendly: true
        )
        let plain = IntelligencePrompts.styled(
            IntelligencePrompts.episodeSummaryInstructions,
            adhdFriendly: false
        )
        XCTAssertTrue(shaped.contains(IntelligencePrompts.adhdOutputStyle))
        XCTAssertFalse(plain.contains(IntelligencePrompts.adhdOutputStyle))
        // 两种情况下任务本身那两小节的骨架都在（提示词是中文原文，不走 tr）。
        for instructions in [shaped, plain] {
            XCTAssertTrue(instructions.contains("## 当时在干什么"))
            XCTAssertTrue(instructions.contains("## 卡在哪"))
        }
    }

    func testSummaryUserPromptCarriesTheSegmentAndTheCue() {
        let prompt = IntelligencePrompts.episodeSummaryUser(EpisodeSummaryInput(
            targetName: "整理访谈材料",
            targetNote: "先摘要点",
            periodTitle: "那一段 · 专注 28 分",
            returnCue: "第 4 题问得太宽",
            factLines: ["[文件] 访谈提纲 v3.md"]
        ))
        XCTAssertTrue(prompt.contains("整理访谈材料"))
        XCTAssertTrue(prompt.contains("先摘要点"))
        XCTAssertTrue(prompt.contains("那一段 · 专注 28 分"))
        XCTAssertTrue(prompt.contains("第 4 题问得太宽"))
        XCTAssertTrue(prompt.contains("- [文件] 访谈提纲 v3.md"))
    }

    // MARK: - 落到段上

    func testSummarizeEpisodeWritesItOntoThatSegmentAndSurvivesReload() async throws {
        let storeURL = temporaryEventsDirectoryURL()
        let workspace = makeWorkspace(storeURL: storeURL, engine: StubEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))

        let wrote = await workspace.summarizeEpisode(episode.id)
        XCTAssertTrue(wrote)
        let summary = try XCTUnwrap(workspace.snapshot.episodes[episode.id]?.summary)
        XCTAssertEqual(summary.text, StubEngine.text)
        XCTAssertEqual(summary.engineName, StubEngine().name, "总结必须署名是哪套引擎写的")
        XCTAssertGreaterThan(summary.factCount, 0)
        XCTAssertFalse(summary.isEdited)
        XCTAssertGreaterThan(summary.characterCount, 0)
        XCTAssertTrue(workspace.summarizingEpisodeIDs.isEmpty)

        let reloaded = AttentionWorkspace(store: LocalEventStore(directoryURL: storeURL))
        XCTAssertEqual(reloaded.snapshot.episodes[episode.id]?.summary, summary)
    }

    func testEditedSummaryIsNotOverwrittenUnlessForced() async throws {
        let workspace = makeWorkspace(engine: StubEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))

        XCTAssertTrue(workspace.updateEpisodeSummary(episode.id, text: "我自己写的那份"))
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.summary?.text, "我自己写的那份")
        XCTAssertTrue(workspace.snapshot.episodes[episode.id]?.summary?.isEdited == true)

        let auto = await workspace.summarizeEpisode(episode.id)
        XCTAssertFalse(auto, "改过的那份不许被自动重写覆盖")
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.summary?.text, "我自己写的那份")

        let forced = await workspace.summarizeEpisode(episode.id, force: true)
        XCTAssertTrue(forced, "用户自己点「重新整理」时才重写")
        XCTAssertNotEqual(workspace.snapshot.episodes[episode.id]?.summary?.text, "我自己写的那份")
        XCTAssertFalse(workspace.snapshot.episodes[episode.id]?.summary?.isEdited == true)
    }

    func testClearingTheSummaryRemovesIt() async throws {
        let workspace = makeWorkspace(engine: StubEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))
        _ = await workspace.summarizeEpisode(episode.id)
        XCTAssertNotNil(workspace.snapshot.episodes[episode.id]?.summary)

        XCTAssertTrue(workspace.updateEpisodeSummary(episode.id, text: "   "))
        XCTAssertNil(workspace.snapshot.episodes[episode.id]?.summary)
    }

    /// 总结要在你回来之前就写好：放下的那一刻自动跑。
    func testSettingSomethingAsideSummarizesItAutomatically() async throws {
        let workspace = makeWorkspace(engine: StubEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))

        XCTAssertTrue(workspace.pauseEpisode(episode.id, returnCue: "先去开会"))
        try await waitForSummary(of: episode.id, in: workspace)
        XCTAssertNotNil(workspace.snapshot.episodes[episode.id]?.summary)
    }

    /// 偏好关掉就一次也不跑（云端调用要花钱，这颗开关必须真的管事）。
    func testAutoSummaryStaysOffWhenThePreferenceIsOff() async throws {
        let workspace = makeWorkspace(autoSummarize: false, engine: StubEngine())
        let episode = try XCTUnwrap(seedSegment(in: workspace))

        XCTAssertTrue(workspace.pauseEpisode(episode.id, returnCue: "先去开会"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(workspace.snapshot.episodes[episode.id]?.summary)
    }

    // MARK: - 夹具

    private func makeWorkspace(
        storeURL: URL? = nil,
        autoSummarize: Bool = true,
        engine: IntelligenceEngineProtocol? = nil
    ) -> AttentionWorkspace {
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: storeURL ?? temporaryEventsDirectoryURL()),
            sceneCapturePreferences: SceneCapturePreferences(),
            recordingTraceStore: RecordingTraceStore(directoryURL: temporaryDirectoryURL()),
            clipboardHistoryStore: ClipboardHistoryStore(directoryURL: temporaryDirectoryURL()),
            contextCapture: { _, _ in ContextCapsule() },
            // 不传引擎就是「没配」：云端没 Key，测试不出网也不降级。
            intelligenceEngine: engine
        )
        var preferences = IntelligencePreferences.default
        preferences.autoSummarizeEpisodes = autoSummarize
        preferences.engine = .cloud
        workspace.updateIntelligencePreferences(preferences)
        return workspace
    }

    /// 一段有东西可说的工作：现场里有文件和应用，身上留了一句话。
    private func seedSegment(in workspace: AttentionWorkspace) -> AttentionEpisode? {
        guard let target = workspace.createTarget(name: "整理访谈材料") else { return nil }
        return workspace.startEpisode(
            targetID: target.id,
            context: ContextCapsule(
                applications: ["Obsidian"],
                applicationBundleIdentifiers: ["md.obsidian"],
                files: [URL(fileURLWithPath: "/tmp/访谈提纲 v3.md")],
                terminalWorkingDirectories: [URL(fileURLWithPath: "/tmp")],
                terminalCommands: ["swift test"]
            ),
            returnCue: "第 4 题问得太宽"
        )
    }

    private func waitForSummary(
        of episodeID: UUID,
        in workspace: AttentionWorkspace,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if workspace.snapshot.episodes[episodeID]?.summary != nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等不到自动整理出的总结")
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events", isDirectory: true)
    }

    // MARK: 替身引擎

    /// 会写总结的那种：只实现这一个能力，其余走协议默认或空实现。
    private struct StubEngine: IntelligenceEngineProtocol {
        static let text = "## 当时在干什么\n把要点摘进提纲。\n\n## 卡在哪\n第 4 题问得太宽。"

        let name = "替身模型"
        let isAvailable = true

        func filterSceneItems(items: [SceneItem], targetName: String, targetNote: String) async -> [SceneRelevanceResult] { [] }
        func generateReturnCue(items: [SceneItem], targetName: String, lastEditedFile: String?, lastTerminalCommand: String?) async -> String { "" }
        func generateReturnBriefing(_ input: ReturnBriefingInput) async -> ReturnBriefing? { nil }
        func triageInbox(items: [InboxTriageItem], recentTargets: [String]) async -> [InboxTriageProposal] { [] }
        func generateNarrative(_ input: NarrativeInput) async -> String? { nil }
        func summarizeEpisode(_ input: EpisodeSummaryInput) async throws -> String { Self.text }
        func answerMemoryQuestion(_ input: MemoryQuestionInput) async throws -> String { "" }
        func composeRecordMarkdown(_ input: RecordComposeInput) async throws -> String { "" }
    }

    /// 会失败的那种：模拟服务端报错，原文必须原样亮给用户。
    private struct FailingEngine: IntelligenceEngineProtocol {
        static let message = "429 Too Many Requests"

        let name = "会失败的模型"
        let isAvailable = true

        func filterSceneItems(items: [SceneItem], targetName: String, targetNote: String) async -> [SceneRelevanceResult] { [] }
        func generateReturnCue(items: [SceneItem], targetName: String, lastEditedFile: String?, lastTerminalCommand: String?) async -> String { "" }
        func generateReturnBriefing(_ input: ReturnBriefingInput) async -> ReturnBriefing? { nil }
        func triageInbox(items: [InboxTriageItem], recentTargets: [String]) async -> [InboxTriageProposal] { [] }
        func generateNarrative(_ input: NarrativeInput) async -> String? { nil }
        func summarizeEpisode(_ input: EpisodeSummaryInput) async throws -> String {
            throw MemoryAnswerError.engineUnavailable(Self.message)
        }
        func answerMemoryQuestion(_ input: MemoryQuestionInput) async throws -> String { "" }
        func composeRecordMarkdown(_ input: RecordComposeInput) async throws -> String { "" }
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
