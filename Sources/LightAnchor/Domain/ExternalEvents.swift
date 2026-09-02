import Foundation

enum ExternalEventSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case ide
    case terminal
    case build
    case download
    case export
    case reply
    case calendar
    case agent
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ide: "IDE"
        case .terminal: tr("terminal")
        case .build: tr("build_tools")
        case .download: tr("download_tools")
        case .export: tr("export_tools")
        case .reply: tr("reply_connector")
        case .calendar: tr("calendar")
        case .agent: "Agent"
        case .custom: tr("other_connectors")
        }
    }
}

enum ExternalEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case started
    case progress
    case completed
    case failed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .started: tr("started")
        case .progress: tr("in_progress")
        case .completed: tr("completed")
        case .failed: tr("failed_2")
        case .cancelled: tr("cancelled")
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .started, .progress: false
        }
    }
}

struct ExternalEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: ExternalEventSource
    let kind: ExternalEventKind
    let correlationID: String
    let title: String
    let detail: String
    let payload: [String: String]
    let occurredAt: Date
    let processIdentifier: Int32?
    let workingDirectory: URL?

    init(
        id: UUID = UUID(),
        source: ExternalEventSource,
        kind: ExternalEventKind,
        correlationID: String,
        title: String = "",
        detail: String = "",
        payload: [String: String] = [:],
        occurredAt: Date = Date(),
        processIdentifier: Int32? = nil,
        workingDirectory: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.correlationID = String(
            correlationID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxCorrelationLength)
        )
        self.title = Self.clean(title, limit: Self.maxTitleLength)
        self.detail = Self.clean(detail, limit: Self.maxDetailLength)
        self.payload = Dictionary(
            uniqueKeysWithValues: payload
                .sorted { $0.key < $1.key }
                .prefix(Self.maxPayloadEntries)
                .map { (String($0.key.prefix(64)), Self.clean($0.value, limit: Self.maxDetailLength)) }
        )
        self.occurredAt = occurredAt
        self.processIdentifier = processIdentifier
        self.workingDirectory = workingDirectory
    }

    /// 事件收件箱是同一用户下任何进程都能写的文件，字段长度必须在这里收口；
    /// 文本先脱敏再截断，避免只截掉 token 的一半。
    static let maxCorrelationLength = 256
    static let maxTitleLength = 240
    static let maxDetailLength = 1_000
    static let maxPayloadEntries = 16

    private static func clean(_ text: String, limit: Int) -> String {
        String(
            SecretRedactor.redact(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .prefix(limit)
        )
    }

    /// 解码走同一条清洗路径：直接落盘的行绕不过这些上限。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            source: try container.decode(ExternalEventSource.self, forKey: .source),
            kind: try container.decode(ExternalEventKind.self, forKey: .kind),
            correlationID: try container.decode(String.self, forKey: .correlationID),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            detail: try container.decodeIfPresent(String.self, forKey: .detail) ?? "",
            payload: try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:],
            occurredAt: try container.decode(Date.self, forKey: .occurredAt),
            processIdentifier: try container.decodeIfPresent(Int32.self, forKey: .processIdentifier),
            workingDirectory: try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        )
    }

    /// 时间戳也是外部输入：写成 2999 年的「完成」会永远压住同一 correlation 之后
    /// 的真实事件，所以未来最多只认 now+5min。过去不夹——重启时整个收件箱会按原始
    /// 时间重放，旧事件必须保持先后顺序；而一个日期很旧的「完成」本来就压不住任何
    /// 比它新的事件。
    func clampingOccurredAt(to now: Date) -> ExternalEvent {
        let latest = now.addingTimeInterval(5 * 60)
        guard occurredAt > latest else { return self }
        return ExternalEvent(
            id: id,
            source: source,
            kind: kind,
            correlationID: correlationID,
            title: title,
            detail: detail,
            payload: payload,
            occurredAt: latest,
            processIdentifier: processIdentifier,
            workingDirectory: workingDirectory
        )
    }

    var isValid: Bool {
        !correlationID.isEmpty && (!title.isEmpty || !detail.isEmpty || kind.isTerminal)
    }

    var evidence: String {
        let label = title.isEmpty ? source.title : title
        let state = kind.title
        if detail.isEmpty {
            return "\(label)：\(state)"
        }
        return "\(label)：\(state)。\(detail)"
    }
}
