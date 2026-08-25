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
    /// 用户标签（不带 #，去重保序）；旧数据没有这个字段，解码时默认为空。
    var tags: [String]
    /// 截图 OCR 出的文字（本机 Vision），用于全文检索；其他类型恒为空。
    var extractedText: String
    /// 上次尝试提取的时间；非 nil 且文字为空表示试过但没识别出内容，
    /// 维护循环不再重试。
    var textExtractedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case body
        case title
        case sourceURL
        case assetURL
        case mimeType
        case duration
        case sourceApplication
        case sourceWindowTitle
        case capturedAt
        case status
        case attachedEpisodeID
        case tags
        case extractedText
        case textExtractedAt
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(CaptureKind.self, forKey: .kind),
            body: try container.decode(String.self, forKey: .body),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
            assetURL: try container.decodeIfPresent(URL.self, forKey: .assetURL),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration),
            sourceApplication: try container.decodeIfPresent(String.self, forKey: .sourceApplication),
            sourceWindowTitle: try container.decodeIfPresent(String.self, forKey: .sourceWindowTitle),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            status: try container.decode(CaptureStatus.self, forKey: .status),
            attachedEpisodeID: try container.decodeIfPresent(UUID.self, forKey: .attachedEpisodeID),
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            extractedText: try container.decodeIfPresent(String.self, forKey: .extractedText) ?? "",
            textExtractedAt: try container.decodeIfPresent(Date.self, forKey: .textExtractedAt)
        )
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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case note
        case createdAt
        case updatedAt
        case environmentProfileID
        case sceneFilterMode
    }

    init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        environmentProfileID: UUID? = nil,
        sceneFilterMode: SceneFilterMode? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.environmentProfileID = environmentProfileID
        self.sceneFilterMode = sceneFilterMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            note: try container.decodeIfPresent(String.self, forKey: .note) ?? "",
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            environmentProfileID: try container.decodeIfPresent(UUID.self, forKey: .environmentProfileID),
            sceneFilterMode: try container.decodeIfPresent(SceneFilterMode.self, forKey: .sceneFilterMode)
        )
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
    /// 读不到命令的位置为空字符串。旧数据没有这个字段。
    var terminalCommands: [String]
    /// 采集瞬间的剪贴板文字（截断保存）。开关关闭或内容标记为机密时为空。
    var clipboardText: String
    var note: String
    var capturedAt: Date

    private enum CodingKeys: String, CodingKey {
        case applications
        case applicationBundleIdentifiers
        case windows
        case windowFacts
        case files
        case links
        case terminalWorkingDirectories
        case terminalCommands
        case clipboardText
        case note
        case capturedAt
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            applications: try container.decodeIfPresent([String].self, forKey: .applications) ?? [],
            applicationBundleIdentifiers: try container.decodeIfPresent(
                [String].self,
                forKey: .applicationBundleIdentifiers
            ) ?? [],
            windows: try container.decodeIfPresent([String].self, forKey: .windows) ?? [],
            windowFacts: try container.decodeIfPresent(
                [ContextWindowFact].self,
                forKey: .windowFacts
            ) ?? [],
            files: try container.decodeIfPresent([URL].self, forKey: .files) ?? [],
            links: try container.decodeIfPresent([URL].self, forKey: .links) ?? [],
            terminalWorkingDirectories: try container.decodeIfPresent(
                [URL].self,
                forKey: .terminalWorkingDirectories
            ) ?? [],
            terminalCommands: try container.decodeIfPresent(
                [String].self,
                forKey: .terminalCommands
            ) ?? [],
            clipboardText: try container.decodeIfPresent(String.self, forKey: .clipboardText) ?? "",
            note: try container.decodeIfPresent(String.self, forKey: .note) ?? "",
            capturedAt: try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        )
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

enum AttentionEpisodeState: String, Codable, Equatable {
    case active
    case paused
    case waiting
    case returning
    case ended
}

/// 结束原因只有两种：完成和放弃。切换目标不会结束 episode——`startEpisode`
/// 把上一个暂停掉，历史里没有「switched」这种结束。
enum AttentionEpisodeEndReason: String, Codable, Equatable {
    case completed
    case abandoned
}

struct AttentionEpisode: Codable, Equatable, Identifiable {
    let id: UUID
    let targetID: UUID
    let startedAt: Date
    var updatedAt: Date
    var state: AttentionEpisodeState
    var endedAt: Date?
    var endedReason: AttentionEpisodeEndReason?
    var isBackground: Bool
    var context: ContextCapsule
    var returnCue: String
    var waitingIDs: [UUID]

    private enum CodingKeys: String, CodingKey {
        case id
        case targetID
        case startedAt
        case updatedAt
        case state
        case endedAt
        case endedReason
        case isBackground
        case context
        case returnCue
        case waitingIDs
    }

