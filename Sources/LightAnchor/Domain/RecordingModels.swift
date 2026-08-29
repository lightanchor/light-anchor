import Foundation

// MARK: - 过程记录（Recording）
//
// 记录不是人写的：软件对「做某件事的过程」自动留痕。跟随工作时，
// 开始就录、放下/等待暂停、恢复继续、结束或切走收尾；也可以脱离
// 工作流主动录一个过程。产物是按时间排列的事实条目（trace），
// 之后由智能引擎生成两种成稿：给人看的分享文档，或给 AI 执行的 SKILL.md。
//
// 存储分两层：会话元数据 + 成稿进事件日志（小、可回放、可备份）；
// trace 条目落 recordings/<id>.json 独立文件（事件日志是整文件原子重写，
// 长 trace 进日志会放大每一次提交）。

/// 成稿风格。决定 AI 整理的文体和导出的文件形态。
enum RecordingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 给人看的：背景、步骤、坑点，一篇可直接分享的复盘文档。
    case guide
    /// 给 AI 执行的：SKILL.md（YAML frontmatter + 面向 agent 的执行指令）。
    case skill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guide: tr("record_style_guide")
        case .skill: tr("record_style_skill")
        }
    }

    var explanation: String {
        switch self {
        case .guide: tr("record_style_guide_detail")
        case .skill: tr("record_style_skill_detail")
        }
    }

    /// 导出文件名：guide 用标题起名，skill 固定叫 SKILL.md（约定文件名）。
    func exportFileName(for title: String) -> String {
        switch self {
        case .guide:
            let slug = RecordingSession.slug(from: title)
            return slug.isEmpty ? "record.md" : "\(slug).md"
        case .skill:
            return "SKILL.md"
        }
    }
}

/// trace 条目的种类：都是软件观察到的事实，不是用户手写的内容。
enum RecordingEntryKind: String, Codable, CaseIterable, Sendable {
    /// 切到某个应用。
    case application
    /// 打开/切到某个文件。
    case file
    /// 打开/切到某个网页。
    case link
    /// 终端里出现的命令。
    case command
    /// 期间的捕获（想法/截图/链接）。
    case capture
    /// 等待的开始或结果。
    case waiting
    /// 工作段状态迁移（开始/放下/恢复/结束）。
    case episode
    /// 系统备注（如「条目已达上限」）。
    case note

    var title: String {
        switch self {
        case .application: tr("apps")
        case .file: tr("file")
        case .link: tr("web_page")
        case .command: tr("command")
        case .capture: tr("capture")
        case .waiting: tr("waiting")
        case .episode: tr("work_session")
        case .note: tr("recording_note")
        }
    }
}

/// 一条 trace 事实：时刻 + 动作。只存事实，不做判断。
struct RecordingEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let at: Date
    let kind: RecordingEntryKind
    /// 主体（应用名/文件名/网页标题/命令/捕获摘要）。
    let title: String
    /// 补充（窗口标题/目录/等待证据等），可为空。
    let detail: String

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        kind: RecordingEntryKind,
        title: String,
        detail: String = ""
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 喂给智能引擎的一行事实：时刻 + 类别 + 主体（+ 补充）。
    func factLine(calendar: Calendar = .current) -> String {
        let time = at.formatted(date: .omitted, time: .shortened)
        var line = "\(time) [\(kind.title)] \(title)"
        if !detail.isEmpty {
            line += "（\(detail)）"
        }
        return line
    }

    /// 相邻去重用：同一件事的重复观察不再追加。
    var dedupeKey: String {
        "\(kind.rawValue)|\(title)|\(detail)"
    }
}

enum RecordingSessionStatus: String, Codable, Equatable, Sendable {
    case recording
    case paused
    case finished
}

/// 一次录制的元数据（进事件日志）。trace 条目在 RecordingTraceStore 的独立文件里。
struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    /// 单份 trace 的条目上限：超限保头尾丢中间，由采样端执行。
    static let entryLimit = 800

    let id: UUID
    var title: String
    /// 跟随的工作段与目标；主动录制时可为空。
    var targetID: UUID?
    var episodeID: UUID?
    /// true = 跟随工作自动开始（episode 生命周期管它），false = 用户主动录制。
    var autoFollowed: Bool
    let startedAt: Date
    var endedAt: Date?
    var status: RecordingSessionStatus
    /// 收尾时的条目数（列表展示用；事实源是 trace 文件）。
    var entryCount: Int
    /// 最近一次生成成稿用的风格。
    var style: RecordingStyle
    /// 整理后的 Markdown 成稿（AI 生成后用户可继续改）。空 = 还没整理。
    var markdown: String
    /// 成稿出自哪个引擎（展示用）。
    var composedBy: String
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case targetID
        case episodeID
        case autoFollowed
        case startedAt
        case endedAt
        case status
        case entryCount
        case style
        case markdown
        case composedBy
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String,
        targetID: UUID? = nil,
        episodeID: UUID? = nil,
        autoFollowed: Bool = false,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: RecordingSessionStatus = .recording,
        entryCount: Int = 0,
        style: RecordingStyle = .guide,
        markdown: String = "",
        composedBy: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetID = targetID
        self.episodeID = episodeID
        self.autoFollowed = autoFollowed
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.entryCount = max(0, entryCount)
        self.style = style
        self.markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        self.composedBy = composedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            targetID: try container.decodeIfPresent(UUID.self, forKey: .targetID),
            episodeID: try container.decodeIfPresent(UUID.self, forKey: .episodeID),
            autoFollowed: try container.decodeIfPresent(Bool.self, forKey: .autoFollowed) ?? false,
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decodeIfPresent(Date.self, forKey: .endedAt),
            status: try container.decodeIfPresent(
                RecordingSessionStatus.self,
                forKey: .status
            ) ?? .finished,
            entryCount: try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0,
            style: try container.decodeIfPresent(RecordingStyle.self, forKey: .style) ?? .guide,
            markdown: try container.decodeIfPresent(String.self, forKey: .markdown) ?? "",
            composedBy: try container.decodeIfPresent(String.self, forKey: .composedBy) ?? "",
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }

    var isActive: Bool {
        status == .recording || status == .paused
    }

    /// 分享/导出的内容：成稿；没有成稿时给个明确的空说明而不是空文件。
    var shareableMarkdown: String {
        markdown.isEmpty ? "# \(title)\n\n\(tr("not_composed_yet_open_to_compose"))" : markdown
    }

    /// 标题转文件名 slug：保留中英文与数字，其余折叠成 "-"。
    static func slug(from title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }
}
