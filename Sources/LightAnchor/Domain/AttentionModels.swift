import Foundation

enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case text
    case voice
    case screenshot
    case link
    case fileReference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: tr("text_2")
        case .voice: tr("voice")
        case .screenshot: tr("screenshot")
        case .link: tr("link")
        case .fileReference: tr("file_reference")
        }
    }

    var icon: String {
        switch self {
        case .text: "text.alignleft"
        case .voice: "waveform"
        case .screenshot: "camera.viewfinder"
        case .link: "link"
        case .fileReference: "doc"
        }
    }
}

enum CaptureStatus: String, Codable, Equatable {
    case inbox
    case attached
    case reference
    case archived
}

struct CaptureItem: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: CaptureKind
    let body: String
    let title: String?
    let sourceURL: URL?
    let assetURL: URL?
    let mimeType: String?
    let duration: TimeInterval?
    let sourceApplication: String?
    let sourceWindowTitle: String?
    let capturedAt: Date
    var status: CaptureStatus
    var attachedEpisodeID: UUID?
    /// 用户标签（不带 #，去重保序）。
    var tags: [String]
    /// 截图 OCR 出的文字（本机 Vision），用于全文检索；其他类型恒为空。
    var extractedText: String
    /// 上次尝试提取的时间；非 nil 且文字为空表示试过但没识别出内容，
    /// 维护循环不再重试。
    var textExtractedAt: Date?

    /// 规范化标签：去掉首部 #、修剪空白、丢空值、去重保序。
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }

    init(
        id: UUID = UUID(),
        kind: CaptureKind = .text,
        body: String,
        title: String? = nil,
        sourceURL: URL? = nil,
        assetURL: URL? = nil,
        mimeType: String? = nil,
        duration: TimeInterval? = nil,
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        capturedAt: Date = Date(),
        status: CaptureStatus = .inbox,
        attachedEpisodeID: UUID? = nil,
        tags: [String] = [],
        extractedText: String = "",
        textExtractedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceURL = sourceURL
        self.assetURL = assetURL
        self.mimeType = mimeType
        self.duration = duration
        self.sourceApplication = sourceApplication
        self.sourceWindowTitle = sourceWindowTitle
        self.capturedAt = capturedAt
        self.status = status
        self.attachedEpisodeID = attachedEpisodeID
        self.tags = Self.normalizedTags(tags)
        self.extractedText = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.textExtractedAt = textExtractedAt
    }

    var isValid: Bool {
        !body.isEmpty || sourceURL != nil || assetURL != nil
    }
}

struct EnvironmentAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case openApplication
        case openURL
        case openFile
        case runShortcut
        case runCommand
        case hideApplication

        var title: String {
            switch self {
            case .openApplication: tr("open_app")
            case .openURL: tr("open_link")
            case .openFile: tr("open_file")
            case .runShortcut: tr("run_shortcut")
            case .runCommand: tr("run_command")
            case .hideApplication: tr("hide_app")
            }
        }
    }

    let id: UUID
    let kind: Kind
    let value: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        value: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
    }
}

struct EnvironmentProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var actions: [EnvironmentAction]
    var allowedApplicationBundleIdentifiers: Set<String>

    init(
        id: UUID = UUID(),
        name: String,
        actions: [EnvironmentAction] = [],
        allowedApplicationBundleIdentifiers: Set<String> = []
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actions = actions
        self.allowedApplicationBundleIdentifiers = allowedApplicationBundleIdentifiers
    }
}

struct AttentionTarget: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var note: String
    let createdAt: Date
    var updatedAt: Date
    var environmentProfileID: UUID?
    /// 该目标的现场筛选偏好（按目标记忆）。nil 表示跟随全局默认。
    var sceneFilterMode: SceneFilterMode?
    /// 属于哪件大任务：非空表示这是它的一个**步骤**（只有一层，步骤不能再拆步骤）。
    /// 步骤是完整的目标——自己的段、自己的现场、自己的计时，切换走换一件事仪式。
    var parentTargetID: UUID?
    /// 连带收起的墓碑：大任务完成时没做完的步骤盖上这个时刻，
    /// 从此不再出现在任何清单里（事件日志保留全部历史）。
    var retiredAt: Date?
    /// 什么时候必须做完。**可以留空**——多数事没有期限，硬逼人填只会得到
    /// 一个编出来的日期。填了的才会到期来找你（见 DueDate）。
    var dueAt: Date?
    /// 上次为这个期限提醒过的时刻：同一个期限只催一次，不隔天再冒出来。
    var nudgedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        environmentProfileID: UUID? = nil,
        sceneFilterMode: SceneFilterMode? = nil,
        parentTargetID: UUID? = nil,
        retiredAt: Date? = nil,
        dueAt: Date? = nil,
        nudgedAt: Date? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.environmentProfileID = environmentProfileID
        self.sceneFilterMode = sceneFilterMode
        self.parentTargetID = parentTargetID
        self.retiredAt = retiredAt
        self.dueAt = dueAt
        self.nudgedAt = nudgedAt
    }

    var isValid: Bool {
        !name.isEmpty
    }
}

