import Foundation

enum LightAnchorStorage {
    static let dataRootEnvironmentKey = "LIGHTANCHOR_DATA_ROOT"

    static func rootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configuredPath = environment[dataRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
                .standardizedFileURL
        }

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("LightAnchor", isDirectory: true)
    }

    /// 事件日志目录（一条事件一个文件，见 `LocalEventStore`）。
    static func eventsDirectoryURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("events", isDirectory: true)
    }

    /// 数据根目录自带的 `.gitignore`：用户把这个目录 `git init` 就能直接用。
    /// 列的都是可重建的缓存与本机状态；剪贴板历史与事件日志都是用户数据，入库。
    static let gitIgnoreContents = """
    # LightAnchor 数据目录。以下是缓存与本机状态，可重建，不入版本库。
    memory-index.sqlite
    memory-index.sqlite-*
    diagnostics.log
    launch-marker.json
    *.lock
    .DS_Store

    """

    static func ensureGitIgnore(in root: URL, fileManager: FileManager = .default) throws {
        let url = root.appendingPathComponent(".gitignore")
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(gitIgnoreContents.utf8).write(to: url, options: .atomic)
    }

    static func assetsURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("assets", isDirectory: true)
    }

    static func diagnosticsURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("diagnostics.log")
    }

    static func launchMarkerURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("launch-marker.json")
    }

    static func memoryChatURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("memory-chat.json")
    }

    /// 「对话」页的检索索引（FTS5 + 端侧向量）。可重建缓存：事实源仍是事件日志。
    static func memoryIndexURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("memory-index.sqlite")
    }

    /// 过程记录的 trace 目录（每份录制一个 <uuid>.json）。会话元数据在事件日志里；
    /// trace 单独落盘是因为事件日志是整文件原子重写，长 trace 会放大每次提交。
    static func recordingsURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("recordings", isDirectory: true)
    }

    /// 跟随事情的剪贴板历史目录（每段工作一个 <episodeID>.json）。
    /// 与 trace 同理单独落盘：一段事里复制几十上百次，进事件日志会放大每次提交。
    static func clipboardHistoryURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("clipboard", isDirectory: true)
    }
}