    init(
        id: UUID = UUID(),
        targetID: UUID,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        state: AttentionEpisodeState = .active,
        endedAt: Date? = nil,
        endedReason: AttentionEpisodeEndReason? = nil,
        isBackground: Bool = false,
        context: ContextCapsule = ContextCapsule(),
        returnCue: String = "",
        waitingIDs: [UUID] = []
    ) {
        self.id = id
        self.targetID = targetID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.state = state
        self.endedAt = endedAt
        self.endedReason = endedReason
        self.isBackground = isBackground
        self.context = context
        self.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.waitingIDs = waitingIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            targetID: try container.decode(UUID.self, forKey: .targetID),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            state: try container.decode(AttentionEpisodeState.self, forKey: .state),
            endedAt: try container.decodeIfPresent(Date.self, forKey: .endedAt),
            endedReason: try container.decodeIfPresent(
                AttentionEpisodeEndReason.self,
                forKey: .endedReason
            ),
            isBackground: try container.decodeIfPresent(Bool.self, forKey: .isBackground) ?? false,
            context: try container.decodeIfPresent(ContextCapsule.self, forKey: .context)
                ?? ContextCapsule(),
            returnCue: try container.decodeIfPresent(String.self, forKey: .returnCue) ?? "",
            waitingIDs: try container.decodeIfPresent([UUID].self, forKey: .waitingIDs) ?? []
        )
    }
}

enum WaitingKind: String, Codable, CaseIterable, Identifiable {
    case build
    case download
    case export
    case reply
    case agent
    case command
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .build: tr("build")
        case .download: tr("download")
        case .export: tr("export")
        case .reply: tr("reply")
        case .agent: tr("agent_session")
        case .command: tr("command")
        case .manual: tr("manual_wait")
        }
    }
}

enum WaitingStatus: String, Codable, Equatable {
    case waiting
    case ready
    case resolved
    case cancelled
}

enum WaitingRestorePolicy: String, Codable, CaseIterable {
    case manual
    case notify
    case nextTransition

    var title: String {
        switch self {
        case .manual: tr("return_manually")
        case .notify: tr("notify_when_the_result_arrives")
        case .nextTransition: tr("remind_me_at_the_next_transition")
        }
    }
}

struct WaitingItem: Codable, Equatable, Identifiable {
    let id: UUID
    let episodeID: UUID
    let kind: WaitingKind
    var description: String
    var completionCondition: String
    let startedAt: Date
    var completedAt: Date?
    var status: WaitingStatus
    var evidence: String
    var notificationSent: Bool
    var restorePolicy: WaitingRestorePolicy
    var monitor: WaitingMonitorConfiguration?
    var timeoutAt: Date?
    var originalContext: ContextCapsule

    private enum CodingKeys: String, CodingKey {
        case id
        case episodeID
        case kind
        case description
        case completionCondition
        case startedAt
        case completedAt
        case status
        case evidence
        case notificationSent
        case restorePolicy
        case monitor
        case timeoutAt
        case originalContext
    }

    init(
        id: UUID = UUID(),
        episodeID: UUID,
        kind: WaitingKind,
        description: String,
        completionCondition: String = "",
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        status: WaitingStatus = .waiting,
        evidence: String = "",
        notificationSent: Bool = false,
        restorePolicy: WaitingRestorePolicy = .manual,
        monitor: WaitingMonitorConfiguration? = nil,
        timeoutAt: Date? = nil,
        originalContext: ContextCapsule = ContextCapsule()
    ) {
        self.id = id
        self.episodeID = episodeID
        self.kind = kind
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.completionCondition = completionCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notificationSent = notificationSent
        self.restorePolicy = restorePolicy
        self.monitor = monitor
        self.timeoutAt = timeoutAt
        self.originalContext = originalContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            episodeID: try container.decode(UUID.self, forKey: .episodeID),
            kind: try container.decode(WaitingKind.self, forKey: .kind),
            description: try container.decode(String.self, forKey: .description),
            completionCondition: try container.decodeIfPresent(
                String.self,
                forKey: .completionCondition
            ) ?? "",
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            completedAt: try container.decodeIfPresent(Date.self, forKey: .completedAt),
            status: try container.decode(WaitingStatus.self, forKey: .status),
            evidence: try container.decodeIfPresent(String.self, forKey: .evidence) ?? "",
            notificationSent: try container.decodeIfPresent(Bool.self, forKey: .notificationSent) ?? false,
            restorePolicy: try container.decodeIfPresent(
                WaitingRestorePolicy.self,
                forKey: .restorePolicy
            ) ?? .manual,
            monitor: try container.decodeIfPresent(
                WaitingMonitorConfiguration.self,
                forKey: .monitor
            ),
            timeoutAt: try container.decodeIfPresent(Date.self, forKey: .timeoutAt),
            originalContext: try container.decodeIfPresent(
                ContextCapsule.self,
                forKey: .originalContext
            ) ?? ContextCapsule()
        )
    }

    var isValid: Bool {
        !description.isEmpty
    }
}