struct ContextElementFact: Codable, Equatable, Sendable {
    let role: String
    let subrole: String
    let title: String
    let identifier: String
    let description: String

    init(
        role: String = "",
        subrole: String = "",
        title: String = "",
        identifier: String = "",
        description: String = ""
    ) {
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subrole = subrole.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasStableIdentity: Bool {
        !identifier.isEmpty || (!role.isEmpty && !title.isEmpty)
    }
}

struct ContextWindowFact: Codable, Equatable, Identifiable, Sendable {
    let stableIdentifier: String
    let applicationBundleIdentifier: String
    let title: String
    let role: String
    let subrole: String
    let documentURL: URL?
    let isMain: Bool
    let isFocused: Bool
    let focusedElement: ContextElementFact?

    var id: String { stableIdentifier }

    init(
        stableIdentifier: String? = nil,
        applicationBundleIdentifier: String,
        title: String = "",
        role: String = "",
        subrole: String = "",
        documentURL: URL? = nil,
        isMain: Bool = false,
        isFocused: Bool = false,
        focusedElement: ContextElementFact? = nil
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubrole = subrole.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.title = normalizedTitle
        self.role = normalizedRole
        self.subrole = normalizedSubrole
        self.documentURL = documentURL
        self.isMain = isMain
        self.isFocused = isFocused
        self.focusedElement = focusedElement
        if let normalizedIdentifier = stableIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !normalizedIdentifier.isEmpty {
            self.stableIdentifier = normalizedIdentifier
        } else {
            self.stableIdentifier = Self.makeStableIdentifier(
                applicationBundleIdentifier: applicationBundleIdentifier,
                title: normalizedTitle,
                documentURL: documentURL,
                role: normalizedRole,
                subrole: normalizedSubrole
            )
        }
    }

    private static func makeStableIdentifier(
        applicationBundleIdentifier: String,
        title: String,
        documentURL: URL?,
        role: String,
        subrole: String
    ) -> String {
        [
            applicationBundleIdentifier,
            documentURL?.absoluteString ?? "",
            title,
            role,
            subrole
        ].joined(separator: "|")
    }
}

struct ContextCapsule: Codable, Equatable {
    var applications: [String]
    var applicationBundleIdentifiers: [String]
    var windows: [String]
    var windowFacts: [ContextWindowFact]
    var files: [URL]
    var links: [URL]
    var terminalWorkingDirectories: [URL]
    /// 与 terminalWorkingDirectories 一一对应的「当时正在运行的命令」；
    /// 读不到命令的位置为空字符串。
    var terminalCommands: [String]
    /// 采集瞬间的剪贴板文字（截断保存）。开关关闭或内容标记为机密时为空。
    var clipboardText: String
    var note: String
    var capturedAt: Date

    init(
        applications: [String] = [],
        applicationBundleIdentifiers: [String] = [],
        windows: [String] = [],
        windowFacts: [ContextWindowFact] = [],
        files: [URL] = [],
        links: [URL] = [],
        terminalWorkingDirectories: [URL] = [],
        terminalCommands: [String] = [],
        clipboardText: String = "",
        note: String = "",
        capturedAt: Date = Date()
    ) {
        self.applications = applications
        self.applicationBundleIdentifiers = applicationBundleIdentifiers
        self.windows = windows
        self.windowFacts = windowFacts
        self.files = files
        self.links = links
        self.terminalWorkingDirectories = terminalWorkingDirectories
        self.terminalCommands = terminalCommands
        self.clipboardText = clipboardText
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.capturedAt = capturedAt
    }

    var hasSceneContent: Bool {
        !applications.isEmpty
            || !applicationBundleIdentifiers.isEmpty
            || !windows.isEmpty
            || !windowFacts.isEmpty
            || !files.isEmpty
            || !links.isEmpty
            || !terminalWorkingDirectories.isEmpty
            || !terminalCommands.allSatisfy(\.isEmpty)
            || !clipboardText.isEmpty
    }

