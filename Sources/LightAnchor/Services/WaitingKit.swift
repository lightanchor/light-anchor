import Foundation

enum WaitingDetectionError: LocalizedError {
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            tr("the_wait_detection_setup_is_incomplete")
        }
    }
}

/// 定时等待：睡到约定时刻即算结果到了。手动等待没有探测器，不会被挂上监视。
struct DateWaitingDetector: Sendable {
    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String {
        guard let date = configuration.date else {
            throw WaitingDetectionError.invalidConfiguration
        }
        let interval = date.timeIntervalSinceNow
        if interval > 0 {
            try await Task.sleep(for: .seconds(interval))
        }
        return "等待时间已到达。"
    }
}

@MainActor
final class WaitingCoordinator {
    private weak var workspace: AttentionWorkspace?
    /// The token identifies which detector owns the entry. A finishing detector
    /// must not evict the replacement that a cancel-then-restart already
    /// installed, or two detectors end up running for the same wait.
    private var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    init(workspace: AttentionWorkspace) {
        self.workspace = workspace
    }

    deinit {
        tasks.values.forEach { $0.task.cancel() }
    }

    func startMonitoring(_ waiting: WaitingItem) {
        guard let monitor = waiting.monitor,
              monitor.kind != .manual,
              waiting.status == .waiting
        else { return }

        // Background maintenance runs repeatedly. Keep an active detector alive;
        // only a new waiting item or an explicit cancellation should replace it.
        guard tasks[waiting.id] == nil else { return }
        let token = UUID()
        tasks[waiting.id] = (token, Task { [weak self] in
            do {
                let evidence = try await DateWaitingDetector().wait(for: monitor)
                guard !Task.isCancelled else { return }
                self?.workspace?.completeWaiting(waiting.id, evidence: evidence)
            } catch {
                guard !Task.isCancelled else { return }
                self?.workspace?.cancelWaiting(
                    waiting.id,
                    evidence: error.localizedDescription
                )
            }
            if self?.tasks[waiting.id]?.token == token {
                self?.tasks.removeValue(forKey: waiting.id)
            }
        })
    }

    /// 启动与维护循环的补挂入口：把日志里仍在等待、带定时监视器的项重新挂上。
    func startMonitoringActiveWaits() {
        workspace?.snapshot.activeWaitingItems
            .filter { $0.status == .waiting }
            .forEach(startMonitoring)
    }

    func cancelMonitoring(_ waitingID: UUID) {
        tasks.removeValue(forKey: waitingID)?.task.cancel()
    }

    func cancelAllMonitoring() {
        tasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
    }
}
