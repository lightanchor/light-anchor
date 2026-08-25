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
    /// 相关性来源：ai（模型判断）/ manual（用户手动）/ all（全部保存）。
    /// heuristic 已停用（启发式不再猜相关性），仅为解码旧数据保留。
    var relevanceSource: SceneRelevanceSource

    init(
        id: UUID = UUID(),
        kind: SceneItemKind,
        title: String,
        address: String,
        sourceApplication: String = "",
        detail: String = "",
        isRelevant: Bool = true,
        relevanceSource: SceneRelevanceSource = .all
    ) {
        self.id = id
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceApplication = sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isRelevant = isRelevant
        self.relevanceSource = relevanceSource
    }
}

enum SceneRelevanceSource: String, Codable, Equatable, Sendable {
    case ai
    /// 已停用：新快照不再产生此值，仅为解码旧数据保留。
    case heuristic
    case manual
    case all
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
    /// 产生这份现场的工作段。旧数据没有时由目标和时间做兼容匹配。
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

    private enum CodingKeys: String, CodingKey {
        case id
        case targetID
        case episodeID
        case items
        case filterMode
        case returnCue
        case clipboardText
        case screenshotAssetURL
        case capturedAt
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            targetID: try container.decodeIfPresent(UUID.self, forKey: .targetID),
            episodeID: try container.decodeIfPresent(UUID.self, forKey: .episodeID),
            items: try container.decodeIfPresent([SceneItem].self, forKey: .items) ?? [],
            filterMode: try container.decodeIfPresent(SceneFilterMode.self, forKey: .filterMode)
                ?? .aiFiltered,
            returnCue: try container.decodeIfPresent(String.self, forKey: .returnCue) ?? "",
            clipboardText: try container.decodeIfPresent(String.self, forKey: .clipboardText) ?? "",
            screenshotAssetURL: try container.decodeIfPresent(
                URL.self,
                forKey: .screenshotAssetURL
            ),
            capturedAt: try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        )
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

// MARK: - 现场条目失效检查

/// 单个条目的失效状态。
enum SceneItemStaleness: Equatable, Sendable {
    case fresh
    case possiblyChanged(reason: String)
    case missing(reason: String)

    var isActionable: Bool {
        if case .fresh = self { return false }
        return true
    }
}
