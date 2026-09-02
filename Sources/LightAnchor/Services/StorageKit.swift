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

    static func eventsURL(fileManager: FileManager = .default) -> URL {
        rootURL(fileManager: fileManager).appendingPathComponent("events.json")
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
}
