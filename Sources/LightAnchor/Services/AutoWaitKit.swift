import Foundation

// MARK: - 自动等待（Agent / 终端事件自动归集）
//
// 与「先声明等待、再等事件」的连接器相反，这里事件先到、等待后建：
// Agent 会话开始工作、终端跑起长命令时发布 started，路由器把它翻译成
// 一个后台等待项；completed / failed 让它变成「可以返回」——失败恰恰是
// 最需要回去看的结果；同一 correlationID 的新 started 会把已就绪的等待
// 重新打开（Agent 的下一个回合）。

// 一个来源开不开，唯一的真相是 设置 → 连接 里接没接入：接入 = 开，移除 = 关。
// 这里曾经还有一份 `AutoWaitPreferences`（设置 → 接收 的两个开关），是同一件事
// 的第二个总闸——没接入时它拨了也没反应，接入后关掉它会让事件被静默丢弃，
// 用户只会以为接入坏了。旧版本在 UserDefaults 里留下的
// `lightanchor.autoWaitPreferences` 不再读取。

/// 每个自动来源的等待归集到一个固定 ID 的中枢目标：
/// 固定 ID 让查找不依赖名称（改名安全）、重放和跨设备合并天然收敛。
enum AutoWaitHub {
    struct Descriptor {
        let targetID: UUID
        let name: String
        let note: String
        let waitingKind: WaitingKind
        let fallbackTitle: String
    }

    static let agentTargetID = UUID(uuidString: "5A6E17A9-0A0A-4A0A-8A0A-000000000001")!
    static let terminalTargetID = UUID(uuidString: "5A6E17A9-0A0A-4A0A-8A0A-000000000002")!

    static func descriptor(for source: ExternalEventSource) -> Descriptor? {
        switch source {
        case .agent:
            Descriptor(
                targetID: agentTargetID,
                name: "Agent 会话",
                note: "Agent 报告的工作会自动归集到这里。",
                waitingKind: .agent,
                fallbackTitle: "Agent 会话"
            )
        case .terminal:
            Descriptor(
                targetID: terminalTargetID,
                name: "终端命令",
                note: "终端里的长命令会自动归集到这里。",
                waitingKind: .command,
                fallbackTitle: "终端命令"
            )
        default:
            nil
        }
    }
}

/// 自动等待路由器：增量读取外部事件收件箱，把新事件交给工作区应用。
/// 日志只追加；进程重启后从头重放，由工作区一侧的幂等路由收敛。
@MainActor
final class AutoWaitRouter {
    private let inboxURL: URL?
    private var processedEventCount = 0
    private var reportedReadFailure = false

    init(inboxURL: URL? = nil) {
        self.inboxURL = inboxURL
    }

    func route(into workspace: AttentionWorkspace, now: Date = Date()) {
        let store = ExternalEventStore(fileURL: inboxURL)
        let events: [ExternalEvent]
        do {
            events = try store.events()
            reportedReadFailure = false
        } catch ExternalEventStoreError.inboxTooLarge {
            // 被刷量了：只留最近一批，游标归零，下一轮从压缩后的文件继续。
            try? store.compact()
            processedEventCount = 0
            LocalDiagnostics.shared.record(
                operation: "auto-wait.read",
                message: "外部事件收件箱超限，已压缩"
            )
            return
        } catch {
            // 收件箱损坏不应打断维护循环；记一次诊断，等它被修复。
            if !reportedReadFailure {
                reportedReadFailure = true
                LocalDiagnostics.shared.record(
                    operation: "auto-wait.read",
                    message: error.localizedDescription
                )
            }
            return
        }

        // 收件箱被清空（例如用户删数据）时回退游标。
        processedEventCount = min(processedEventCount, events.count)
        guard events.count > processedEventCount else { return }
        let fresh = events[processedEventCount...]
        processedEventCount = events.count

        // 归集得了的来源由 AutoWaitHub.descriptor 决定（agent / terminal）；
        // 其余来源在工作区一侧原样落地。
        for event in fresh {
            workspace.applyAutoWaitEvent(event.clampingOccurredAt(to: now))
        }
    }
}
