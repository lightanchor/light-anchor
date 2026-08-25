import Foundation
import NaturalLanguage
import SQLite3

// MARK: - 「对话」页的检索索引（docs/chat-memory-design.md · 一期）
//
// 可检索档案：捕获、工作痕迹、聊天问答入一个 SQLite 索引文件，
// FTS5 trigram 做词法召回（中文免分词），系统端侧句向量做语义召回，
// RRF 融合后按时近与类型加权。零第三方依赖：系统 libsqlite3 + NaturalLanguage。
//
// 索引是可重建的缓存——事实源永远是事件日志。坏了、删了、换机器，
// 下次刷新自动重建；「删除全部本地数据」把它一并清掉。

// MARK: - 索引条目（派生层）

/// 一条待索引内容。key 稳定（同一来源同一键），内容变了靠哈希识别并重写。
struct MemoryIndexItem: Sendable, Equatable {
    enum Kind: String, Sendable {
        case capture
        case trace
        case chat
    }

    let key: String
    let kind: Kind
    let text: String
    let createdAt: Date
}

/// 从事件流与快照派生索引条目。与 MemoryRecall 同一红线：
/// 剪贴板内容、终端命令不进索引。
enum MemoryIndexSource {
    static func items(
        events: [AttentionEvent],
        snapshot: AttentionSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MemoryIndexItem] {
        var items: [MemoryIndexItem] = []

        // 捕获：标题/正文/标签/截图 OCR 文本都可被搜到。
        for capture in snapshot.captures.values {
            var parts: [String] = []
            if let title = capture.title, !title.isEmpty { parts.append(title) }
            if !capture.body.isEmpty { parts.append(capture.body) }
            if !capture.tags.isEmpty { parts.append(capture.tags.map { "#\($0)" }.joined(separator: " ")) }
            if !capture.extractedText.isEmpty { parts.append(String(capture.extractedText.prefix(300))) }
            if let url = capture.sourceURL { parts.append(url.absoluteString) }
            let text = parts.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            items.append(MemoryIndexItem(
                key: "capture:\(capture.id.uuidString)",
                kind: .capture,
                text: text,
                createdAt: capture.capturedAt
            ))
        }

        // 工作痕迹：近 90 天（检索加权的时近窗口一致）。
        let interval = DateInterval(
            start: now.addingTimeInterval(-90 * 24 * 3600),
            end: now.addingTimeInterval(60)
        )
        let traces = WorkHistoryBuilder.traces(
            events: events,
            snapshot: snapshot,
            interval: interval,
            now: now,
            calendar: calendar
        )
        for trace in traces {
            var parts = [trace.targetTitle]
            if !trace.summary.isEmpty { parts.append(trace.summary) }
            if !trace.nextCue.isEmpty { parts.append("下一步：\(trace.nextCue)") }
            items.append(MemoryIndexItem(
                key: "trace:\(trace.episodeID.uuidString)",
                kind: .trace,
                text: parts.joined(separator: "\n"),
                createdAt: trace.lastActivityAt
            ))
        }

        return items
    }
}

// MARK: - 命中

struct MemoryIndexHit: Sendable, Equatable {
    let key: String
    let kind: MemoryIndexItem.Kind
    let text: String
    let createdAt: Date
    let score: Double
}

// MARK: - 端侧句向量

/// 文本→归一化向量。协议存在是为了测试可注入；产品实现只有系统端侧一种。
protocol MemoryTextEmbedding: Sendable {
    /// 模型标识：换模型时索引里的旧向量整体作废重算。
    var identifier: String { get }
    /// 模型就绪与否：未就绪时补算整批跳过（索引退化为纯 FTS，仍好于无）。
    var isReady: Bool { get }
    /// 归一化向量；就绪后仍可能对个别文本返回 nil（该条写哨兵跳过，不卡批次）。
    func vector(for text: String) -> [Float]?
}

/// NLContextualEmbedding（系统自带端侧多语言句向量，CJK 模型 512 维）。
/// token 向量取均值再归一化。资产由系统按需下载，未就绪时返回 nil。
/// @unchecked Sendable：只被 MemoryIndex actor 串行使用。
final class ContextualTextEmbedding: MemoryTextEmbedding, @unchecked Sendable {
    private var model: NLContextualEmbedding?
    private var attempted = false

    var identifier: String {
        loadedModel()?.modelIdentifier ?? "unavailable"
    }

    var isReady: Bool {
        loadedModel() != nil
    }

