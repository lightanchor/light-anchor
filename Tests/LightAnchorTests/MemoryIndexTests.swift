import Foundation
import XCTest
@testable import LightAnchor

/// 「对话」页检索索引（docs/chat-memory-design.md 一期）：FTS5 trigram 中文召回、
/// 短词 LIKE 兜底、向量语义命中、内容变更重建、来源消失剪除、追问改写门槛。
final class MemoryIndexTests: XCTestCase {

    /// 可注入的假向量：按关键词给固定轴向量，语义命中可以被精确断言。
    private struct FakeEmbedding: MemoryTextEmbedding {
        let identifier = "test-embedding"
        let isReady = true

        func vector(for text: String) -> [Float]? {
            if text.contains("动画") || text.contains("动效") { return [1, 0] }
            if text.contains("结果") || text.contains("CI") { return [0, 1] }
            return nil
        }
    }

    /// 模型不可用：整批跳过，索引退化为纯 FTS。
    private struct UnavailableEmbedding: MemoryTextEmbedding {
        let identifier = "unavailable"
        let isReady = false
        func vector(for text: String) -> [Float]? { nil }
    }

    // MARK: - 词法召回

    func testChineseFTSSearchAndShortQueryFallback() async throws {
        let index = temporaryIndex(embedding: UnavailableEmbedding())
        try await index.upsert([
            item(key: "capture:a", text: "蓝点重构要先改侧栏动画"),
            item(key: "capture:b", text: "上周在等 CI 的结果")
        ])

        // trigram：≥3 字的中文词直接命中。
        let hits = try await index.search(query: "侧栏动画")
        XCTAssertEqual(hits.first?.key, "capture:a")

        // 全部片段都短于 3 字（trigram 索引够不到）：LIKE 兜底仍要能命中。
        let short = try await index.search(query: "动画")
        XCTAssertEqual(short.first?.key, "capture:a")

        await index.removeAll()
    }

    func testReindexOnContentChangeAndStableWhenUnchanged() async throws {
        let index = temporaryIndex(embedding: UnavailableEmbedding())
        try await index.upsert([item(key: "capture:a", text: "先改侧栏动画")])
        try await index.upsert([item(key: "capture:a", text: "改成先修复布局跳动")])

        let stale = try await index.search(query: "侧栏动画")
        XCTAssertTrue(stale.isEmpty, "旧内容不应再被命中")
        let fresh = try await index.search(query: "布局跳动")
        XCTAssertEqual(fresh.first?.key, "capture:a")

        await index.removeAll()
    }

    func testPruneRemovesStaleSourcesButKeepsChatTurns() async throws {
        let index = temporaryIndex(embedding: UnavailableEmbedding())
        // 三条文本刻意无共词：查询命中不会串门。
        try await index.upsert([
            item(key: "capture:gone", text: "被移除的旧想法条目"),
            item(key: "capture:kept", text: "仍然保留的参考链接")
        ])
        let turnID = UUID()
        await index.indexChatTurns([(id: turnID, question: "上周干了什么", answer: "主要在做蓝点重构", at: Date())])

        // 全量刷新只带 kept：gone 被剪掉，chat 行不受影响。
        try await index.prune(validKeys: ["capture:kept"])
        let gone = try await index.search(query: "旧想法")
        let kept = try await index.search(query: "参考链接")
        let chat = try await index.search(query: "蓝点重构")
        XCTAssertTrue(gone.isEmpty, "\(gone.map(\.key))")
        XCTAssertEqual(kept.first?.key, "capture:kept")
        XCTAssertEqual(chat.first?.key, "chat:\(turnID.uuidString)")

        await index.removeAll()
    }

    // MARK: - 语义召回

    func testHybridFindsSemanticMatchWithoutLexicalOverlap() async throws {
        let index = temporaryIndex(embedding: FakeEmbedding())
        try await index.upsert([
            item(key: "capture:anim", text: "蓝点重构要先改侧栏动画"),
            item(key: "capture:ci", text: "上周在等 CI 的结果")
        ])
        try await index.embedPending(limit: 10)

        // 「动效」与文档没有任何字面重叠，只有向量能把它接到「动画」。
        let hits = try await index.search(query: "界面动效")
        XCTAssertEqual(hits.first?.key, "capture:anim")

        await index.removeAll()
    }

