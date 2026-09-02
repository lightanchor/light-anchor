import Foundation

import AppKit

// MARK: - 过程记录：trace 存储 + 采样 + 协调
//
// 录制期间的事实条目（trace）不进事件日志：每份录制一个
// recordings/<uuid>.json，随写随存；事件日志只存会话元数据与成稿。
// 采样以前台应用切换通知驱动，周期兜底补漏；观察走与现场记录同一条
// 采集通道（同一套隐私排除规则），被排除的应用/域名/目录不会进 trace。

/// trace 文件仓库。目录可注入（测试用临时目录）。
struct RecordingTraceStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? LightAnchorStorage.recordingsURL()
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
        return decoder
    }

    func save(_ entries: [RecordingEntry], for sessionID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(entries)
        try data.write(to: fileURL(for: sessionID), options: .atomic)
    }

    func load(for sessionID: UUID) -> [RecordingEntry] {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return [] }
        return (try? Self.makeDecoder().decode([RecordingEntry].self, from: data)) ?? []
    }

    func remove(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
    }
}

/// 录制协调器：同一时刻至多一份在录。采样、去重、上限、trace 落盘都在这里；
/// 会话元数据的提交回给 workspace（事件日志的唯一写入口）。
@MainActor
final class RecordingCoordinator {
    private weak var workspace: AttentionWorkspace?
    private let traceStore: RecordingTraceStore
    /// 与现场记录同一条采集通道（隐私规则在读取时生效）。
    private let capture: () -> ContextCapsule

    private(set) var activeSessionID: UUID?
    private var isPaused = false
    private var entries: [RecordingEntry] = []
    private var limitReached = false

    /// 采样去重状态。
    private var lastFrontApplication = ""
    private var seenFiles: Set<URL> = []
    private var seenLinks: Set<URL> = []
    private var seenCommands: Set<String> = []

    private var periodicTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    /// 周期兜底间隔：应用内切窗口/换文件不触发激活通知，靠它补。
    static let samplingInterval: TimeInterval = 30

    init(
        workspace: AttentionWorkspace,
        traceStore: RecordingTraceStore = RecordingTraceStore(),
        capture: @escaping () -> ContextCapsule
    ) {
        self.workspace = workspace
        self.traceStore = traceStore
        self.capture = capture
    }

    // 协调器与 workspace 同寿命（应用整个生命周期）；激活观察者在停录时
    // 由 stopSampling 移除，deinit 只负责掐掉周期任务（Sendable，可跨隔离访问）。
    deinit {
        periodicTask?.cancel()
    }

    // MARK: 生命周期

    /// 开始一份录制。已有在录的先收尾（同一时刻至多一份）。
    @discardableResult
    func start(
        title: String,
        targetID: UUID? = nil,
        episodeID: UUID? = nil,
        autoFollowed: Bool = false,
        now: Date = Date()
    ) -> RecordingSession? {
        if activeSessionID != nil {
            stop(now: now)
        }
        let session = RecordingSession(
            title: title,
            targetID: targetID,
            episodeID: episodeID,
            autoFollowed: autoFollowed,
            startedAt: now,
            updatedAt: now
        )
        guard workspace?.persistRecordingSession(session, at: now) == true else { return nil }
        activeSessionID = session.id
        isPaused = false
        entries = []
        limitReached = false
        lastFrontApplication = ""
        seenFiles = []
        seenLinks = []
        seenCommands = []
        startSampling()
        sampleNow(at: now)
        return session
    }

    func pause(now: Date = Date()) {
        guard let sessionID = activeSessionID, !isPaused else { return }
        isPaused = true
        stopSampling()
        updateSession(sessionID, at: now) { session in
            session.status = .paused
        }
    }

    func resume(now: Date = Date()) {
        guard let sessionID = activeSessionID, isPaused else { return }
        isPaused = false
        updateSession(sessionID, at: now) { session in
            session.status = .recording
        }
        startSampling()
        sampleNow(at: now)
    }

    /// 收尾归档：trace 已在盘上，这里定格条目数与结束时刻。
    @discardableResult
    func stop(now: Date = Date()) -> RecordingSession? {
        guard let sessionID = activeSessionID else { return nil }
        stopSampling()
        flush(sessionID: sessionID)
        let entryCount = entries.count
        activeSessionID = nil
        isPaused = false
        entries = []
        return updateSession(sessionID, at: now) { session in
            session.status = .finished
            session.endedAt = now
            session.entryCount = entryCount
        }
    }

    /// 会话被删除时的善后：正在录的直接丢弃缓冲并停采样。
    func discard(_ sessionID: UUID) {
        traceStore.remove(for: sessionID)
        guard sessionID == activeSessionID else { return }
        stopSampling()
        activeSessionID = nil
        isPaused = false
        entries = []
    }

