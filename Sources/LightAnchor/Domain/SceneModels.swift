import Foundation

// MARK: - 现场快照（Scene Snapshot）
//
// 现场快照是「一键重返」的数据基础：切换、等待或暂停时，把当前工作现场
// 记录成一组可可靠重开的条目（文件、网页、终端目录、应用），而不是
// 试图还原窗口排布。恢复动作全部走 `open` 原语，接近 100% 可靠。

/// 现场条目类别。恢复时每种类别对应一组可靠原语。
enum SceneItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case file
    case link
    case terminal
    case application

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: tr("file")
        case .link: tr("web_page")
        case .terminal: tr("terminal")
        case .application: tr("apps")
        }
    }

}

/// 单个现场条目。
struct SceneItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: SceneItemKind
    /// 展示名（文件名 / 网页标题 / 目录名 / 应用名）。
    var title: String
    /// 恢复用地址：file:// / https:// / 终端目录 file:// / 应用 bundleID。
    var address: String
    /// 来源应用名（如 VSCode、Safari、iTerm），用于设置用户预期。
    var sourceApplication: String
    /// 终端条目当时正在运行的命令（如 "swift test"），仅展示用。
    var detail: String
    /// 是否被判定为与当前目标相关。AI 筛选关闭时默认全部为 true。
    var isRelevant: Bool

    init(
        id: UUID = UUID(),
        kind: SceneItemKind,
        title: String,
        address: String,
        sourceApplication: String = "",
        detail: String = "",
        isRelevant: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceApplication = sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isRelevant = isRelevant
    }
}

/// 现场筛选方式。默认 AI 筛选（只存与目标相关），可切换为全部保存。
enum SceneFilterMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case aiFiltered
    case saveAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aiFiltered: tr("ai_filter")
        case .saveAll: tr("save_all")
        }
    }
}

/// 一份现场快照。
struct SceneSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// 关联的注意力目标（可选，等待场景可能跨目标）。
    var targetID: UUID?
    /// 产生这份现场的工作段。检查点现场可能没有工作段和目标。
    var episodeID: UUID?
    var items: [SceneItem]
    var filterMode: SceneFilterMode
    /// AI 生成或用户编辑的「回来先做」。
    var returnCue: String
    /// 采集瞬间的剪贴板文字（「保存剪贴板内容」开启时）。重返时可一键放回。
    var clipboardText: String
    /// 采集瞬间的桌面截图（「保存窗口截图」开启时），存在本机资产目录。
    var screenshotAssetURL: URL?
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        targetID: UUID? = nil,
        episodeID: UUID? = nil,
        items: [SceneItem] = [],
        filterMode: SceneFilterMode = .aiFiltered,
        returnCue: String = "",
        clipboardText: String = "",
        screenshotAssetURL: URL? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.targetID = targetID
        self.episodeID = episodeID
        self.items = items
        self.filterMode = filterMode
        self.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clipboardText = clipboardText
        self.screenshotAssetURL = screenshotAssetURL
        self.capturedAt = capturedAt
    }

    /// 参与恢复的条目（AI 筛选开启时只取相关项，全部保存时取全部）。
    var restorableItems: [SceneItem] {
        switch filterMode {
        case .aiFiltered: items.filter(\.isRelevant)
        case .saveAll: items
        }
    }

    /// 被 AI 收起的条目数（用于「已自动收起 N 个无关窗口」提示）。
    var tuckedAwayCount: Int {
        items.count - restorableItems.count
    }

    func items(of kind: SceneItemKind) -> [SceneItem] {
        restorableItems.filter { $0.kind == kind }
    }
}

extension ContextCapsule {
    /// 剔掉若干现场条目后的上下文——「换一件事」里被划掉的不带走。
    /// 条目地址的写法与 `SceneSnapshotBuilder.items(from:)` 一致：文件 / 网页 /
    /// 终端目录是 URL 的 absoluteString，应用是 bundleID。
    func removing(_ items: [SceneItem]) -> ContextCapsule {
        var result = self
        let files = Set(items.filter { $0.kind == .file }.map(\.address))
        result.files.removeAll { files.contains($0.absoluteString) }

        let links = Set(items.filter { $0.kind == .link }.map(\.address))
        result.links.removeAll { links.contains($0.absoluteString) }

        // 终端目录与当时的命令是并列数组，要一起删。
        let directories = Set(items.filter { $0.kind == .terminal }.map(\.address))
        var keptDirectories: [URL] = []
        var keptCommands: [String] = []
        for (index, directory) in terminalWorkingDirectories.enumerated()
        where !directories.contains(directory.absoluteString) {
            keptDirectories.append(directory)
            keptCommands.append(index < terminalCommands.count ? terminalCommands[index] : "")
        }
        result.terminalWorkingDirectories = keptDirectories
        result.terminalCommands = keptCommands

        let bundleIDs = Set(items.filter { $0.kind == .application }.map(\.address))
        let appNames = Set(items.filter { $0.kind == .application }.map(\.title))
        result.windowFacts.removeAll { bundleIDs.contains($0.applicationBundleIdentifier) }
        result.applicationBundleIdentifiers.removeAll { bundleIDs.contains($0) }
        result.applications.removeAll { appNames.contains($0) }
        return result
    }
}

// MARK: - 现场条目失效检查

/// 单个条目的失效状态。
enum SceneItemStaleness: Equatable, Sendable {
    case fresh
    case missing(reason: String)

    var isActionable: Bool {
        if case .fresh = self { return false }
        return true
    }
}