    func testEmbedPendingSkipsUnembeddableTextWithoutStallingBatch() async throws {
        let index = temporaryIndex(embedding: FakeEmbedding())
        try await index.upsert([
            item(key: "capture:none", text: "没有任何关键词的普通文本"),
            item(key: "capture:anim", text: "侧栏动画")
        ])
        // 第一条嵌入返回 nil：写哨兵跳过，不得堵住第二条。
        try await index.embedPending(limit: 10)
        let hits = try await index.search(query: "界面动效")
        XCTAssertEqual(hits.first?.key, "capture:anim")

        await index.removeAll()
    }

    // MARK: - 派生与门槛

    @MainActor
    func testWorkspaceDerivedItemsIncludeCaptures() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        _ = workspace.captureText("蓝点重构要先改侧栏动画", now: Date(timeIntervalSinceNow: -600))

        let items = MemoryIndexSource.items(events: [], snapshot: workspace.snapshot)
        let capture = try XCTUnwrap(items.first { $0.kind == .capture })
        XCTAssertTrue(capture.key.hasPrefix("capture:"))
        XCTAssertTrue(capture.text.contains("蓝点重构"))

        // 键与内容都稳定：重复派生不会引起重写。
        XCTAssertEqual(items, MemoryIndexSource.items(events: [], snapshot: workspace.snapshot))
    }

    func testRewriteGateOnlyFiresOnFollowUps() {
        XCTAssertFalse(
            MemoryQueryRewrite.needsRewrite(question: "那件事呢", hasHistory: false),
            "没有历史就没有可接的指代"
        )
        XCTAssertTrue(MemoryQueryRewrite.needsRewrite(question: "那件事呢", hasHistory: true))
        XCTAssertTrue(MemoryQueryRewrite.needsRewrite(question: "然后呢", hasHistory: true))
        XCTAssertFalse(
            MemoryQueryRewrite.needsRewrite(question: "上周的蓝点重构进展怎么样", hasHistory: true),
            "完整独立的问题不需要花一次改写调用"
        )
    }

    func testNormalizedRewrittenQueryTakesFirstCleanLine() {
        XCTAssertEqual(
            IntelligencePrompts.normalizedRewrittenQuery("\n「蓝点重构的侧栏动画想法」\n另一行"),
            "蓝点重构的侧栏动画想法"
        )
        XCTAssertNil(IntelligencePrompts.normalizedRewrittenQuery("  \n  "))
    }

    // MARK: - 对话页整链

    @MainActor
    func testChatContextMergesIndexHitsWithLiveFacts() async throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        _ = workspace.captureText("蓝点重构要先改侧栏动画", now: Date(timeIntervalSinceNow: -600))

        let index = temporaryIndex(embedding: UnavailableEmbedding())
        let items = MemoryIndexSource.items(events: [], snapshot: workspace.snapshot)
        try await index.upsert(items)

        let context = await workspace.makeChatQuestionContext(
            question: "侧栏动画", history: [], index: index
        )
        let captureLabel = tr("fact_label_capture")
        XCTAssertTrue(
            context.facts.contains { $0.label == captureLabel && $0.text.contains("蓝点重构") },
            "索引命中要以捕获标签进入事实列表：\(context.factLines)"
        )
        XCTAssertTrue(
            context.facts.contains { $0.label == tr("fact_label_now") },
            "活状态事实照旧要在"
        )

        await index.removeAll()
    }

    // MARK: - 端侧向量冒烟（系统资产就绪才跑）

    func testContextualEmbeddingChineseSmoke() throws {
        let embedding = ContextualTextEmbedding()
        guard embedding.isReady else {
            throw XCTSkip("NLContextualEmbedding 中文资产未就绪")
        }
        let anchor = try XCTUnwrap(embedding.vector(for: "蓝点重构要先改侧栏动画"))
        let related = try XCTUnwrap(embedding.vector(for: "界面动效的改造想法"))
        let unrelated = try XCTUnwrap(embedding.vector(for: "周五下午等编译结果"))

        func dot(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        XCTAssertGreaterThan(
            dot(anchor, related), dot(anchor, unrelated),
            "语义相近的句子相似度应更高"
        )
    }

    // MARK: - 工具

    private func item(key: String, text: String, at date: Date = Date()) -> MemoryIndexItem {
        MemoryIndexItem(key: key, kind: .capture, text: text, createdAt: date)
    }

    private func temporaryIndex(embedding: MemoryTextEmbedding) -> MemoryIndex {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-index-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memory-index.sqlite")
        return MemoryIndex(fileURL: url, embedding: embedding)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-index-tests-\(UUID().uuidString)")
            .appendingPathComponent("events.json")
    }
}
