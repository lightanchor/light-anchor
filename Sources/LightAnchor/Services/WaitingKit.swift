import Foundation

#if os(macOS)
import Darwin
#endif

enum WaitingDetectionError: LocalizedError {
    case unsupported
    case invalidConfiguration
    case commandFailed(String)
    case externalEventFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported:
            tr("no_detector_for_this_wait_type")
        case .invalidConfiguration:
            tr("the_wait_detection_setup_is_incomplete")
        case .commandFailed(let message):
            message.isEmpty ? tr("the_wait_command_failed") : message
        case .externalEventFailed(let message):
            message.isEmpty ? tr("the_external_event_reported_a_failure") : message
        case .timedOut:
            tr("the_wait_passed_its_deadline")
        }
    }
}

protocol WaitingDetector: Sendable {
    var kind: WaitingMonitorKind { get }
    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String
}

struct CommandWaitingDetector: WaitingDetector {
    let kind: WaitingMonitorKind = .command

    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String {
        guard let command = configuration.command, !command.isEmpty else {
            throw WaitingDetectionError.invalidConfiguration
        }
        return try await ProcessWaitingSupport.run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", command],
            workingDirectory: configuration.workingDirectory
        )
    }
}

struct ProcessWaitingDetector: WaitingDetector {
    let kind: WaitingMonitorKind = .process

    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String {
        #if os(macOS)
        guard let processIdentifier = configuration.processIdentifier,
              processIdentifier > 0
        else { throw WaitingDetectionError.invalidConfiguration }

        while processIsRunning(processIdentifier) {
            try await Task.sleep(for: .milliseconds(400))
        }
        return "进程 \(processIdentifier) 已结束。"
        #else
        throw WaitingDetectionError.unsupported
        #endif
    }

    #if os(macOS)
    private func processIsRunning(_ processIdentifier: Int32) -> Bool {
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
    #endif
}

struct FileWaitingDetector: WaitingDetector {
    let kind: WaitingMonitorKind = .file

    private struct FileObservation: Equatable {
        let modificationDate: Date?
        let size: Int64?
    }

    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String {
        guard let fileURL = configuration.fileURL else {
            throw WaitingDetectionError.invalidConfiguration
        }

        var previousObservation: FileObservation?
        var stableSince: Date?

        while !Task.isCancelled {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else {
                previousObservation = nil
                stableSince = nil
                try await Task.sleep(for: .milliseconds(500))
                continue
            }

            if !configuration.fileRequiresChange || fileHasChanged(
                attributes: attributes,
                configuration: configuration
            ) {
                let observation = FileObservation(
                    modificationDate: attributes[.modificationDate] as? Date,
                    size: (attributes[.size] as? NSNumber)?.int64Value
                )
                if observation != previousObservation {
                    previousObservation = observation
                    stableSince = Date()
                }
                if configuration.fileStableDuration <= 0 ||
                    Date().timeIntervalSince(stableSince ?? Date()) >= configuration.fileStableDuration {
                    return "文件已完成：\(fileURL.path)"
                }
            } else {
                previousObservation = nil
                stableSince = nil
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CancellationError()
    }

    private func fileHasChanged(
        attributes: [FileAttributeKey: Any],
        configuration: WaitingMonitorConfiguration
    ) -> Bool {
        let currentDate = attributes[.modificationDate] as? Date
        let currentSize = (attributes[.size] as? NSNumber)?.int64Value
        if let baselineDate = configuration.fileBaselineModificationDate,
           let currentDate,
           currentDate > baselineDate {
            return true
        }
        if let baselineSize = configuration.fileBaselineSize,
           let currentSize,
           currentSize != baselineSize {
            return true
        }
        return configuration.fileBaselineModificationDate == nil &&
            configuration.fileBaselineSize == nil
    }
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

struct ExternalEventWaitingDetector: WaitingDetector {
    let kind: WaitingMonitorKind = .event

    func wait(for configuration: WaitingMonitorConfiguration) async throws -> String {
        guard let correlationID = configuration.eventCorrelationID,
              !correlationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw WaitingDetectionError.invalidConfiguration }

        let store = ExternalEventStore(fileURL: configuration.eventInboxURL)
        let sources = Set(configuration.eventSources)
        let kinds = Set(configuration.eventKinds)

        while !Task.isCancelled {
            let matches = try store.matching(
                correlationID: correlationID,
                sources: sources,
                kinds: kinds,
                after: configuration.eventAfter
            )
            if let event = matches.last {
                switch event.kind {
                case .completed:
                    return event.evidence
                case .failed:
                    throw WaitingDetectionError.externalEventFailed(event.evidence)
                case .cancelled:
                    throw WaitingDetectionError.externalEventFailed("\(event.evidence)，外部任务已取消。")
                case .started, .progress:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CancellationError()
    }
}

private enum ProcessWaitingSupport {
    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?
    ) async throws -> String {
        do {
            let output = try await ProcessExecutionSupport.run(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
            return output.isEmpty ? "命令已完成。" : output
        } catch let error as ProcessExecutionError {
            throw WaitingDetectionError.commandFailed(error.localizedDescription)
        }
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
              // 自动等待由 AutoWaitRouter 驱动；这里的事件检测器会把 failed
              // 映射成取消，而 Agent/命令的失败恰恰是「该回去看」的结果。
              !monitor.eventAutoManaged,
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
        case .command: CommandWaitingDetector()
        case .process: ProcessWaitingDetector()
        case .file: FileWaitingDetector()
        case .date: DateWaitingDetector()
        case .event: ExternalEventWaitingDetector()
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