    func vector(for text: String) -> [Float]? {
        guard let model = loadedModel() else { return nil }
        let clipped = String(text.prefix(300))
        guard !clipped.isEmpty,
              let result = try? model.embeddingResult(for: clipped, language: .simplifiedChinese) else {
            return nil
        }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            for (index, value) in vector.enumerated() where index < sum.count {
                sum[index] += value
            }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let mean = sum.map { Float($0 / Double(count)) }
        return Self.normalized(mean)
    }

    private func loadedModel() -> NLContextualEmbedding? {
        if let model { return model }
        guard !attempted else { return nil }
        attempted = true
        guard let candidate = NLContextualEmbedding(language: .simplifiedChinese),
              candidate.hasAvailableAssets,
              (try? candidate.load()) != nil else {
            return nil
        }
        model = candidate
        return candidate
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
}

// MARK: - 追问改写门槛

enum MemoryQueryRewrite {
    /// 只有追问才值得花一次改写调用：有历史，且问题短或带指代。
    static func needsRewrite(question: String, hasHistory: Bool) -> Bool {
        guard hasHistory else { return false }
        if question.count <= 8 { return true }
        let pronouns = ["那个", "那条", "那件", "这个", "这条", "它", "刚才", "上面", "之前", "继续", "然后呢", "还有呢"]
        return pronouns.contains { question.contains($0) }
    }