    /// 清除历史现场时保留用户主动写下的备注与原始时间，但移除采集事实。
    var scrubbedSceneContent: Self {
        Self(note: note, capturedAt: capturedAt)
    }
}

/// 没有「等待中」这一档：**等结果的事就是被放下了**。原来它和「放下」并列，
/// 于是有了一个会自己漂移的状态——你一旦真的去干别的，切换会把它改成 paused，
/// 而那条没到的结果还挂着。归属现在只由「身上有没有一条还没等到的结果」决定
/// （见 LaterListProjection），状态只管这段工作本身。
enum AttentionEpisodeState: String, Codable, Equatable {
    case active
    case paused
    case returning
    case ended
}

/// 结束原因只有两种：完成和放弃。切换目标不会结束 episode——`startEpisode`
/// 把上一个暂停掉，历史里没有「switched」这种结束。
enum AttentionEpisodeEndReason: String, Codable, Equatable {
    case completed
    case abandoned
}

/// 一段工作的总结（「上次做到哪」）。
///
/// 现场告诉你**东西在哪**，总结告诉你**当时在干什么、卡在哪**——隔几天回来，
/// 前者不够：五个文件名说不出你上次为什么停下。所以它和现场是同一份东西的
/// 两面，都挂在这一段上，绝不是两个并列的页签。
///
/// 正文是 Markdown-lite：`## 小标题` + 段落，与「整理记录」同一套写法。
/// 全文只许复述 `factCount` 条本机事实；署名如实写明是哪套引擎整理的，
/// 启发式降级也照签自己的名，用户看得出这份没过模型。
struct EpisodeSummary: Codable, Equatable, Sendable {
    var text: String
    /// 署名：哪套引擎整理的（模型名 / 「端侧模型」/「启发式（离线）」）。
    var engineName: String
    /// 出自多少条本机事实。
    var factCount: Int
    var generatedAt: Date
    /// 用户自己改过：改过的不再被自动重写覆盖（要重写得他自己点）。
    var isEdited: Bool

    init(
        text: String,
        engineName: String,
        factCount: Int,
        generatedAt: Date = Date(),
        isEdited: Bool = false
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.engineName = engineName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.factCount = max(0, factCount)
        self.generatedAt = generatedAt
        self.isEdited = isEdited
    }

    var isEmpty: Bool { text.isEmpty }

    /// 「N 字」：中日韩按字数报，不按词数——这一行是给人估阅读量的。
    var characterCount: Int {
        text.replacingOccurrences(of: "#", with: "")
            .filter { !$0.isWhitespace }
            .count
    }
}

struct AttentionEpisode: Codable, Equatable, Identifiable {
    let id: UUID
    let targetID: UUID
    let startedAt: Date
    var updatedAt: Date
    var state: AttentionEpisodeState
    var endedAt: Date?
    var endedReason: AttentionEpisodeEndReason?
    var context: ContextCapsule
    var returnCue: String
    var waitingIDs: [UUID]
    /// 这一段的总结。可选：没整理过就是 nil（旧日志里也没有这个字段，
    /// Optional 的合成解码遇到缺 key 会给 nil，不需要迁移）。
    var summary: EpisodeSummary?

    init(
        id: UUID = UUID(),
        targetID: UUID,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        state: AttentionEpisodeState = .active,
        endedAt: Date? = nil,
        endedReason: AttentionEpisodeEndReason? = nil,
        context: ContextCapsule = ContextCapsule(),
        returnCue: String = "",
        waitingIDs: [UUID] = [],
        summary: EpisodeSummary? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.state = state
        self.endedAt = endedAt
        self.endedReason = endedReason
        self.context = context
        self.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.waitingIDs = waitingIDs
        self.summary = summary.flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum WaitingStatus: String, Codable, Equatable {
    case waiting
    case ready
    case resolved
    case cancelled
}

/// 一条等待：一个悬在别人手里的结果。
///
/// 它身上押的是**截止日期**（`dueAt`），不是「几点提醒我」。「三天」是你对别人
/// 耐心的估计，是编的；「周五」是你自己日程上的硬点。而且日期能倒着算——
/// 「周五要用，催一趟要一天，那今天就得动」——时长模型里没有终点，倒不回来。
///
/// 软件永远判断不了「结果到了」（那要它看得见你的邮箱），但能百分百判断
/// 「快到期了」。所以 `.ready` 只能由人确认，到期只负责催你。
struct WaitingItem: Codable, Equatable, Identifiable {
    let id: UUID
    let episodeID: UUID
    var description: String
    var completionCondition: String
    let startedAt: Date
    var completedAt: Date?
    var status: WaitingStatus
    var evidence: String
    /// 什么时候必须拿到。可以留空——没期限的等待只是一笔账，永不打扰。
    var dueAt: Date?
    /// 上次为这个期限催过的时刻：催过就不再催，除非你改了期限。
    var nudgedAt: Date?
    var originalContext: ContextCapsule

    init(
        id: UUID = UUID(),
        episodeID: UUID,
        description: String,
        completionCondition: String = "",
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        status: WaitingStatus = .waiting,
        evidence: String = "",
        dueAt: Date? = nil,
        nudgedAt: Date? = nil,
        originalContext: ContextCapsule = ContextCapsule()
    ) {
        self.id = id
        self.episodeID = episodeID
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.completionCondition = completionCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dueAt = dueAt
        self.nudgedAt = nudgedAt
        self.originalContext = originalContext
    }

    var isValid: Bool {
        !description.isEmpty
    }
}
