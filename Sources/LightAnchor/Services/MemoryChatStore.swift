import Foundation

// MARK: - 「对话」页的本地存档
//
// 问答不进事件日志：它随时可以重来，不属于注意力事实。
// 存数据根下的 memory-chat.json，原子写。读坏了会抛给「对话」页显示（原文件不覆盖），
// 不静默从空对话开始——那看起来就是历史凭空消失。事件日志不受影响。

struct MemoryChatMessage: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// 真实产生这条回答的引擎名——降级到哪个就写哪个，不冒名。
    var engineName: String?
    var thinkingSeconds: Double?
    /// 回答依据的事实行（「依据」折叠区）。
    var factLines: [String]
    var periodTitle: String?
    /// 引擎出错的回合：正文就是错误原文（含服务端消息），不做静默兜底。
    var isError: Bool
    /// 流式回答中途断掉（用户手动停止或流中途失败）：正文是已产出的部分，
    /// 元信息行标「已中断」——半截答案不能伪装成完整答案。
    var wasInterrupted: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        engineName: String? = nil,
        thinkingSeconds: Double? = nil,
        factLines: [String] = [],
        periodTitle: String? = nil,
        isError: Bool = false,
        wasInterrupted: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.engineName = engineName
        self.thinkingSeconds = thinkingSeconds
        self.factLines = factLines
        self.periodTitle = periodTitle
        self.isError = isError
        self.wasInterrupted = wasInterrupted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case engineName
        case thinkingSeconds
        case factLines
        case periodTitle
        case isError
        case wasInterrupted
    }

    init(from decoder: Decoder) throws {
        // 新字段宽容解码：老存档缺键不致命。
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        engineName = try container.decodeIfPresent(String.self, forKey: .engineName)
        thinkingSeconds = try container.decodeIfPresent(Double.self, forKey: .thinkingSeconds)
        factLines = try container.decodeIfPresent([String].self, forKey: .factLines) ?? []
        periodTitle = try container.decodeIfPresent(String.self, forKey: .periodTitle)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        wasInterrupted = try container.decodeIfPresent(Bool.self, forKey: .wasInterrupted) ?? false
    }
}

struct MemoryChatStore {
    let fileURL: URL

    /// 存档上限：超出丢最旧的。对话是易耗品，账本才是真相。
    static let maximumMessages = 400

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? LightAnchorStorage.memoryChatURL()
    }

    /// 读存档。没有文件（第一次用）不算错；有文件但读不出来要往上抛：
    /// 静默从空对话开始，用户看到的是「历史凭空消失」。
    func load() throws -> [MemoryChatMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Document.self, from: data).messages
    }

    func save(_ messages: [MemoryChatMessage]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let document = Document(
            schemaVersion: 1,
            messages: Array(messages.suffix(Self.maximumMessages))
        )
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var messages: [MemoryChatMessage]

        init(schemaVersion: Int, messages: [MemoryChatMessage]) {
            self.schemaVersion = schemaVersion
            self.messages = messages
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case messages
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            messages = try container.decodeIfPresent([MemoryChatMessage].self, forKey: .messages) ?? []
        }
    }
}