enum WaitingMonitorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case command
    case process
    case file
    case date
    case event

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: tr("confirm_manually")
        case .command: tr("command_finished")
        case .process: tr("background_task_finished")
        case .file: tr("file_ready")
        case .date: tr("at_a_set_time")
        case .event: tr("another_tool_reported_done")
        }
    }
}

struct WaitingMonitorConfiguration: Codable, Equatable, Sendable {
    var kind: WaitingMonitorKind
    var command: String?
    var arguments: [String]
    var workingDirectory: URL?
    var processIdentifier: Int32?
    var fileURL: URL?
    var date: Date?
    var eventInboxURL: URL?
    var eventCorrelationID: String?
    var eventSources: [ExternalEventSource]
    var eventKinds: [ExternalEventKind]
    var eventAfter: Date?
    /// 自动等待（Agent/终端事件自动归集）：由 AutoWaitRouter 全权驱动，
    /// WaitingCoordinator 不为它启动轮询检测器。
    var eventAutoManaged: Bool
    var fileBaselineModificationDate: Date?
    var fileBaselineSize: Int64?
    var fileRequiresChange: Bool
    var fileStableDuration: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
        case arguments
        case workingDirectory
        case processIdentifier
        case fileURL
        case date
        case eventInboxURL
        case eventCorrelationID
        case eventSources
        case eventKinds
        case eventAfter
        case eventAutoManaged
        case fileBaselineModificationDate
        case fileBaselineSize
        case fileRequiresChange
        case fileStableDuration
    }

    init(
        kind: WaitingMonitorKind,
        command: String? = nil,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        processIdentifier: Int32? = nil,
        fileURL: URL? = nil,
        date: Date? = nil,
        eventInboxURL: URL? = nil,
        eventCorrelationID: String? = nil,
        eventSources: [ExternalEventSource] = [],
        eventKinds: [ExternalEventKind] = [.completed, .failed, .cancelled],
        eventAfter: Date? = nil,
        eventAutoManaged: Bool = false,
        fileBaselineModificationDate: Date? = nil,
        fileBaselineSize: Int64? = nil,
        fileRequiresChange: Bool = false,
        fileStableDuration: TimeInterval = 0
    ) {
        self.kind = kind
        self.command = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.processIdentifier = processIdentifier
        self.fileURL = fileURL
        self.date = date
        self.eventInboxURL = eventInboxURL
        self.eventCorrelationID = eventCorrelationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.eventSources = eventSources
        self.eventKinds = eventKinds
        self.eventAfter = eventAfter
        self.eventAutoManaged = eventAutoManaged
        self.fileBaselineModificationDate = fileBaselineModificationDate
        self.fileBaselineSize = fileBaselineSize
        self.fileRequiresChange = fileRequiresChange
        self.fileStableDuration = max(fileStableDuration, 0)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(WaitingMonitorKind.self, forKey: .kind),
            command: try container.decodeIfPresent(String.self, forKey: .command),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
            workingDirectory: try container.decodeIfPresent(URL.self, forKey: .workingDirectory),
            processIdentifier: try container.decodeIfPresent(Int32.self, forKey: .processIdentifier),
            fileURL: try container.decodeIfPresent(URL.self, forKey: .fileURL),
            date: try container.decodeIfPresent(Date.self, forKey: .date),
            eventInboxURL: try container.decodeIfPresent(URL.self, forKey: .eventInboxURL),
            eventCorrelationID: try container.decodeIfPresent(String.self, forKey: .eventCorrelationID),
            eventSources: try container.decodeIfPresent([ExternalEventSource].self, forKey: .eventSources) ?? [],
            eventKinds: try container.decodeIfPresent([ExternalEventKind].self, forKey: .eventKinds)
                ?? [.completed, .failed, .cancelled],
            eventAfter: try container.decodeIfPresent(Date.self, forKey: .eventAfter),
            eventAutoManaged: try container.decodeIfPresent(
                Bool.self,
                forKey: .eventAutoManaged
            ) ?? false,
            fileBaselineModificationDate: try container.decodeIfPresent(
                Date.self,
                forKey: .fileBaselineModificationDate
            ),
            fileBaselineSize: try container.decodeIfPresent(Int64.self, forKey: .fileBaselineSize),
            fileRequiresChange: try container.decodeIfPresent(
                Bool.self,
                forKey: .fileRequiresChange
            ) ?? false,
            fileStableDuration: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .fileStableDuration
            ) ?? 0
        )
    }
}
