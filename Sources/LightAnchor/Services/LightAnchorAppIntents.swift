// MARK: - 快捷指令入口
//
// 这里的标题与说明是 `LocalizedStringResource`：App Intents 在构建期就把它们
// 抽进「快捷指令」应用的元数据，取的是主 bundle 的表，而 tr() 走的是 SPM 的
// Bundle.module——两条路。所以这几条暂时留中文，要双语得先把这套字符串搬进
// 主 bundle 的资源里，是一件单独的事。
//
// 元数据由 Scripts/build-release.sh 调 appintentsmetadataprocessor 生成到
// Contents/Resources/Metadata.appintents；没有它「快捷指令」根本看不见这些动作。
// 处理器只认编译期抽取，所以这个文件里的 title / description / phrases 必须是
// 字面量，不能经 tr() 之类的函数算出来。

#if os(macOS)
import AppIntents

/// 工作区拒绝动作时抛给「快捷指令」，让它把原因原样显示出来，而不是默默报成功。
struct LightAnchorIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AttentionActionResult {
    /// 只把拒绝当失败；其余结果用 `.result()` 静默完成，和菜单里的同名动作一致。
    fileprivate func throwIfRejected() throws {
        if case .rejected(let message) = self {
            throw LightAnchorIntentError(message: message)
        }
    }
}

struct LightAnchorCaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "捕获想法"
    static let description = IntentDescription("把一段文字保存到轻锚的稍后处理箱。")
    static let openAppWhenRun = true

    @Parameter(title: "内容")
    var text: String

    init() {
        text = ""
    }

    // 路由器持有 App 启动时 attach 的工作区；openAppWhenRun 保证 perform 时 App 已在跑。
    @MainActor
    func perform() async throws -> some IntentResult {
        try AttentionActionRouter.shared.perform(.captureText(text)).throwIfRejected()
        return .result()
    }
}

struct LightAnchorBeginWaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "开始手动等待"
    static let description = IntentDescription("为当前目标创建一个需要稍后确认的手动等待。")
    static let openAppWhenRun = true

    @Parameter(title: "等待什么")
    var description: String

    init() {
        description = ""
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try AttentionActionRouter.shared.perform(.beginManualWaiting(description)).throwIfRejected()
        return .result()
    }
}

struct LightAnchorEndCurrentWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "结束当前工作"
    static let description = IntentDescription("结束轻锚当前目标，并保留已记录的上下文事实。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try AttentionActionRouter.shared.perform(.endCurrentEpisode).throwIfRejected()
        return .result()
    }
}

// 每条唤起短语都必须包含 `\(.applicationName)`（真正的字符串插值，不是转义文本），
// 否则 appintentsmetadataprocessor 直接判错、整套元数据都不产出。
struct LightAnchorAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LightAnchorEndCurrentWorkIntent(),
            phrases: [
                "结束 \(.applicationName) 当前工作",
                "用 \(.applicationName) 结束当前工作"
            ],
            shortTitle: "结束当前工作",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: LightAnchorCaptureTextIntent(),
            phrases: [
                "用 \(.applicationName) 捕获想法",
                "记到 \(.applicationName)"
            ],
            shortTitle: "捕获想法",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: LightAnchorBeginWaitingIntent(),
            phrases: [
                "用 \(.applicationName) 开始等待",
                "在 \(.applicationName) 里开始手动等待"
            ],
            shortTitle: "开始手动等待",
            systemImageName: "hourglass"
        )
    }
}
#endif
