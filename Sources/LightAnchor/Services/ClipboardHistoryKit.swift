import AppKit
import Foundation

// MARK: - 剪贴板历史：存储 + 采样 + 跟随
//
// 一段工作（episode）一个 clipboard/<episodeID>.json，随写随存。系统没有
// 剪贴板变化通知，靠轮询 changeCount（只读一个整数，内容变了才读文字）。
// 跟随谁由 workspace 决定：占着「现在」且在专注的那段工作在跟随，放下 /
// 等待 / 结束就停；接着做时重新跟随，把盘上已有的条目接着往后写。

/// 一次剪贴板观察。`text` 已按现场隐私规则处理过：非文字、标记机密、
/// 前台敏感或被排除的应用都给空串。
struct ClipboardSample: Equatable, Sendable {
    var changeCount: Int
    var text: String
    var sourceApplication: String
}

/// 剪贴板历史文件仓库。目录可注入（测试用临时目录）。
struct ClipboardHistoryStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? LightAnchorStorage.clipboardHistoryURL()
    }

    private func fileURL(for episodeID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(episodeID.uuidString).json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
        return decoder
    }

    func save(_ entries: [ClipboardHistoryEntry], for episodeID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(entries)
        try data.write(to: fileURL(for: episodeID), options: .atomic)
    }

    func load(for episodeID: UUID) -> [ClipboardHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL(for: episodeID)) else { return [] }
        return (try? Self.makeDecoder().decode([ClipboardHistoryEntry].self, from: data)) ?? []
    }

    func remove(for episodeID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: episodeID))
    }
}

/// 系统剪贴板的默认读取方式：与现场那一次读取同一条隐私规则，另加现场来源
/// 里被排除的应用（持续跟随比一次读取更该尊重这份名单）。
enum MacClipboardSampler {
    @MainActor
    static func sample(
        characterLimit: Int,
        sourcePreferences: SceneCapturePreferences
    ) -> ClipboardSample {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let changeCount = NSPasteboard.general.changeCount
        let bundleIdentifier = frontmost?.bundleIdentifier ?? ""
        guard sourcePreferences.allowsApplication(bundleIdentifier) else {
            return ClipboardSample(changeCount: changeCount, text: "", sourceApplication: "")
        }
        return ClipboardSample(
            changeCount: changeCount,
            text: MacContextRecorder.clipboardText(
                limit: characterLimit,
                frontmostBundleIdentifier: frontmost?.bundleIdentifier
            ),
            sourceApplication: frontmost?.localizedName ?? ""
        )
    }
}

/// 剪贴板历史协调器：同一时刻至多跟随一段工作。轮询、去重、上限、落盘都在
/// 这里；跟随谁、什么时候停由 workspace 按 episode 状态驱动。
@MainActor
final class ClipboardHistoryCoordinator {
    private let store: ClipboardHistoryStore
    /// 读一次剪贴板。可注入（测试）。
    private let sample: () -> ClipboardSample
    /// 每次采样前问一下：开关关了或自动记录暂停时不记，但跟随不断——
    /// 开关一开下一次复制就开始记，不用等换一件事。
    private let isEnabled: () -> Bool
    /// 记下一条之后通知（界面据此刷新正在跟随那段事的复写条）。
    private let onChange: () -> Void

    private(set) var followingEpisodeID: UUID?
    private var entries: [ClipboardHistoryEntry] = []
    /// 读过的历史文件缓存：现场卡在列表里反复求值，不能每次都去读盘。
    private var loaded: [UUID: [ClipboardHistoryEntry]] = [:]
    /// 上次看到的 changeCount；nil 表示刚开始跟随，下一次采样不比较直接看内容。
    private var lastChangeCount: Int?
    private var pollingTask: Task<Void, Never>?

    /// 轮询间隔：只读 changeCount 一个整数，1 秒一次感知不到开销。
    static let pollingInterval: TimeInterval = 1

    init(
        store: ClipboardHistoryStore = ClipboardHistoryStore(),
        sample: @escaping () -> ClipboardSample,
        isEnabled: @escaping () -> Bool,
        onChange: @escaping () -> Void = {}
    ) {
        self.store = store
        self.sample = sample
        self.isEnabled = isEnabled
        self.onChange = onChange
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: 跟随

    /// 开始（或继续）跟随一段工作。已在跟随别的先停掉；盘上已有的条目接着写。
    /// 跟随的第一拍就看一眼剪贴板：手上正拿着的内容也算这段事的一部分。
    func follow(_ episodeID: UUID, now: Date = Date()) {
        if followingEpisodeID == episodeID { return }
        if followingEpisodeID != nil { stopFollowing() }
        followingEpisodeID = episodeID
        entries = store.load(for: episodeID)
        loaded[episodeID] = nil
        lastChangeCount = nil
        startPolling()
        sampleNow(at: now)
    }

    /// 停止跟随（放下 / 等待 / 结束都走这里）。条目已在盘上，这里只收拾内存。
    func stopFollowing() {
        guard let episodeID = followingEpisodeID else { return }
        stopPolling()
        flush(episodeID: episodeID)
        loaded[episodeID] = entries
        followingEpisodeID = nil
        entries = []
        lastChangeCount = nil
    }

    /// 删数据时的善后：不落盘、直接丢。文件由删除清单一并移除。
    func discardAll() {
        stopPolling()
        followingEpisodeID = nil
        entries = []
        loaded = [:]
        lastChangeCount = nil
    }

    /// 某段工作的历史（在跟随的取内存，其余读盘并缓存），最早的在前。
    func entries(for episodeID: UUID) -> [ClipboardHistoryEntry] {
        if followingEpisodeID == episodeID { return entries }
        if let cached = loaded[episodeID] { return cached }
        let fromDisk = store.load(for: episodeID)
        loaded[episodeID] = fromDisk
        return fromDisk
    }

    // MARK: 采样

    /// 立刻看一次剪贴板。内容没变（changeCount 相同）不读文字；与上一条相同
    /// 的文字不重复记；空文字（非文字 / 机密 / 敏感前台）不记。
    func sampleNow(at now: Date = Date()) {
        guard let episodeID = followingEpisodeID, isEnabled() else { return }
        let observed = sample()
        guard observed.changeCount != lastChangeCount else { return }
        lastChangeCount = observed.changeCount
        guard !observed.text.isEmpty, observed.text != entries.last?.text else { return }
        entries.append(ClipboardHistoryEntry(
            at: now,
            text: observed.text,
            sourceApplication: observed.sourceApplication
        ))
        if entries.count > ClipboardHistoryEntry.entryLimit {
            entries.removeFirst(entries.count - ClipboardHistoryEntry.entryLimit)
        }
        flush(episodeID: episodeID)
        onChange()
    }

    // MARK: 内部

    private func flush(episodeID: UUID) {
        do {
            try store.save(entries, for: episodeID)
        } catch {
            LocalDiagnostics.shared.record(
                operation: "clipboard.history.save",
                message: error.localizedDescription
            )
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollingInterval))
                guard !Task.isCancelled else { return }
                self?.sampleNow()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
