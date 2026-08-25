// MARK: - 快捷指令入口
//
// 这里的标题与说明是 `LocalizedStringResource`：App Intents 在构建期就把它们
// 抽进「快捷指令」应用的元数据，取的是主 bundle 的表，而 tr() 走的是 SPM 的
// Bundle.module——两条路。所以这几条暂时留中文，要双语得先把这套字符串搬进
// 主 bundle 的资源里，是一件单独的事。

#if os(macOS)
import AppIntents

struct LightAnchorCaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "捕获想法"
    static let description = IntentDescription("把一段文字保存到轻锚的稍后处理箱。")
    static let openAppWhenRun = true

    @Parameter(title: "内容")
    var text: String

    init() {
        text = ""
    }

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run {
            AttentionActionRouter.shared.perform(.captureText(text))
        }
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

    init(description: String) {
        self.description = description
    }

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run {
            AttentionActionRouter.shared.perform(.beginManualWaiting(description))
        }
        return .result()
    }
}

struct LightAnchorEndCurrentWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "结束当前工作"
    static let description = IntentDescription("结束轻锚当前目标，并保留已记录的上下文事实。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run {
            AttentionActionRouter.shared.perform(.endCurrentEpisode)
        }
        return .result()
    }
}

struct LightAnchorAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LightAnchorEndCurrentWorkIntent(),
            phrases: ["结束 \\(.applicationName) 当前工作"],
            shortTitle: "结束当前工作",
            systemImageName: "checkmark.circle"
        )
    }
}
#endif