    /// 限时等待：改写是锦上添花，不值得让首字延迟超过几秒。
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - 索引服务

/// SQLite 索引的唯一持有者。actor 串行化全部读写；语句都是即用即备。
actor MemoryIndex {
    static let shared = MemoryIndex()

    enum IndexError: LocalizedError {
        case storage(String)

        var errorDescription: String? {
            switch self {
            case .storage(let detail): "检索索引不可用：\(detail)"
            }
        }
    }

    private let fileURL: URL
    private let embedding: MemoryTextEmbedding
    private var database: OpaquePointer?
    private var lastRefreshAt: Date?

    static let schemaVersion = 1
    /// 每轮刷新最多补算多少条向量：控制单次开销，剩余的下轮接着算。
    static let embedBatchLimit = 128

    init(
        fileURL: URL = LightAnchorStorage.memoryIndexURL(),
        embedding: MemoryTextEmbedding = ContextualTextEmbedding()
    ) {
        self.fileURL = fileURL
        self.embedding = embedding
    }

    // 刻意没有 deinit：Swift 6 的 actor deinit 摸不了非 Sendable 的句柄。
    // 共享实例与进程同寿；临时实例（测试）用 removeAll() 关闭并清盘。

    // MARK: 刷新与写入

    /// 全量刷新：upsert 派生条目、清掉来源已消失的旧行（chat 类除外——
    /// 聊天回合只由聊天页追加）、补算一批向量。60 秒节流。
    func refresh(items: [MemoryIndexItem], now: Date = Date()) {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < 60 { return }
        lastRefreshAt = now
        do {
            try upsert(items)
            try prune(validKeys: Set(items.map(\.key)))
            try embedPending(limit: Self.embedBatchLimit)
        } catch {
            LocalDiagnostics.shared.record(
                operation: "memory-index.refresh",
                message: error.localizedDescription
            )
        }
    }

    /// 聊天回合入索引（问答各出现一次的成对文本）。失败只记诊断。
    func indexChatTurns(_ turns: [(id: UUID, question: String, answer: String, at: Date)]) {
        let items = turns.map { turn in
            MemoryIndexItem(
                key: "chat:\(turn.id.uuidString)",
                kind: .chat,
                text: "问：\(String(turn.question.prefix(200)))\n答：\(String(turn.answer.prefix(400)))",
                createdAt: turn.at
            )
        }
        do {
            try upsert(items)
            try embedPending(limit: items.count)
        } catch {
            LocalDiagnostics.shared.record(
                operation: "memory-index.chat",
                message: error.localizedDescription
            )
        }
    }

    func upsert(_ items: [MemoryIndexItem]) throws {
        guard !items.isEmpty else { return }
        let db = try open()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            for item in items {
                let hash = Self.contentHash(item.text)
                if let existing = try existingHash(db, key: item.key), existing == hash {
                    continue
                }
                try run(db, "DELETE FROM docs_fts WHERE key = ?1", binds: [.text(item.key)])
                try run(db, """
                    INSERT INTO docs(key, kind, created_at, content_hash, text, embedding)
                    VALUES(?1, ?2, ?3, ?4, ?5, NULL)
                    ON CONFLICT(key) DO UPDATE SET
                      kind = excluded.kind,
                      created_at = excluded.created_at,
                      content_hash = excluded.content_hash,
                      text = excluded.text,
                      embedding = NULL
                    """, binds: [
                        .text(item.key),
                        .text(item.kind.rawValue),
                        .double(item.createdAt.timeIntervalSinceReferenceDate),
                        .text(hash),
                        .text(item.text)
                    ])
                try run(db, "INSERT INTO docs_fts(key, text) VALUES(?1, ?2)", binds: [
                    .text(item.key), .text(item.text)
                ])
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// 来源消失的行清掉（chat 类除外），避免命中已删除的捕获。
    func prune(validKeys: Set<String>) throws {
        let db = try open()
        var stale: [String] = []
        try query(db, "SELECT key FROM docs WHERE kind != 'chat'", binds: []) { statement in
            if let key = Self.columnText(statement, 0), !validKeys.contains(key) {
                stale.append(key)
            }
        }
        guard !stale.isEmpty else { return }
        for key in stale {
            try run(db, "DELETE FROM docs WHERE key = ?1", binds: [.text(key)])
            try run(db, "DELETE FROM docs_fts WHERE key = ?1", binds: [.text(key)])
        }
    }

    /// 给还没有向量的行补算。模型未就绪整批跳过（纯 FTS 照常工作）；
    /// 个别文本嵌入失败写空哨兵——不能让一条坏文本永远堵住后面的批次。
    func embedPending(limit: Int) throws {
        guard embedding.isReady else { return }
        let db = try open()
        var pending: [(key: String, text: String)] = []
        try query(db, "SELECT key, text FROM docs WHERE embedding IS NULL LIMIT ?1",
                  binds: [.int(limit)]) { statement in
            if let key = Self.columnText(statement, 0), let text = Self.columnText(statement, 1) {
                pending.append((key, text))
            }
        }
        for row in pending {
            let data = embedding.vector(for: row.text)
                .map { vector in vector.withUnsafeBytes { Data($0) } } ?? Data()
            try run(db, "UPDATE docs SET embedding = ?1 WHERE key = ?2", binds: [
                .blob(data), .text(row.key)
            ])
        }
    }

    func removeAll() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 检索

    /// 混合检索：FTS5 trigram（≥3 字词法）∪ 向量（语义）→ RRF 融合，
    /// 再按类型与时近加权。全部片段都短于 3 字时退化为 LIKE 扫描。
    func search(query queryText: String, limit: Int = 8, now: Date = Date()) throws -> [MemoryIndexHit] {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let db = try open()

        var fragments = MemoryRecall.searchFragments(question: trimmed)
        if fragments.isEmpty { fragments = [trimmed] }

        var lexicalRanked: [String] = []
        let matchFragments = fragments.filter { $0.count >= 3 }
        if !matchFragments.isEmpty {
            let match = matchFragments
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " OR ")
            try query(db, """
                SELECT key FROM docs_fts WHERE docs_fts MATCH ?1
                ORDER BY bm25(docs_fts) LIMIT 40
                """, binds: [.text(match)]) { statement in
                if let key = Self.columnText(statement, 0) { lexicalRanked.append(key) }
            }
        }
        if lexicalRanked.isEmpty {
            // trigram 索引够不到 <3 字的词（中文双字词很常见），LIKE 扫描兜住。
            for fragment in fragments.prefix(3) {
                try query(db, """
                    SELECT key FROM docs WHERE text LIKE ?1
                    ORDER BY created_at DESC LIMIT 20
                    """, binds: [.text("%\(fragment)%")]) { statement in
                    if let key = Self.columnText(statement, 0), !lexicalRanked.contains(key) {
                        lexicalRanked.append(key)
                    }
                }
            }
        }

        var vectorRanked: [String] = []
        if let queryVector = embedding.vector(for: trimmed) {
            var scored: [(String, Float)] = []
            try query(db, "SELECT key, embedding FROM docs WHERE embedding IS NOT NULL", binds: []) { statement in
                guard let key = Self.columnText(statement, 0),
                      let vector = Self.columnFloats(statement, 1),
                      vector.count == queryVector.count else { return }
                let dot = zip(vector, queryVector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                scored.append((key, dot))
            }
            vectorRanked = scored.sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
        }

        // RRF（k=60，行业标准融合，免归一化）→ 类型权重 × 时近提升。
        var fused: [String: Double] = [:]
        for (index, key) in lexicalRanked.enumerated() {
            fused[key, default: 0] += 1.0 / (60.0 + Double(index + 1))
        }
        for (index, key) in vectorRanked.enumerated() {
            fused[key, default: 0] += 1.0 / (60.0 + Double(index + 1))
        }
        guard !fused.isEmpty else { return [] }

        var hits: [MemoryIndexHit] = []
        for (key, base) in fused {
            guard let row = try loadDoc(db, key: key) else { continue }
            let ageDays = max(0, now.timeIntervalSince(row.createdAt) / 86_400)
            let freshness = max(0.0, 1.0 - ageDays / 90.0)
            let kindWeight: Double = switch row.kind {
            case .capture: 1.0
            case .trace: 0.95
            case .chat: 0.85
            }
            hits.append(MemoryIndexHit(
                key: key,
                kind: row.kind,
                text: row.text,
                createdAt: row.createdAt,
                score: base * kindWeight * (1.0 + 0.3 * freshness)
            ))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: SQLite 底座

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开索引文件"
            if let handle { sqlite3_close_v2(handle) }
            throw IndexError.storage(message)
        }
        database = handle
        do {
            try migrateIfNeeded(handle)
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
        return handle
    }

    private func migrateIfNeeded(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS docs(
              key TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              created_at REAL NOT NULL,
              content_hash TEXT NOT NULL,
              text TEXT NOT NULL,
              embedding BLOB
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts
              USING fts5(text, key UNINDEXED, tokenize='trigram');
            """)

        // 架构版本变了整库重来（索引是缓存，重建无损）。
        if let stored = try metaValue(db, key: "schemaVersion"),
           stored != String(Self.schemaVersion) {
            try exec(db, "DELETE FROM docs; DELETE FROM docs_fts; DELETE FROM meta;")
        }
        try run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('schemaVersion', ?1)",
                binds: [.text(String(Self.schemaVersion))])

        // 换了嵌入模型：旧向量整体作废，FTS 行保留。
        let model = embedding.identifier
        if let stored = try metaValue(db, key: "embeddingModel"), stored != model {
            try exec(db, "UPDATE docs SET embedding = NULL")
        }
        try run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('embeddingModel', ?1)",
                binds: [.text(model)])
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
        case blob(Data)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ db: OpaquePointer, _ sql: String, binds: [Bind]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.storage(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, bind) in binds.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch bind {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .int(let value):
                sqlite3_bind_int64(statement, index, Int64(value))
            case .blob(let data):
                data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient)
                }
            }
            guard code == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw IndexError.storage(String(cString: sqlite3_errmsg(db)))
            }
        }
        return statement
    }

    private func run(_ db: OpaquePointer, _ sql: String, binds: [Bind]) throws {
        let statement = try prepare(db, sql, binds: binds)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.storage(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(
        _ db: OpaquePointer,
        _ sql: String,
        binds: [Bind],
        row: (OpaquePointer) -> Void
    ) throws {
        let statement = try prepare(db, sql, binds: binds)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                row(statement)
            } else if code == SQLITE_DONE {
                return
            } else {
                throw IndexError.storage(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError.storage(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func existingHash(_ db: OpaquePointer, key: String) throws -> String? {
        var hash: String?
        try query(db, "SELECT content_hash FROM docs WHERE key = ?1", binds: [.text(key)]) { statement in
            hash = Self.columnText(statement, 0)
        }
        return hash
    }

    private func metaValue(_ db: OpaquePointer, key: String) throws -> String? {
        var value: String?
        try query(db, "SELECT value FROM meta WHERE key = ?1", binds: [.text(key)]) { statement in
            value = Self.columnText(statement, 0)
        }
        return value
    }

    private struct DocRow {
        let kind: MemoryIndexItem.Kind
        let text: String
        let createdAt: Date
    }

    private func loadDoc(_ db: OpaquePointer, key: String) throws -> DocRow? {
        var row: DocRow?
        try query(db, "SELECT kind, text, created_at FROM docs WHERE key = ?1",
                  binds: [.text(key)]) { statement in
            guard let rawKind = Self.columnText(statement, 0),
                  let kind = MemoryIndexItem.Kind(rawValue: rawKind),
                  let text = Self.columnText(statement, 1) else { return }
            row = DocRow(
                kind: kind,
                text: text,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            )
        }
        return row
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func columnFloats(_ statement: OpaquePointer, _ index: Int32) -> [Float]? {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, byteCount % MemoryLayout<Float>.size == 0,
              let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = byteCount / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            memcpy(buffer.baseAddress, pointer, byteCount)
            initialized = count
        }
    }

    static func contentHash(_ text: String) -> String {
        // 稳定短哈希（FNV-1a 64）：识别内容是否变化，不做安全用途。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
