import Combine
import Foundation

/// 把「一批事件落盘」翻译成「一次 git 快照」的协调器。
///
/// 监听 `lightAnchorEventsChanged`，在一个很短的去抖窗口合并突发写入（用户
/// 连续操作、回放后台维护），再落一个快照。若窗口内没有再触发，就把这次
/// 主动提交当作断点。
///
/// 这样设计而不是「每个事件都提交」：提交是昂贵的进程调用，而 git 对同一批
/// 内容只会产生一个有意义的快照。去抖窗口足够短，用户几乎感知不到延迟。
///
/// 运行在 main actor：git 调用经 `GitSnapshotService` 的串行队列，不会卡 UI。
@MainActor
final class SnapshotController: NSObject {
    private let service: GitSnapshotService
    private var debounceTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var pendingNotes: [SnapshotNote] = []
    private var isStarted = false
    private let debounce: Duration
    private let autoSyncInterval: Duration
    /// 同步并进远端新内容后要重载的工作区。弱引用：控制器不该续工作区的命。
    weak var workspace: AttentionWorkspace?

    init(
        service: GitSnapshotService = GitSnapshotService(),
        debounce: Duration = .seconds(2),
        autoSyncInterval: Duration = .seconds(900)
    ) {
        self.service = service
        self.debounce = debounce
        self.autoSyncInterval = autoSyncInterval
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventsChanged),
            name: .lightAnchorEventsChanged,
            object: nil
        )
        let service = self.service
        preparationTask = Task.detached(priority: .utility) {
            try? service.prepare()
        }
        scheduleSnapshot()
        startAutoSync()
    }

    func stop() {
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        debounceTask?.cancel()
        debounceTask = nil
        autoSyncTask?.cancel()
        autoSyncTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        pendingNotes.removeAll()
    }

    /// 周期性自动同步。两道闸门：填了远端地址，且用户已经确认过首次推送
    /// （`lastPushDate != nil`）——数据出机永远是用户先点头，定时器只是延续。
    private func startAutoSync() {
        guard autoSyncTask == nil else { return }
        let service = self.service
        let interval = autoSyncInterval
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard service.remoteURL != nil, service.lastPushDate != nil else { continue }
                let outcome = await Task.detached(priority: .utility) {
                    try? service.sync()
                }.value
                // 远端并进了新内容 → 内存里的快照过期了，重载。
                if outcome == .merged {
                    _ = self?.workspace?.reloadFromDisk()
                }
            }
        }
    }

    @objc private func eventsChanged(_ notification: Notification) {
        guard let note = notification.userInfo?["note"] as? SnapshotNote else { return }
        pendingNotes.append(note)
        scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        debounceTask?.cancel()
        let service = self.service
        let preparation = preparationTask
        let delay = debounce
        debounceTask = Task { [weak self] in
            await preparation?.value
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.isStarted else { return }
            let note = self.pendingNotes.isEmpty
                ? tr("snapshot_note_startup") : SnapshotNote.combined(self.pendingNotes)
            self.pendingNotes.removeAll()
            await Task.detached(priority: .utility) {
                _ = try? service.snapshot(note: note)
            }.value
        }
    }
}
