import Foundation

/// 「删除全部本地数据」的清单。
///
/// 写成一份可枚举的清单、而不是散在调用点，是因为它漏过：对话记录、用户手写的
/// 回顾正文和云端 API Key 曾经一直留在盘上，而确认弹窗已经宣称「已删除这台 Mac
/// 上的工作区数据」。清单分成两类是刻意的：
///
/// - **内容、凭据、缓存**：必须清空。用户以为删掉了的东西不能留在磁盘上。
/// - **界面与隐私偏好**：刻意保留。删数据不该把用户收紧过的采集开关退回默认
///   （默认往往更宽松），也不该让界面语言和主题突然变样。
///
/// `LocalDataErasureTests` 会核对源码里出现的每一个 UserDefaults 键都落在这两类
/// 之中：以后新增一个键却忘了分类，测试就红。
enum LocalDataErasure {

    /// 数据根目录下由应用写入、删数据时要一并移除的文件名。
    ///
    /// `.lock` 不在其中：每个存储各自在自己的锁下删数据，把锁文件一起删会让并发
    /// 写入者失去互斥。附件目录由 `LocalAssetStore.removeAll()` 负责，诊断日志由
    /// `LocalDiagnostics.removeAllData()` 负责，都不在这里重复。
    static var fileNames: [String] {
        [
            // 事件日志目录（整个目录一起移除）。
            LightAnchorStorage.eventsDirectoryURL(),
            LightAnchorStorage.launchMarkerURL(),
            LightAnchorStorage.memoryChatURL(),
            // 检索索引是缓存，但里面装着捕获与问答的全文，删数据必须一并清。
            LightAnchorStorage.memoryIndexURL(),
            // 过程记录的 trace 目录（整个目录一起移除）。
            LightAnchorStorage.recordingsURL(),
            // 跟随事情的剪贴板历史目录：里面是用户复制过的原文，必须一并清。
            LightAnchorStorage.clipboardHistoryURL()
        ].map(\.lastPathComponent) + [
            // 版本库装着数据的全部历史。「删除全部本地数据」宣称删干净，
            // 留着 .git 等于什么都没删。
            ".git",
            // 版本库的 .gitignore 是应用生成的，一并清。
            ".gitignore"
        ]
    }

    /// 上面这些文件在给定数据根目录下的位置。
    ///
    /// 取根目录而不是直接用 `LightAnchorStorage` 的默认路径，是因为事件存储的位置
    /// 可以注入（测试用临时目录）：照默认路径删会删到真人的数据。
    static func fileURLs(in root: URL) -> [URL] {
        fileNames.map { root.appendingPathComponent($0) }
    }

    /// 内容、凭据与缓存类的键：删数据时清空。
    ///
    /// 云端配置不在这里逐键列出——它和采集开关同住一个
    /// `intelligence.preferences` blob 里，整块删会把隐私开关一起退回默认，
    /// 所以由 `IntelligencePreferences.eraseCloudConfiguration` 只抹凭据部分。
    static var erasableUserDefaultsKeys: [String] {
        [
            AttentionWorkspace.inboxAutoArchiveEnabledKey,
            AttentionWorkspace.inboxAutoArchiveDaysKey,
            // 用户手写或生成的回顾正文，属于内容。
            NarrativeStore.storageKey,
            // 更新链配置：manifest 地址是用户填的，一并清。
            "lightanchor.updateChecksEnabled",
            "lightanchor.updateManifestURL",
            "lightanchor.updateLastCheckedAt",
            // 远端备份地址可能内嵌访问令牌（PAT），属于凭据，必须清。
            GitSnapshotService.remoteURLKey,
            GitSnapshotService.lastPushDateKey,
            // 同步状态与错误文本（错误里可能带远端地址），一并清。
            GitSnapshotService.lastSyncDateKey,
            GitSnapshotService.lastSyncErrorKey
        ] + PrivacyPermissionCache.allCacheKeys
    }

    /// 刻意保留的键：纯界面与隐私偏好。
    static let preservedUserDefaultsKeys: [String] = [
        AppLanguage.storageKey,
        AppLanguage.appleLanguagesKey,
        LightAnchorThemeController.storageKey,
        LightAnchorMenuBarPreference.storageKey,
        LightAnchorCaptureReturnPreference.storageKey,
        LightAnchorCaptureDestinationPreference.storageKey,
        GlobalHotKeyPreferences.storageKey,
        SceneCapturePreferences.storageKey,
        LightAnchorNarrativePreference.storageKey,
        // 采集与输出开关和云端凭据同住一个 blob；凭据由
        // IntelligencePreferences.eraseCloudConfiguration 单独抹掉。
        IntelligencePreferences.storageKey
    ]
}
