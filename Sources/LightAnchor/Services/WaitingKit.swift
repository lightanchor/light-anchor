import Foundation

enum WaitingDetectionError: LocalizedError {
    case unsupported
    case invalidConfiguration
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported:
            tr("no_detector_for_this_wait_type")
        case .invalidConfiguration:
            tr("the_wait_detection_setup_is_incomplete")
        case .timedOut:
            tr("the_wait_passed_its_deadline")
        }
    }
}

protocol WaitingDetector: Sendable {
    var kind: WaitingMonitorKind { get }
    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String
}

struct DateWaitingDetector: WaitingDetector {
    let kind: WaitingMonitorKind = .date

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
                let evidence = try await Self.waitForResult(
                    monitor: monitor,
                    timeoutAt: waiting.timeoutAt
                )
                guard !Task.isCancelled else { return }
                self?.workspace?.completeWaiting(waiting.id, evidence: evidence)
            } catch WaitingDetectionError.timedOut {
                guard !Task.isCancelled else { return }
                self?.workspace?.timeoutWaiting(waiting.id)
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

    private static func waitForResult(
        monitor: WaitingMonitorConfiguration,
        timeoutAt: Date?
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await detector(for: monitor.kind).wait(for: monitor)
            }
            if let timeoutAt {
                group.addTask {
                    let interval = timeoutAt.timeIntervalSinceNow
                    if interval > 0 {
                        try await Task.sleep(for: .seconds(interval))
                    }
                    throw WaitingDetectionError.timedOut
                }
            }
            guard let result = try await group.next() else {
                throw WaitingDetectionError.unsupported
            }
            group.cancelAll()
            return result
        }
    }

    private static func detector(for kind: WaitingMonitorKind) -> any WaitingDetector {
        switch kind {
        case .date: DateWaitingDetector()
        case .manual: ManualWaitingDetector()
        }
    }
}

private struct ManualWaitingDetector: WaitingDetector {
    let kind: WaitingMonitorKind = .manual

    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String {
        throw WaitingDetectionError.unsupported
    }
}