    /// 应用重启后，上次进程没来得及收尾的会话（日志里仍是在录/暂停）补个句点。
    /// 由维护循环调用；当前真正在录的那份不受影响。
    func finalizeOrphanedSessions(now: Date = Date()) {
        guard let workspace else { return }
        for session in workspace.snapshot.recordingSessions.values
        where session.isActive && session.id != activeSessionID {
            let entryCount = traceStore.load(for: session.id).count
            updateSession(session.id, at: now) { session in
                session.status = .finished
                session.endedAt = session.updatedAt
                session.entryCount = entryCount
            }
        }
    }

    // MARK: 外部事实（捕获 / 等待 / 工作段迁移）

    /// 生命周期事实在暂停时也记（等待结果到了本身就是过程的一部分）；
    /// 只有屏幕采样在暂停时停。
    func note(
        kind: RecordingEntryKind,
        title: String,
        detail: String = "",
        at now: Date = Date()
    ) {
        guard activeSessionID != nil else { return }
        append(RecordingEntry(at: now, kind: kind, title: title, detail: detail))
    }

    // MARK: 采样

    /// 立刻观察一次桌面并差分进 trace。
    func sampleNow(at now: Date = Date()) {
        guard activeSessionID != nil, !isPaused else { return }
        ingest(capture(), at: now)
    }

    /// 差分一份上下文观察：前台应用变了记应用，新出现的文件/网页/命令各记一条。
    /// 同一次录制里重复出现的不再记（trace 是「过程里发生过什么」，不是心跳日志）。
    func ingest(_ capsule: ContextCapsule, at now: Date = Date()) {
        guard activeSessionID != nil else { return }

        if let front = capsule.applications.first, front != lastFrontApplication {
            lastFrontApplication = front
            append(RecordingEntry(
                at: now,
                kind: .application,
                title: front,
                detail: capsule.windows.first ?? ""
            ))
        }

        for file in capsule.files where !seenFiles.contains(file) {
            seenFiles.insert(file)
            append(RecordingEntry(
                at: now,
                kind: .file,
                title: file.lastPathComponent,
                detail: file.deletingLastPathComponent().path
            ))
        }

        for link in capsule.links where !seenLinks.contains(link) {
            seenLinks.insert(link)
            let title = capsule.windowFacts
                .first { $0.documentURL == link }?
                .title ?? ""
            append(RecordingEntry(
                at: now,
                kind: .link,
                title: title.isEmpty ? String(link.absoluteString.prefix(80)) : title,
                detail: link.host() ?? ""
            ))
        }

        for (index, command) in capsule.terminalCommands.enumerated()
        where !command.isEmpty && !seenCommands.contains(command) {
            seenCommands.insert(command)
            let directory = index < capsule.terminalWorkingDirectories.count
                ? capsule.terminalWorkingDirectories[index].lastPathComponent
                : ""
            append(RecordingEntry(at: now, kind: .command, title: command, detail: directory))
        }
    }

    // MARK: 内部

    private func append(_ entry: RecordingEntry) {
        guard let sessionID = activeSessionID else { return }
        if entries.count >= RecordingSession.entryLimit {
            guard !limitReached else { return }
            limitReached = true
            entries.append(RecordingEntry(
                at: entry.at,
                kind: .note,
                title: tr("recording_hit_the_entry_limit")
            ))
            flush(sessionID: sessionID)
            return
        }
        // 相邻去重：同一件事的重复观察不追加。
        if entries.last?.dedupeKey == entry.dedupeKey { return }
        entries.append(entry)
        flush(sessionID: sessionID)
    }

    private func flush(sessionID: UUID) {
        do {
            try traceStore.save(entries, for: sessionID)
        } catch {
            LocalDiagnostics.shared.record(
                operation: "recording.trace.save",
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    private func updateSession(
        _ sessionID: UUID,
        at now: Date,
        mutate: (inout RecordingSession) -> Void
    ) -> RecordingSession? {
        guard let workspace,
              var session = workspace.snapshot.recordingSessions[sessionID]
        else { return nil }
        mutate(&session)
        session.updatedAt = now
        guard workspace.persistRecordingSession(session, at: now) else { return nil }
        return workspace.snapshot.recordingSessions[sessionID]
    }

    private func startSampling() {
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // 让出一拍再采：刚激活的应用要一小会儿才把窗口事实摆好。
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.sampleNow()
                }
            }
        }
        guard periodicTask == nil else { return }
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.samplingInterval))
                guard !Task.isCancelled else { return }
                self?.sampleNow()
            }
        }
    }

    private func stopSampling() {
        periodicTask?.cancel()
        periodicTask = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}
