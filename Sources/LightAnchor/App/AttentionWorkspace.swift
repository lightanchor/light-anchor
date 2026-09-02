import Combine
import Foundation

@MainActor
final class AttentionWorkspace: ObservableObject {
    // 纯常量，不需要跟着类走主线程隔离：LocalDataErasure 的清单在非隔离上下文里读。
    nonisolated static let inboxAutoArchiveEnabledKey = "lightanchor.inboxAutoArchiveEnabled"
    nonisolated static let inboxAutoArchiveDaysKey = "lightanchor.inboxAutoArchiveDays"

    @Published private(set) var snapshot: AttentionSnapshot
    @Published private(set) var lastError: String?
    @Published private(set) var lastNotice: String?
    /// 刚放下并存好现场的一件事（仅会话内，不落盘）：「现在」页据此出确认卡，
    /// 让用户看到保存了什么、能逐条剔除，由用户点掉。
    @Published private(set) var recentSetAside: RecentSetAside?

    struct RecentSetAside: Equatable, Identifiable {
        let targetID: UUID
        let targetName: String
        let snapshotID: UUID
        let at: Date

        var id: UUID { snapshotID }
    }

    private let store: LocalEventStore
    private let assetStore: LocalAssetStore
    private var events: [AttentionEvent]
    /// Writing is an atomic replace of the whole log, so while the file on disk
    /// cannot be read the in-memory history is not a safe base to write from:
    /// committing would replace the unreadable file and discard everything.
    private var isEventLogReadable = true
    private lazy var waitingCoordinator = WaitingCoordinator(workspace: self)
    private lazy var scheduledTaskCoordinator = ScheduledTaskCoordinator(workspace: self)
    private let recordingTraceStore: RecordingTraceStore
    private lazy var recordingCoordinator = RecordingCoordinator(
        workspace: self,
        traceStore: recordingTraceStore,
        capture: { [weak self] in
            guard let self else { return ContextCapsule() }
            return self.contextCapture(self.intelligencePreferences, self.sceneCapturePreferences)
        }
    )
    private let autoWaitRouter: AutoWaitRouter
    private let contextCapture: (IntelligencePreferences, SceneCapturePreferences) -> ContextCapsule

    @Published private(set) var sceneCapturePreferences: SceneCapturePreferences = .load()

    init(
        store: LocalEventStore = LocalEventStore(),
        assetStore: LocalAssetStore? = nil,
        externalEventInboxURL: URL? = nil,
        sceneCapturePreferences: SceneCapturePreferences? = nil,
        recordingTraceStore: RecordingTraceStore? = nil,
        contextCapture: ((IntelligencePreferences, SceneCapturePreferences) -> ContextCapsule)? = nil
    ) {
        self.store = store
        self.assetStore = assetStore ?? LocalAssetStore()
        self.recordingTraceStore = recordingTraceStore ?? RecordingTraceStore()
        self.autoWaitRouter = AutoWaitRouter(inboxURL: externalEventInboxURL)
        self.sceneCapturePreferences = sceneCapturePreferences ?? .load()
        #if os(macOS)
        self.contextCapture = contextCapture ?? { intelligence, sourcePreferences in
            MacContextRecorder().capture(
                options: ContextCaptureOptions(
                    preferences: intelligence,
                    sourcePreferences: sourcePreferences
                )
            ).capsule
        }
        #else
        self.contextCapture = contextCapture ?? { _, _ in ContextCapsule() }
        #endif

        do {
            let loadedEvents = try store.load()
            events = loadedEvents
            snapshot = AttentionSnapshot.replay(loadedEvents)
            isEventLogReadable = true
        } catch {
            events = []
            snapshot = AttentionSnapshot()
            lastError = Self.unreadableLogMessage(error)
            isEventLogReadable = false
        }
    }

    private static var unreadableLogRefusalMessage: String {
        tr("can_t_read_local_records")
    }

    private static func unreadableLogMessage(_ error: Error) -> String {
        unreadableLogRefusalMessage + "（\(error.localizedDescription)）"
    }

    var currentEpisode: AttentionEpisode? {
        snapshot.currentEpisode
    }

    func clearError() {
        lastError = nil
    }

    func presentNotice(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastNotice = trimmed
    }

    func clearNotice() {
        lastNotice = nil
    }

    @discardableResult
    func publishExternalEvent(_ event: ExternalEvent) -> Bool {
        do {
            try ExternalEventStore().publish(event)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            LocalDiagnostics.shared.record(
                operation: "external-event.publish",
                message: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    func beginWaitingFromIncomingURL(
        _ request: IncomingURLWaitingRequest,
        now: Date = Date()
    ) -> WaitingItem? {
        guard let episode = currentEpisode, episode.state != .ended else {
            presentNotice(tr("no_work_in_progress_to_attach"))
            return nil
        }

        let description = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            presentNotice(tr("external_wait_needs_a_description"))
            return nil
        }

        guard var monitor = try? GenericExternalEventConnector(
            kind: request.kind,
            source: request.source
        ).makeMonitor(
            description: description,
            value: request.correlationID
        ) else {
            presentNotice(tr("external_wait_has_an_invalid_correlation"))
            return nil
        }

        // A completed download can hand off its wait and event URLs almost together.
        // The correlation ID is unique to this explicit action, so a short grace
        // window prevents that event from racing the waiting monitor setup.
        monitor.eventAfter = now.addingTimeInterval(-60)

        let waiting = beginWaiting(
            episodeID: episode.id,
            kind: request.kind,
            description: description,
            completionCondition: request.detail,
            restorePolicy: .notify,
            monitor: monitor,
            now: now
        )
        if waiting == nil {
            presentNotice(tr("can_t_create_the_external_wait"))
        }
        return waiting
    }

    func runBackgroundMaintenance(now: Date = Date()) {
        _ = archiveConfiguredInbox(now: now)
        autoWaitRouter.route(into: self)
        #if os(macOS)
        backfillCaptureText()
        #endif
        backfillInboxOrganization()
        startActiveWaitingMonitors()
        scheduledTaskCoordinator.startMonitoringScheduledTasks(now: now)
        recordingCoordinator.finalizeOrphanedSessions(now: now)
    }

    // MARK: - 时间账本

    // MARK: - 智能输入组装（回场简报 / 清理台 / 叙事）

    /// 组装回场简报的输入：全部是已有的本地事实。
    func makeReturnBriefingInput(
        episodeID: UUID,
        waitingID: UUID? = nil,
        now: Date = Date()
    ) -> ReturnBriefingInput? {
        guard let episode = snapshot.episodes[episodeID],
              let target = snapshot.targets[episode.targetID]
        else { return nil }

        let scene = snapshot.latestSceneSnapshot(for: episode.targetID)
        let waiting = waitingID.flatMap { snapshot.waitingItems[$0] }
        let awayReference = waiting?.startedAt ?? episode.updatedAt
        let capturesWhileAway = snapshot.captures.values
            .filter { $0.capturedAt > awayReference && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
            .prefix(5)
            .map { capture in
                let text = capture.title?.isEmpty == false ? (capture.title ?? "") : capture.body
                return "[\(capture.kind.title)] \(String(text.prefix(40)))"
            }
        let sceneReturnCue = scene?.returnCue ?? ""
        // 这件事的历史纵深：简报「你在哪」第一次有全程视角（累计/上次/线索）。
        let historyLine = MemoryRecall.targetHistory(
            targetID: episode.targetID, events: events, snapshot: snapshot, now: now
        ).map { MemoryRecall.briefingHistoryLine(targetName: target.name, digest: $0) } ?? ""
        return ReturnBriefingInput(
            targetName: target.name,
            targetNote: target.note,
            returnCue: sceneReturnCue.isEmpty ? episode.returnCue : sceneReturnCue,
            awayMinutes: max(0, Int(now.timeIntervalSince(awayReference) / 60)),
            waitingEvidence: waiting?.evidence ?? "",
            sceneItems: scene?.restorableItems ?? [],
            capturesWhileAway: Array(capturesWhileAway),
            targetHistoryLine: historyLine
        )
    }

    /// 从现场快照出发组装回场简报（重返现场面板用）：等待的 episode 优先，
    /// 否则取该目标最近的一段。
    func makeReturnBriefingInput(
        sceneSnapshot: SceneSnapshot,
        waitingID: UUID?,
        now: Date = Date()
    ) -> ReturnBriefingInput? {
        let episodeID = waitingID.flatMap { snapshot.waitingItems[$0]?.episodeID }
            ?? sceneSnapshot.targetID.flatMap { targetID in
                snapshot.episodes.values
                    .filter { $0.targetID == targetID }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .first?.id
            }
        guard let episodeID else { return nil }
        return makeReturnBriefingInput(episodeID: episodeID, waitingID: waitingID, now: now)
    }

    /// 收件箱清理台的输入条目（内容截断到摘要级）。
    func makeInboxTriageItems(now: Date = Date()) -> [InboxTriageItem] {
        snapshot.inbox.map { capture in
            let title = capture.title ?? ""
            let text = !title.isEmpty
                ? title
                : (!capture.body.isEmpty ? capture.body : (capture.sourceURL?.absoluteString ?? ""))
            return InboxTriageItem(
                captureID: capture.id,
                kind: capture.kind,
                summary: String(text.prefix(80)),
                ageDays: max(0, Int(now.timeIntervalSince(capture.capturedAt) / 86_400)),
                tags: capture.tags,
                historyHint: MemoryRecall.captureDispositionHint(
                    for: capture, snapshot: snapshot, now: now
                )
            )
        }
    }

    /// 清理台提示里的「最近在做的事」。
    var recentTargetNames: [String] {
        snapshot.targets.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
            .map(\.name)
    }

    /// 应用用户勾选的清理提议。keep 不算数；转等待在没有当前工作时跳过。
    @discardableResult
    func applyInboxTriageProposals(
        _ proposals: [InboxTriageProposal],
        now: Date = Date()
    ) -> (applied: Int, skipped: Int) {
        var applied = 0
        var skipped = 0
        for proposal in proposals {
            guard let capture = snapshot.captures[proposal.captureID],
                  capture.status == .inbox
            else {
                skipped += 1
                continue
            }
            let succeeded: Bool
            switch proposal.action {
            case .keep:
                continue
            case .archive:
                succeeded = archiveCapture(proposal.captureID, now: now)
            case .saveReference:
                succeeded = saveCaptureAsReference(proposal.captureID, now: now)
            case .startTarget:
                succeeded = adoptCaptureAsTarget(capture, now: now)
            case .convertToWaiting:
                succeeded = beginWaitingFromCapture(proposal.captureID, now: now) != nil
            }
            if succeeded { applied += 1 } else { skipped += 1 }
        }
        return (applied, skipped)
    }

    /// 批量整理的「立为一件事」：建立目标并归档来源捕获
    /// （进入目标时重新出现），但绝不开始、不切走当前工作。
    private func adoptCaptureAsTarget(_ capture: CaptureItem, now: Date) -> Bool {
        let title = capture.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (title?.isEmpty == false ? title : nil)
            ?? capture.body.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "新注意力目标"
        guard let target = createTarget(
            name: String(name.prefix(60)),
            note: "从稍后处理箱整理而来。",
            now: now
        ) else { return false }
        _ = target
        return archiveCapture(capture.id, now: now)
    }

    /// 「对话」页的问答检索：从事件流与快照收集带来源标注的事实行。
    /// 纯读取，不产生事件；现场细节（剪贴板/终端命令）不进事实行。
    /// 生产走下面的索引版；这是同一套事实拼装的同步入口，事件日志是
    /// private 的，MemoryRecallTests 靠它验证拼装逻辑。
    func makeMemoryQuestionContext(question: String, now: Date = Date()) -> MemoryQuestionContext {
        MemoryRecall.questionContext(
            question: question,
            events: events,
            snapshot: snapshot,
            now: now
        )
    }

    /// 「对话」页的问答检索（索引版，docs/chat-memory-design.md 一期）：
    /// 活状态与账本事实照旧本地拼装；历史召回走 MemoryIndex（FTS5 trigram +
    /// 端侧向量），取代原来的关键词子串匹配；追问先按需改写再检索。
    /// 索引读取失败时回落关键词检索并记诊断——两者都是本地事实，只差召回质量。
    func makeChatQuestionContext(
        question: String,
        history: [MemoryChatTurn],
        index: MemoryIndex = .shared,
        now: Date = Date()
    ) async -> MemoryQuestionContext {
        var searchQuery = question
        if MemoryQueryRewrite.needsRewrite(question: question, hasHistory: !history.isEmpty) {
            let engine = intelligenceEngine
            if let rewritten = await MemoryQueryRewrite.withTimeout(seconds: 6, {
                await engine.rewriteMemoryQuery(question: question, history: history)
            }) {
                searchQuery = rewritten
            }
        }

        var context = MemoryRecall.questionContext(
            question: question,
            events: events,
            snapshot: snapshot,
            now: now,
            includeCaptureSearch: false
        )
        do {
            let hits = try await index.search(query: searchQuery, now: now)
            let indexFacts = hits.map { hit in
                MemoryFact(label: Self.factLabel(for: hit.kind), text: Self.factText(for: hit, now: now))
            }
            context.facts = Array((context.facts + indexFacts).prefix(MemoryRecall.maximumFacts))
        } catch {
            LocalDiagnostics.shared.record(
                operation: "memory-index.search",
                message: error.localizedDescription
            )
            context = MemoryRecall.questionContext(
                question: question,
                events: events,
                snapshot: snapshot,
                now: now
            )
        }
        return context
    }

    /// 刷新检索索引：主线程取材（值拷贝），派生与写入都在后台。
    /// 60 秒节流在索引侧；失败只记诊断，不打断任何前台动作。
    func refreshMemoryIndex(index: MemoryIndex = .shared, now: Date = Date()) {
        let items = MemoryIndexSource.items(events: events, snapshot: snapshot, now: now)
        guard !items.isEmpty else { return }
        Task.detached(priority: .utility) {
            await index.refresh(items: items, now: now)
        }
    }

    private static func factLabel(for kind: MemoryIndexItem.Kind) -> String {
        switch kind {
        case .capture: tr("fact_label_capture")
        case .trace: tr("fact_label_work")
        case .chat: tr("fact_label_chat")
        }
    }

    private static func factText(for hit: MemoryIndexHit, now: Date) -> String {
        let singleLine = hit.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
        let day = hit.createdAt.formatted(.dateTime.month(.defaultDigits).day())
        return "\(day) \(String(singleLine.prefix(120)))"
    }

    /// 组装叙事输入：把周期账本的事实写成句子，模型只许复述它们。
    func makeNarrativeInput(for period: ReviewPeriod, now: Date = Date()) -> NarrativeInput {
        let summary = focusPeriodSummary(in: period.interval(now: now), now: now)
        var facts: [String] = []
        let minutes = Int(summary.focusDuration / 60)
        if minutes >= 1 {
            facts.append(
                String(
                    format: summary.segmentCount == 1
                        ? tr("focused_for_in_n_segments_one") : tr("focused_for_in_n_segments"),
                    UserFacingCopy.focusDuration(minutes),
                    summary.segmentCount
                )
            )
        }
        for stat in summary.targetStats.prefix(3) {
            let statMinutes = Int(stat.duration / 60)
            guard statMinutes >= 1 else { continue }
            let name = snapshot.targets[stat.targetID]?.name ?? tr("untitled_work")
            facts.append(
                String(
                    format: tr("name_took_duration"),
                    name,
                    UserFacingCopy.focusDuration(statMinutes)
                )
            )
        }
        if summary.completedCount > 0 {
            facts.append(String(
                format: summary.completedCount == 1
                    ? tr("finished_n_things_one") : tr("finished_n_things"),
                summary.completedCount
            ))
        }
        if summary.readyWaitingCount > 0 {
            facts.append(
                String(
                    format: summary.readyWaitingCount == 1
                        ? tr("n_external_results_arrived_one") : tr("n_external_results_arrived"),
                    summary.readyWaitingCount
                )
            )
        }
        if summary.captureCount > 0 {
            facts.append(String(
                format: summary.captureCount == 1
                    ? tr("captured_n_thoughts_one") : tr("captured_n_thoughts"),
                summary.captureCount
            ))
        }
        // 与上一周期的对比——叙事第一次有纵深，仍然只是可复述的事实。
        if let comparison = MemoryRecall.periodComparison(period: period, events: events, now: now) {
            facts.append(comparison)
        }
        return NarrativeInput(periodTitle: period.title(now: now), factLines: facts)
    }

    /// 现在页 hero 的历史小字（「累计 6 小时 40 分 · 9 段 · 上次 8月20日」）。
    /// 只有一段历史或太短时返回 nil，不值得占一行。
    func currentTargetHistoryLine(now: Date = Date()) -> String? {
        guard let episode = currentEpisode else { return nil }
        guard let digest = MemoryRecall.targetHistory(
            targetID: episode.targetID, events: events, snapshot: snapshot, now: now
        ) else { return nil }
        return MemoryRecall.targetHistoryLine(digest)
    }

    /// 天（startOfDay）→ 专注时长，热力图的时长档用。
    func focusDayDurations(now: Date = Date()) -> [Date: TimeInterval] {
        FocusLedger.dayDurations(segments: FocusLedger.segments(events: events, now: now))
    }

    /// 一个周期（日/周/月）的注意力事实汇总。
    func focusPeriodSummary(in interval: DateInterval, now: Date = Date()) -> FocusPeriodSummary {
        FocusLedger.summary(events: events, interval: interval, now: now)
    }

    func recentWorkTraces(in interval: DateInterval, now: Date = Date()) -> [RecentWorkTrace] {
        WorkHistoryBuilder.traces(
            events: events,
            snapshot: snapshot,
            interval: interval,
            now: now
        )
    }

    func stopBackgroundMaintenance() {
        waitingCoordinator.cancelAllMonitoring()
        scheduledTaskCoordinator.cancelAllMonitoring()
        // 应用要退出了：在录的过程记录就地收尾，别留一份「还在录」的孤儿。
        _ = recordingCoordinator.stop()
    }

    @discardableResult
    func reloadFromDisk() -> Bool {
        waitingCoordinator.cancelAllMonitoring()
        scheduledTaskCoordinator.cancelAllMonitoring()
        do {
            let loadedEvents = try store.load()
            events = loadedEvents
            snapshot = AttentionSnapshot.replay(loadedEvents)
            lastError = nil
            isEventLogReadable = true
            runBackgroundMaintenance()
            return true
        } catch {
            // Drop the in-memory history along with the flag, exactly as `init`
            // does. Keeping it would leave writes that bypass `commit` holding a
            // stale history they could rebuild the unreadable file from.
            events = []
            snapshot = AttentionSnapshot()
            lastError = Self.unreadableLogMessage(error)
            isEventLogReadable = false
            LocalDiagnostics.shared.record(
                operation: "workspace.reload",
                message: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    func archiveConfiguredInbox(now: Date = Date()) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.inboxAutoArchiveEnabledKey) else { return 0 }
        let days = defaults.double(forKey: Self.inboxAutoArchiveDaysKey)
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-(days * 24 * 60 * 60))
        return archiveInbox(olderThan: cutoff, now: now)
    }

    func exportData(to url: URL) throws {
        let data = try store.encodedData(events: events)
        try data.write(to: url, options: .atomic)
    }

    func exportData() throws -> Data {
        try store.encodedData(events: events)
    }

    /// 删除全部本地数据。删什么、留什么由 `LocalDataErasure` 一处定义并由守门
    /// 测试核对——这里只负责按清单执行，以及把内存里的状态同步清空。
    @discardableResult
    func deleteAllData(defaults: UserDefaults = .standard) -> Bool {
        do {
            waitingCoordinator.cancelAllMonitoring()
            scheduledTaskCoordinator.cancelAllMonitoring()
            // 在录的直接丢弃（不 stop：stop 会往马上要删掉的日志里再写一笔）。
            if let activeRecordingID = recordingCoordinator.activeSessionID {
                recordingCoordinator.discard(activeRecordingID)
            }
            if FileManager.default.fileExists(atPath: store.fileURL.path) {
                try FileManager.default.removeItem(at: store.fileURL)
            }
            // Drop the in-memory history as soon as its file is gone. If a later
            // step fails, the next commit must not write the deleted events back.
            events = []
            snapshot = AttentionSnapshot()
            isEventLogReadable = true
            try assetStore.removeAll()
            let fileManager = FileManager.default
            // 数据根目录取自事件存储本身：位置可注入，照默认路径删会删到别处。
            let dataRoot = store.fileURL.deletingLastPathComponent()
            for url in LocalDataErasure.fileURLs(in: dataRoot)
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try? ExternalEventStore().removeAll()
            for key in LocalDataErasure.erasableUserDefaultsKeys {
                defaults.removeObject(forKey: key)
            }
            // 云端凭据住在保留下来的偏好 blob 里，单独抹。
            IntelligencePreferences.eraseCloudConfiguration(in: defaults)
            intelligencePreferences = .load(from: defaults)
            LocalDiagnostics.shared.removeAllData()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            LocalDiagnostics.shared.record(operation: "workspace.commit", message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func createTarget(
        name: String,
        note: String = "",
        environmentProfileID: UUID? = nil,
        now: Date = Date()
    ) -> AttentionTarget? {
        let target = AttentionTarget(
            name: name,
            note: note,
            createdAt: now,
            updatedAt: now,
            environmentProfileID: environmentProfileID
        )
        guard target.isValid else { return nil }
        guard commit([.targetChanged(target, at: now)]) else { return nil }
        return target
    }

    @discardableResult
    func updateTarget(
        _ targetID: UUID,
        name: String,
        note: String,
        environmentProfileID: UUID?,
        now: Date = Date()
    ) -> Bool {
        guard let target = snapshot.targets[targetID] else { return false }
        let updatedTarget = AttentionTarget(
            id: target.id,
            name: name,
            note: note,
            createdAt: target.createdAt,
            updatedAt: now,
            environmentProfileID: environmentProfileID
        )
        guard updatedTarget.isValid else { return false }
        return commit([.targetChanged(updatedTarget, at: now)])
    }

    @discardableResult
    func createEnvironment(
        name: String,
        actions: [EnvironmentAction] = [],
        allowedApplicationBundleIdentifiers: Set<String> = [],
        now: Date = Date()
    ) -> EnvironmentProfile? {
        let environment = EnvironmentProfile(
            name: name,
            actions: actions,
            allowedApplicationBundleIdentifiers: allowedApplicationBundleIdentifiers
        )
        guard !environment.name.isEmpty else { return nil }
        guard commit([.environmentChanged(environment, at: now)]) else { return nil }
        return environment
    }

    @discardableResult
    func updateEnvironment(
        _ environmentID: UUID,
        name: String,
        actions: [EnvironmentAction],
        allowedApplicationBundleIdentifiers: Set<String> = [],
        now: Date = Date()
    ) -> Bool {
        guard snapshot.environments[environmentID] != nil else { return false }
        let environment = EnvironmentProfile(
            id: environmentID,
            name: name,
            actions: actions,
            allowedApplicationBundleIdentifiers: allowedApplicationBundleIdentifiers
        )
        guard !environment.name.isEmpty else { return false }
        return commit([.environmentChanged(environment, at: now)])
    }

    /// 这件事还没结束的那一段（放下 / 等待中）：回到一件事时接着做它。
    /// 后台段（Agent/终端自动等待的中枢）不算「你在做的事」。
    func unfinishedEpisode(for targetID: UUID) -> AttentionEpisode? {
        snapshot.episodes.values
            .filter { $0.targetID == targetID && $0.state != .ended && !$0.isBackground }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.startedAt > $1.startedAt
            }
            .first
    }

    /// 「我现在做这件事」：同一件事若还有没结束的那一段，**接着做那一段**，
    /// 不新开。否则每次回到一件事都会多出一段：累计段数虚增，上一段的现场
    /// 与「回来先看」被丢在旁边成孤儿，界面上还永远显示「进行中」。
    @discardableResult
    func startEpisode(
        targetID: UUID,
        context: ContextCapsule = ContextCapsule(),
        returnCue: String = "",
        now: Date = Date()
    ) -> AttentionEpisode? {
        guard snapshot.targets[targetID] != nil else { return nil }

        let previousEpisode = currentEpisode
        let resumable = unfinishedEpisode(for: targetID)
        var events: [AttentionEvent] = []
        var transitionNotifications: [WaitingItem] = []
        var shouldCapturePreviousScene = false
        for waiting in snapshot.readyWaitingItems
            where waiting.restorePolicy == .nextTransition && !waiting.notificationSent {
            var notifiedWaiting = waiting
            notifiedWaiting.notificationSent = true
            events.append(.waitingChanged(notifiedWaiting, at: now))
            transitionNotifications.append(notifiedWaiting)
        }
        // 手上那件放下并存现场——除非要接着做的就是它本身。
        if let currentEpisode,
           currentEpisode.id != resumable?.id,
           currentEpisode.state != .ended,
           currentEpisode.state != .paused {
            var paused = currentEpisode
            if currentEpisode.state == .active || currentEpisode.state == .returning {
                paused.context = boundaryContext(for: currentEpisode, at: now)
            }
            paused.state = .paused
            paused.updatedAt = now
            events.append(.episodeChanged(paused, at: now))
            shouldCapturePreviousScene = true
        }

        let episode: AttentionEpisode
        if var resumed = resumable {
            // 接着做：这一段原有的现场、回来先看和累计专注全部留着。
            resumed.state = .active
            resumed.isBackground = false
            resumed.updatedAt = now
            if context.hasSceneContent { resumed.context = context }
            let trimmedCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCue.isEmpty { resumed.returnCue = trimmedCue }
            episode = resumed
        } else {
            var initialContext = context
            if previousEpisode == nil, !context.hasSceneContent,
               !sceneCapturePreferences.isAutomaticCapturePaused {
                let captured = contextCapture(intelligencePreferences, sceneCapturePreferences)
                if captured.hasSceneContent {
                    initialContext = captured
                    initialContext.note = context.note
                }
            }
            episode = AttentionEpisode(
                targetID: targetID,
                startedAt: now,
                updatedAt: now,
                context: initialContext,
                returnCue: returnCue
            )
        }
        events.append(.episodeChanged(episode, at: now))
        guard commit(events) else { return nil }
        handleRecordingOnEpisodeStart(episode, now: now)
        // 回到某件事时，它旧的「已放下」确认卡就过时了。
        if recentSetAside?.targetID == targetID {
            recentSetAside = nil
        }
        // 切换目标时，为被暂停的 episode 自动捕获现场，并把结果亮给用户。
        if shouldCapturePreviousScene,
           let previousEpisode,
           previousEpisode.id != episode.id {
            scheduleSceneAutoCapture(for: previousEpisode.id, announcingSetAside: true)
        }
        #if os(macOS)
        transitionNotifications.forEach {
            WaitingNotificationService().notifyIfAllowed($0, isTransition: true)
        }
        #endif
        return episode
    }

    @discardableResult
    func updateContext(
        for episodeID: UUID,
        context: ContextCapsule,
        returnCue: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard var episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        episode.context = context
        if let returnCue {
            episode.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        episode.updatedAt = now
        return commit([.episodeChanged(episode, at: now)])
    }

    @discardableResult
    func pauseEpisode(
        _ episodeID: UUID,
        returnCue: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard var episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        if episode.state == .active || episode.state == .returning {
            episode.context = boundaryContext(for: episode, at: now)
        }
        episode.state = .paused
        episode.updatedAt = now
        if let returnCue {
            episode.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let changed = commit([.episodeChanged(episode, at: now)])
        if changed {
            handleRecordingOnEpisodePause(episodeID, now: now)
            scheduleSceneAutoCapture(for: episodeID, announcingSetAside: true)
        }
        return changed
    }

    @discardableResult
    func resumeEpisode(_ episodeID: UUID, now: Date = Date()) -> Bool {
        guard let episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        // 接着做这件事：它的「已放下」确认卡到此为止。
        if recentSetAside?.targetID == episode.targetID {
            recentSetAside = nil
        }
        let changed = changeEpisodeState(episodeID, state: .active, now: now)
        if changed {
            handleRecordingOnEpisodeResume(episodeID, now: now)
        }
        return changed
    }

    /// An ended target must not leave outstanding waits behind: they would keep
    /// counting in the sidebar, keep their detectors running, and their "返回"
    /// action would silently do nothing because the episode is gone.
    private func closeOutstandingWaitingEvents(
        for episodeID: UUID,
        detail: String,
        now: Date
    ) -> [AttentionEvent] {
        var events: [AttentionEvent] = []
        for var waiting in snapshot.waitingItems.values
            .filter({ $0.episodeID == episodeID && ($0.status == .waiting || $0.status == .ready) })
            .sorted(by: { $0.startedAt < $1.startedAt }) {
            waitingCoordinator.cancelMonitoring(waiting.id)
            let wasReady = waiting.status == .ready
            waiting.status = wasReady ? .resolved : .cancelled
            waiting.completedAt = waiting.completedAt ?? now
            if waiting.evidence.isEmpty { waiting.evidence = detail }
            events.append(.waitingChanged(waiting, at: now))
        }
        return events
    }

    @discardableResult
    func endEpisode(_ episodeID: UUID, now: Date = Date()) -> Bool {
        guard var episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        if episode.state == .active || episode.state == .returning {
            episode.context = boundaryContext(for: episode, at: now)
        }
        episode.state = .ended
        episode.endedAt = now
        episode.endedReason = .completed
        episode.updatedAt = now
        let committed = commit([
            .episodeChanged(episode, at: now)
        ] + closeOutstandingWaitingEvents(
            for: episodeID,
            detail: "目标已结束，不再等待这个结果。",
            now: now
        ))
        if committed {
            handleRecordingOnEpisodeEnd(episodeID, now: now)
            scheduleSceneAutoCapture(for: episodeID)
        }
        return committed
    }

    @discardableResult
    func abandonEpisode(_ episodeID: UUID, now: Date = Date()) -> Bool {
        guard var episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        if episode.state == .active || episode.state == .returning {
            episode.context = boundaryContext(for: episode, at: now)
        }
        episode.state = .ended
        episode.endedAt = now
        episode.endedReason = .abandoned
        episode.updatedAt = now
        let committed = commit([
            .episodeChanged(episode, at: now)
        ] + closeOutstandingWaitingEvents(
            for: episodeID,
            detail: "目标已放弃，不再等待这个结果。",
            now: now
        ))
        if committed {
            handleRecordingOnEpisodeEnd(episodeID, now: now)
            scheduleSceneAutoCapture(for: episodeID)
        }
        return committed
    }

    @discardableResult
    func captureText(
        _ text: String,
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        sourceURL: URL? = nil,
        destination: CaptureStatus = .inbox,
        now: Date = Date()
    ) -> CaptureItem? {
        capture(
            kind: .text,
            body: text,
            sourceURL: sourceURL,
            sourceApplication: sourceApplication,
            sourceWindowTitle: sourceWindowTitle,
            capturedAt: now,
            destination: destination
        )
    }

    @discardableResult
    func captureLink(
        _ url: URL,
        title: String? = nil,
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        destination: CaptureStatus = .inbox,
        now: Date = Date()
    ) -> CaptureItem? {
        capture(
            kind: .link,
            body: title ?? url.absoluteString,
            title: title,
            sourceURL: url,
            sourceApplication: sourceApplication,
            sourceWindowTitle: sourceWindowTitle,
            capturedAt: now,
            destination: destination
        )
    }

    /// 深链进来的链接直接落收件箱——收件箱本身就是不打断当前工作的缓冲。
    @discardableResult
    func routeIncomingLink(
        _ url: URL,
        title: String? = nil,
        now: Date = Date()
    ) -> Bool {
        captureLink(url, title: title, sourceApplication: "浏览器", now: now) != nil
    }

    @discardableResult
    func captureFileReference(
        _ url: URL,
        title: String? = nil,
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        destination: CaptureStatus = .inbox,
        now: Date = Date()
    ) -> CaptureItem? {
        capture(
            kind: .fileReference,
            body: title ?? url.lastPathComponent,
            title: title,
            sourceURL: url,
            sourceApplication: sourceApplication,
            sourceWindowTitle: sourceWindowTitle,
            capturedAt: now,
            destination: destination
        )
    }

    @discardableResult
    func captureScreenshot(
        data: Data,
        note: String = "",
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        destination: CaptureStatus = .inbox,
        now: Date = Date()
    ) -> CaptureItem? {
        capture(
            kind: .screenshot,
            body: note,
            title: "截图",
            assetData: data,
            assetFileExtension: "png",
            mimeType: "image/png",
            sourceApplication: sourceApplication,
            sourceWindowTitle: sourceWindowTitle,
            capturedAt: now,
            destination: destination
        )
    }

    @discardableResult
    func captureVoice(
        transcript: String,
        audioFileURL: URL,
        duration: TimeInterval,
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        destination: CaptureStatus = .inbox,
        now: Date = Date()
    ) -> CaptureItem? {
        capture(
            kind: .voice,
            body: transcript,
            title: "语音捕获",
            assetFileURL: audioFileURL,
            assetFileExtension: "m4a",
            mimeType: "audio/mp4",
            duration: duration,
            sourceApplication: sourceApplication,
            sourceWindowTitle: sourceWindowTitle,
            capturedAt: now,
            destination: destination
        )
    }

    @discardableResult
    func capture(
        kind: CaptureKind,
        body: String,
        title: String? = nil,
        sourceURL: URL? = nil,
        assetData: Data? = nil,
        assetFileURL: URL? = nil,
        assetFileExtension: String? = nil,
        mimeType: String? = nil,
        duration: TimeInterval? = nil,
        sourceApplication: String? = nil,
        sourceWindowTitle: String? = nil,
        capturedAt: Date = Date(),
        destination: CaptureStatus = .inbox
    ) -> CaptureItem? {
        var storedAssetURL: URL?
        do {
            if let assetData {
                storedAssetURL = try assetStore.save(
                    data: assetData,
                    fileExtension: assetFileExtension ?? "bin"
                )
            } else if let assetFileURL {
                storedAssetURL = try assetStore.copyItem(
                    at: assetFileURL,
                    fileExtension: assetFileExtension
                )
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        // 去向在落盘前就定：稍后（要做的事）或暂存箱（想法/链接留存）。
        let capture = CaptureItem(
            kind: kind,
            body: body,
            title: title,
            sourceURL: sourceURL,
            assetURL: storedAssetURL,
            mimeType: mimeType,
            duration: duration,
            sourceApplication: sourceApplication,
            sourceWindowTitle: sourceWindowTitle,
            capturedAt: capturedAt,
            status: destination == .reference ? .reference : .inbox
        )
        guard capture.isValid else {
            assetStore.removeIfPresent(at: storedAssetURL)
            return nil
        }
        guard commit([.captureChanged(capture, at: capturedAt)]) else {
            assetStore.removeIfPresent(at: storedAssetURL)
            return nil
        }
        recordingNote(
            kind: .capture,
            title: capture.kind.title,
            detail: String((capture.title ?? capture.body).prefix(60)),
            episodeID: currentEpisode?.id,
            now: capturedAt
        )
        scheduleCaptureTextExtraction(for: capture)
        scheduleInboxAutoOrganize(for: capture)
        return capture
    }

    // MARK: - 稍后处理箱自动整理（链接补标题、按域名归堆）

    private var organizingCaptureIDs: Set<UUID> = []
    /// 本次会话已尝试过的捕获（含失败），避免对同一条反复抓取。
    private var organizeAttemptedCaptureIDs: Set<UUID> = []

    private func scheduleInboxAutoOrganize(for capture: CaptureItem) {
        guard intelligencePreferences.inboxAutoOrganize,
              InboxAutoOrganizer.canOrganize(capture),
              !organizeAttemptedCaptureIDs.contains(capture.id),
              !organizingCaptureIDs.contains(capture.id),
              let url = capture.sourceURL
        else { return }
        organizingCaptureIDs.insert(capture.id)
        let needsTitle = InboxAutoOrganizer.needsTitle(capture)
        Task { @MainActor [weak self] in
            let fetchedTitle = needsTitle
                ? await InboxLinkTitleFetcher.fetchTitle(for: url)
                : nil
            guard let self else { return }
            self.organizingCaptureIDs.remove(capture.id)
            self.organizeAttemptedCaptureIDs.insert(capture.id)
            self.applyInboxOrganization(capture.id, fetchedTitle: fetchedTitle)
        }
    }

    /// 维护循环的回填入口：一次只整理一条，避免一开机就并发抓一堆网页。
    func backfillInboxOrganization() {
        guard intelligencePreferences.inboxAutoOrganize,
              organizingCaptureIDs.isEmpty else { return }
        let candidate = snapshot.captures.values
            .filter {
                InboxAutoOrganizer.canOrganize($0)
                    && !organizeAttemptedCaptureIDs.contains($0.id)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .first
        guard let candidate else { return }
        scheduleInboxAutoOrganize(for: candidate)
    }

    /// 落地整理结果：补标题（body 原来是裸 URL 时一并替换成标题）+ 域名标签。
    /// CaptureItem 的标题是不可变字段，整体重建同 ID 条目后提交。
    private func applyInboxOrganization(
        _ captureID: UUID,
        fetchedTitle: String?,
        now: Date = Date()
    ) {
        guard let capture = snapshot.captures[captureID],
              capture.status == .inbox,
              let url = capture.sourceURL
        else { return }

        var newTitle = capture.title
        var newBody = capture.body
        if let fetchedTitle, InboxAutoOrganizer.needsTitle(capture) {
            newTitle = fetchedTitle
            if capture.body == url.absoluteString {
                newBody = fetchedTitle
            }
        }
        var newTags = capture.tags
        if let hostTag = InboxAutoOrganizer.hostTag(for: url), !newTags.contains(hostTag) {
            newTags.append(hostTag)
        }
        guard newTitle != capture.title || newBody != capture.body || newTags != capture.tags
        else { return }

        let organized = CaptureItem(
            id: capture.id,
            kind: capture.kind,
            body: newBody,
            title: newTitle,
            sourceURL: capture.sourceURL,
            assetURL: capture.assetURL,
            mimeType: capture.mimeType,
            duration: capture.duration,
            sourceApplication: capture.sourceApplication,
            sourceWindowTitle: capture.sourceWindowTitle,
            capturedAt: capture.capturedAt,
            status: capture.status,
            attachedEpisodeID: capture.attachedEpisodeID,
            tags: CaptureItem.normalizedTags(newTags),
            extractedText: capture.extractedText,
            textExtractedAt: capture.textExtractedAt
        )
        _ = commit([.captureChanged(organized, at: now)])
    }

    // MARK: - 截图文字提取（检索用）

    private var extractingCaptureIDs: Set<UUID> = []

    /// 截图入库后异步做本机 OCR；旧截图由维护循环每次补一张。
    private func scheduleCaptureTextExtraction(for capture: CaptureItem) {
        guard capture.kind == .screenshot,
              let assetURL = capture.assetURL,
              capture.textExtractedAt == nil,
              !extractingCaptureIDs.contains(capture.id)
        else { return }
        extractingCaptureIDs.insert(capture.id)
        Task { @MainActor [weak self] in
            let text = await CaptureTextExtractor.extractText(from: assetURL)
            guard let self else { return }
            self.extractingCaptureIDs.remove(capture.id)
            self.setCaptureExtractedText(capture.id, text: text)
        }
    }

    /// 维护循环的回填入口：一次只补一张，避免刚启动就吃满 CPU。
    func backfillCaptureText() {
        guard extractingCaptureIDs.isEmpty else { return }
        let candidate = snapshot.captures.values
            .filter { $0.kind == .screenshot && $0.assetURL != nil && $0.textExtractedAt == nil }
            .sorted { $0.capturedAt > $1.capturedAt }
            .first
        guard let candidate else { return }
        scheduleCaptureTextExtraction(for: candidate)
    }

    @discardableResult
    func setCaptureExtractedText(
        _ captureID: UUID,
        text: String?,
        now: Date = Date()
    ) -> Bool {
        guard var capture = snapshot.captures[captureID] else { return false }
        capture.extractedText = text ?? ""
        // 记下尝试时间：没识别出内容的截图不再反复重试。
        capture.textExtractedAt = now
        return commit([.captureChanged(capture, at: now)])
    }

    /// 把资料（或已归档的内容）转回收件箱重新决定去向。
    @discardableResult
    func moveCaptureToInbox(_ captureID: UUID, now: Date = Date()) -> Bool {
        guard var capture = snapshot.captures[captureID],
              capture.status == .reference || capture.status == .archived
        else { return false }
        capture.status = .inbox
        return commit([.captureChanged(capture, at: now)])
    }

    @discardableResult
    func archiveCapture(_ captureID: UUID, now: Date = Date()) -> Bool {
        guard var capture = snapshot.captures[captureID], capture.status != .archived else {
            return false
        }
        capture.status = .archived
        return commit([.captureArchived(capture, at: now)])
    }

    @discardableResult
    func saveCaptureAsReference(_ captureID: UUID, now: Date = Date()) -> Bool {
        guard var capture = snapshot.captures[captureID],
              capture.status == .inbox || capture.status == .attached
        else { return false }
        capture.status = .reference
        return commit([.captureChanged(capture, at: now)])
    }

    /// 替换一条捕获的标签（会做规范化：去 #、去空、去重）。
    @discardableResult
    func setCaptureTags(_ captureID: UUID, tags: [String], now: Date = Date()) -> Bool {
        guard var capture = snapshot.captures[captureID] else { return false }
        let normalized = CaptureItem.normalizedTags(tags)
        guard capture.tags != normalized else { return true }
        capture.tags = normalized
        return commit([.captureChanged(capture, at: now)])
    }

    @discardableResult
    func createTargetFromCapture(
        _ captureID: UUID,
        name: String? = nil,
        note: String = "",
        environmentProfileID: UUID? = nil,
        now: Date = Date()
    ) -> AttentionTarget? {
        guard let capture = snapshot.captures[captureID], capture.status == .inbox else {
            return nil
        }
        let requestedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedName = requestedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? capture.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? capture.body.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "新注意力目标"
        let target = AttentionTarget(
            name: suggestedName,
            note: note.isEmpty ? "从稍后处理箱开始。" : note,
            createdAt: now,
            updatedAt: now,
            environmentProfileID: environmentProfileID
        )
        guard target.isValid else { return nil }

        let previousEpisode = currentEpisode
        var shouldCapturePreviousScene = false
        var events: [AttentionEvent] = [.targetChanged(target, at: now)]
        var transitionNotifications: [WaitingItem] = []
        for waiting in snapshot.readyWaitingItems
            where waiting.restorePolicy == .nextTransition && !waiting.notificationSent {
            var notifiedWaiting = waiting
            notifiedWaiting.notificationSent = true
            events.append(.waitingChanged(notifiedWaiting, at: now))
            transitionNotifications.append(notifiedWaiting)
        }
        // 与 startEpisode 同一条不变量：任何激活新一段的入口，都要把手上那件
        // 先固定现场再放下。`.returning`（刚回场、还没接着做）也是手上那件——
        // 漏掉它会留下一段永远停在回场态、却已经不是当前工作的孤儿。
        if let previousEpisode,
           previousEpisode.state != .ended,
           previousEpisode.state != .paused {
            var paused = previousEpisode
            if previousEpisode.state == .active || previousEpisode.state == .returning {
                paused.context = boundaryContext(for: previousEpisode, at: now)
            }
            paused.state = .paused
            paused.updatedAt = now
            events.append(.episodeChanged(paused, at: now))
            shouldCapturePreviousScene = true
        }

        let episode = AttentionEpisode(
            targetID: target.id,
            startedAt: now,
            updatedAt: now
        )
        events.append(.episodeChanged(episode, at: now))
        var attachedCapture = capture
        attachedCapture.status = .attached
        attachedCapture.attachedEpisodeID = episode.id
        events.append(.captureChanged(attachedCapture, at: now))
        guard commit(events) else { return nil }

        // 被放下的那一段异步存一张现场快照，并把结果亮给用户（同 startEpisode）。
        if shouldCapturePreviousScene, let previousEpisode {
            scheduleSceneAutoCapture(for: previousEpisode.id, announcingSetAside: true)
        }
        #if os(macOS)
        transitionNotifications.forEach {
            WaitingNotificationService().notifyIfAllowed($0, isTransition: true)
        }
        #endif
        return target
    }

    @discardableResult
    func beginWaitingFromCapture(
        _ captureID: UUID,
        episodeID: UUID? = nil,
        kind: WaitingKind = .manual,
        completionCondition: String = "用户确认已到达",
        restorePolicy: WaitingRestorePolicy = .manual,
        monitor: WaitingMonitorConfiguration? = nil,
        now: Date = Date()
    ) -> WaitingItem? {
        guard let capture = snapshot.captures[captureID], capture.status == .inbox,
              let episodeID = episodeID ?? currentEpisode?.id,
              var episode = snapshot.episodes[episodeID],
              episode.state != .ended
        else { return nil }
        let description = capture.title?.isEmpty == false
            ? capture.title!
            : capture.body
        let waiting = WaitingItem(
            episodeID: episodeID,
            kind: kind,
            description: description,
            completionCondition: completionCondition,
            startedAt: now,
            restorePolicy: restorePolicy,
            monitor: monitor,
            originalContext: episode.context
        )
        guard waiting.isValid else { return nil }
        episode.state = .waiting
        episode.updatedAt = now
        episode.waitingIDs.append(waiting.id)
        var archivedCapture = capture
        archivedCapture.status = .archived
        guard commit([
            .episodeChanged(episode, at: now),
            .waitingChanged(waiting, at: now),
            .captureArchived(archivedCapture, at: now)
        ]) else { return nil }
        if let persistedWaiting = snapshot.waitingItems[waiting.id] {
            waitingCoordinator.startMonitoring(persistedWaiting)
        }
        return waiting
    }

    @discardableResult
    func archiveInbox(
        olderThan cutoff: Date,
        now: Date = Date()
    ) -> Int {
        let staleCaptures = snapshot.inbox.filter { $0.capturedAt < cutoff }
        guard !staleCaptures.isEmpty else { return 0 }
        let events = staleCaptures.map { capture -> AttentionEvent in
            var archived = capture
            archived.status = .archived
            return .captureArchived(archived, at: now)
        }
        guard commit(events) else { return 0 }
        return staleCaptures.count
    }

    @discardableResult
    func deleteCapture(_ captureID: UUID) -> Bool {
        guard let capture = snapshot.captures[captureID] else { return false }
        guard isEventLogReadable else {
            lastError = Self.unreadableLogRefusalMessage
            return false
        }
        let retainedEvents = events.filter { event in
            !(event.entityID == captureID &&
                (event.kind == .captureChanged || event.kind == .captureArchived))
        }

        do {
            try store.save(events: retainedEvents)
            events = retainedEvents
            snapshot = AttentionSnapshot.replay(retainedEvents)
            assetStore.removeIfPresent(at: capture.assetURL)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func beginWaiting(
        episodeID: UUID,
        kind: WaitingKind,
        description: String,
        completionCondition: String = "",
        restorePolicy: WaitingRestorePolicy = .manual,
        monitor: WaitingMonitorConfiguration? = nil,
        timeoutAt: Date? = nil,
        now: Date = Date()
    ) -> WaitingItem? {
        guard var episode = snapshot.episodes[episodeID],
              episode.state != .ended
        else { return nil }

        if episode.state == .active || episode.state == .returning {
            episode.context = boundaryContext(for: episode, at: now)
        }

        var configuredMonitor = monitor
        if configuredMonitor?.kind == .event {
            var eventMonitor = configuredMonitor!
            eventMonitor.eventAfter = eventMonitor.eventAfter ?? now
            configuredMonitor = eventMonitor
        }

        let waiting = WaitingItem(
            episodeID: episodeID,
            kind: kind,
            description: description,
            completionCondition: completionCondition,
            startedAt: now,
            restorePolicy: restorePolicy,
            monitor: configuredMonitor,
            timeoutAt: timeoutAt,
            originalContext: episode.context
        )
        guard waiting.isValid else { return nil }

        episode.state = .waiting
        episode.updatedAt = now
        episode.waitingIDs.append(waiting.id)
        guard commit([
            .episodeChanged(episode, at: now),
            .waitingChanged(waiting, at: now)
        ]) else { return nil }
        if let persistedWaiting = snapshot.waitingItems[waiting.id] {
            waitingCoordinator.startMonitoring(persistedWaiting)
        }
        recordingNote(
            kind: .waiting,
            title: waiting.description,
            detail: tr("recording_wait_started"),
            episodeID: episodeID,
            now: now
        )
        handleRecordingOnEpisodePause(episodeID, now: now)
        // 开始等待时自动捕获现场，作为可返回时的「一键重返」内容
        scheduleSceneAutoCapture(for: episodeID)
        return waiting
    }

    @discardableResult
    func completeWaiting(
        _ waitingID: UUID,
        evidence: String,
        now: Date = Date()
    ) -> Bool {
        guard var waiting = snapshot.waitingItems[waitingID], waiting.status == .waiting else {
            return false
        }
        waiting.status = .ready
        waiting.completedAt = now
        waiting.evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        if waiting.restorePolicy == .notify {
            waiting.notificationSent = true
        }
        waitingCoordinator.cancelMonitoring(waitingID)
        let committed = commit([
            .waitingChanged(waiting, at: now)
        ])
        #if os(macOS)
        if committed { WaitingNotificationService().notifyIfAllowed(waiting) }
        #endif
        if committed {
            recordingNote(
                kind: .waiting,
                title: waiting.description,
                detail: waiting.evidence,
                episodeID: waiting.episodeID,
                now: now
            )
        }
        return committed
    }

    @discardableResult
    func cancelWaiting(_ waitingID: UUID, evidence: String = "", now: Date = Date()) -> Bool {
        guard var waiting = snapshot.waitingItems[waitingID], waiting.status == .waiting else {
            return false
        }
        waiting.status = .cancelled
        waiting.completedAt = now
        waiting.evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        waitingCoordinator.cancelMonitoring(waitingID)
        var events: [AttentionEvent] = [
            .waitingChanged(waiting, at: now)
        ]
        if var episode = snapshot.episodes[waiting.episodeID], episode.state == .waiting {
            episode.state = .paused
            episode.updatedAt = now
            events.append(.episodeChanged(episode, at: now))
        }
        return commit(events)
    }

    @discardableResult
    func timeoutWaiting(_ waitingID: UUID, now: Date = Date()) -> Bool {
        cancelWaiting(waitingID, evidence: "超过等待截止时间。", now: now)
    }

    func startActiveWaitingMonitors() {
        waitingCoordinator.startMonitoringActiveWaits()
    }

    @discardableResult
    func resumeWaitingEpisode(_ waitingID: UUID, now: Date = Date()) -> Bool {
        guard let waiting = snapshot.waitingItems[waitingID], waiting.status == .ready,
              var episode = snapshot.episodes[waiting.episodeID],
              episode.state != .ended
        else { return false }

        var resolvedWaiting = waiting
        resolvedWaiting.status = .resolved
        episode.isBackground = false
        episode.state = .active
        episode.updatedAt = now
        guard commit([
            .waitingChanged(resolvedWaiting, at: now),
            .episodeChanged(episode, at: now)
        ]) else { return false }
        handleRecordingOnEpisodeResume(episode.id, now: now)
        return true
    }

    @discardableResult
    func dismissWaitingResult(_ waitingID: UUID, now: Date = Date()) -> Bool {
        guard var waiting = snapshot.waitingItems[waitingID], waiting.status == .ready else {
            return false
        }
        waiting.status = .cancelled
        waiting.evidence = "用户标记为无关。"
        waiting.completedAt = waiting.completedAt ?? now
        return commit([
            .waitingChanged(waiting, at: now)
        ])
    }

    // MARK: - 自动等待（Agent / 终端事件）

    /// 确认一个就绪的等待结果，但不切换当前工作、不恢复现场——
    /// 自动等待（Agent 回合、终端命令）的「知道了」。
    @discardableResult
    func acknowledgeWaitingResult(_ waitingID: UUID, now: Date = Date()) -> Bool {
        guard var waiting = snapshot.waitingItems[waitingID], waiting.status == .ready else {
            return false
        }
        waiting.status = .resolved
        var newEvents: [AttentionEvent] = [.waitingChanged(waiting, at: now)]
        if var episode = snapshot.episodes[waiting.episodeID],
           episode.isBackground,
           episode.state == .waiting {
            episode.state = .paused
            episode.updatedAt = now
            newEvents.append(.episodeChanged(episode, at: now))
        }
        return commit(newEvents)
    }

    /// 把一条 Agent / 终端来源的外部事件应用到自动等待上。所有状态时刻都
    /// 取事件自身的 occurredAt——这让重启后从头重放整个收件箱也收敛到同一状态。
    func applyAutoWaitEvent(_ event: ExternalEvent) {
        guard !event.correlationID.isEmpty,
              AutoWaitHub.descriptor(for: event.source) != nil
        else { return }

        // 这个 correlationID 已有用户声明的（非自动）等待：让它的检测器处理。
        let declaredElsewhere = snapshot.waitingItems.values.contains {
            $0.monitor?.eventCorrelationID == event.correlationID
                && $0.monitor?.eventAutoManaged != true
        }
        guard !declaredElsewhere else { return }

        let existing = snapshot.waitingItems.values
            .filter {
                $0.monitor?.eventAutoManaged == true
                    && $0.monitor?.eventCorrelationID == event.correlationID
            }
            .sorted { $0.startedAt > $1.startedAt }
            .first

        switch event.kind {
        case .started:
            if let existing {
                reopenAutoWait(existing, for: event)
            } else {
                _ = createAutoWait(for: event)
            }

        case .progress:
            // 目前的生产者不发进度；忽略，避免每次轮询都写事件日志。
            break

        case .completed, .failed:
            if let existing {
                if existing.status == .waiting {
                    _ = completeWaiting(existing.id, evidence: event.evidence, now: event.occurredAt)
                } else if event.occurredAt > (existing.completedAt ?? existing.startedAt) {
                    // 只报完成、不报开始的工具（如 Codex 的 notify 只有
                    // agent-turn-complete）：更新的完成事件是新一轮结果——
                    // 重开同一项等待并立即就绪，而不是悄悄丢掉。
                    reopenAutoWait(existing, for: event)
                    if snapshot.waitingItems[existing.id]?.status == .waiting {
                        _ = completeWaiting(existing.id, evidence: event.evidence, now: event.occurredAt)
                    }
                }
            } else if let created = createAutoWait(for: event) {
                // 等待开始前应用不在运行（或探针没来得及发 started）：
                // 补一个已完成的结果，长命令跑完的事实仍然值得出现。
                _ = completeWaiting(created.id, evidence: event.evidence, now: event.occurredAt)
            }

        case .cancelled:
            guard let existing, existing.status == .waiting else { return }
            _ = cancelWaiting(existing.id, evidence: event.evidence, now: event.occurredAt)
        }
    }

    @discardableResult
    private func createAutoWait(for event: ExternalEvent) -> WaitingItem? {
        guard let hub = AutoWaitHub.descriptor(for: event.source) else { return nil }
        let title = event.title.isEmpty ? hub.fallbackTitle : event.title
        var newEvents: [AttentionEvent] = []

        if snapshot.targets[hub.targetID] == nil {
            newEvents.append(.targetChanged(
                AttentionTarget(
                    id: hub.targetID,
                    name: hub.name,
                    note: hub.note,
                    createdAt: event.occurredAt,
                    updatedAt: event.occurredAt
                ),
                at: event.occurredAt
            ))
        }

        let waitingID = UUID()
        let episode = AttentionEpisode(
            targetID: hub.targetID,
            startedAt: event.occurredAt,
            updatedAt: event.occurredAt,
            state: .waiting,
            isBackground: true,
            returnCue: title,
            waitingIDs: [waitingID]
        )
        let waiting = WaitingItem(
            id: waitingID,
            episodeID: episode.id,
            kind: hub.waitingKind,
            description: title,
            completionCondition: event.detail,
            startedAt: event.occurredAt,
            restorePolicy: .notify,
            monitor: WaitingMonitorConfiguration(
                kind: .event,
                eventCorrelationID: event.correlationID,
                eventSources: [event.source],
                eventAutoManaged: true
            )
        )
        newEvents.append(.episodeChanged(episode, at: event.occurredAt))
        newEvents.append(.waitingChanged(waiting, at: event.occurredAt))
        guard commit(newEvents) else { return nil }
        return snapshot.waitingItems[waitingID]
    }

    private func reopenAutoWait(_ existing: WaitingItem, for event: ExternalEvent) {
        switch existing.status {
        case .waiting:
            // 已在等待：至多把标题换成最新回合的。
            guard !event.title.isEmpty, event.title != existing.description else { return }
            var updated = existing
            updated.description = event.title
            _ = commit([.waitingChanged(updated, at: event.occurredAt)])

        case .ready, .resolved, .cancelled:
            // 只有比上次收尾更新的 started 才重开——重放旧日志不会翻旧账。
            guard event.occurredAt > (existing.completedAt ?? existing.startedAt) else { return }
            var reopened = existing
            reopened.status = .waiting
            reopened.completedAt = nil
            reopened.evidence = ""
            if !event.title.isEmpty {
                reopened.description = event.title
            }
            var newEvents: [AttentionEvent] = [.waitingChanged(reopened, at: event.occurredAt)]
            if var episode = snapshot.episodes[existing.episodeID], episode.state != .ended {
                episode.state = .waiting
                episode.updatedAt = event.occurredAt
                newEvents.append(.episodeChanged(episode, at: event.occurredAt))
            }
            _ = commit(newEvents)
        }
    }

    private func changeEpisodeState(
        _ episodeID: UUID,
        state: AttentionEpisodeState,
        returnCue: String? = nil,
        now: Date
    ) -> Bool {
        guard var episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        episode.state = state
        episode.updatedAt = now
        if let returnCue {
            episode.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return commit([
            .episodeChanged(episode, at: now)
        ])
    }

    /// 在状态切换前同步固定一次桌面事实。自动记录暂停或读取不到内容时，
    /// 保留上一次上下文，不用空观察覆盖可恢复的现场。
    private func boundaryContext(for episode: AttentionEpisode, at now: Date) -> ContextCapsule {
        guard !sceneCapturePreferences.isAutomaticCapturePaused else { return episode.context }
        // 调用方刚刚提供或手动刷新过的上下文本身就是这个边界的观察；
        // 不立刻再读一遍桌面，也避免用稍后到达的无关窗口覆盖它。
        if episode.context.hasSceneContent,
           abs(now.timeIntervalSince(episode.context.capturedAt)) < 1 {
            return episode.context
        }
        var captured = contextCapture(intelligencePreferences, sceneCapturePreferences)
        guard captured.hasSceneContent else { return episode.context }
        captured.note = episode.context.note
        return captured
    }

    // MARK: - 定时任务

    /// 新建定时任务。`collectSceneOnFire` 打开时，每次到点收集触发那一刻的
    /// 现场检查点（与当时在做什么无关）。
    @discardableResult
    func createScheduledTask(
        title: String,
        note: String = "",
        fireAt: Date,
        repeatRule: ScheduledTaskRepeatRule = .once,
        collectSceneOnFire: Bool = false,
        calendarEventID: String? = nil,
        calendarEventTitle: String? = nil,
        now: Date = Date()
    ) -> ScheduledTask? {
        let task = ScheduledTask(
            title: title,
            note: note,
            fireAt: fireAt,
            repeatRule: repeatRule,
            collectSceneOnFire: collectSceneOnFire,
            calendarEventID: calendarEventID,
            calendarEventTitle: calendarEventTitle,
            createdAt: now,
            updatedAt: now
        )
        guard task.isValid, commit([.scheduledTaskChanged(task, at: now)]) else { return nil }
        if let persisted = snapshot.scheduledTasks[task.id] {
            scheduledTaskCoordinator.startMonitoring(persisted, now: now)
        }
        return snapshot.scheduledTasks[task.id]
    }

    /// 编辑定时任务（时间、重复、标题等）。时间变了协调器会换检测器。
    @discardableResult
    func updateScheduledTask(_ task: ScheduledTask, now: Date = Date()) -> Bool {
        guard snapshot.scheduledTasks[task.id] != nil, task.isValid else { return false }
        var updated = task
        updated.updatedAt = now
        guard commit([.scheduledTaskChanged(updated, at: now)]) else { return false }
        scheduledTaskCoordinator.startMonitoring(updated, now: now)
        return true
    }

    @discardableResult
    func deleteScheduledTask(_ taskID: UUID, now: Date = Date()) -> Bool {
        guard snapshot.scheduledTasks[taskID] != nil else { return false }
        scheduledTaskCoordinator.cancelMonitoring(taskID)
        return commit([.scheduledTaskDeleted(id: taskID, at: now)])
    }

    /// 提前完成：不等到点，直接把任务收进历史（重复任务也整个结束）。
    @discardableResult
    func completeScheduledTask(_ taskID: UUID, now: Date = Date()) -> Bool {
        guard var task = snapshot.scheduledTasks[taskID], task.status == .scheduled else {
            return false
        }
        task.status = .done
        task.updatedAt = now
        scheduledTaskCoordinator.cancelMonitoring(taskID)
        return commit([.scheduledTaskChanged(task, at: now)])
    }

    /// 应用重新打开时跳过已经错过的场次：不补通知、不收现场、不写触发历史。
    /// 单次任务直接结束，重复任务滚到严格晚于启动时刻的下一场。
    @discardableResult
    func skipMissedScheduledTask(_ taskID: UUID, now: Date = Date()) -> ScheduledTask? {
        guard var task = snapshot.scheduledTasks[taskID],
              task.status == .scheduled,
              task.fireAt <= now
        else { return snapshot.scheduledTasks[taskID] }

        if let next = task.repeatRule.nextFireDate(
            after: now,
            previous: task.fireAt
        ) {
            task.fireAt = next
        } else {
            task.status = .done
        }
        task.updatedAt = now
        guard commit([.scheduledTaskChanged(task, at: now)]) else { return nil }
        return snapshot.scheduledTasks[taskID]
    }

    /// 到点：落一条触发记录、发系统通知；重复任务滚到下一场并继续盯，
    /// 单次任务就此完成。要收检查点的，异步收好后补挂到触发记录上。
    /// 由 ScheduledTaskCoordinator 调用。
    func fireScheduledTask(_ taskID: UUID, now: Date = Date()) {
        guard let task = snapshot.scheduledTasks[taskID],
              task.status == .scheduled,
              now >= task.fireAt
        else { return }
        let rolled = task.firing(at: now)
        let fire = ScheduledTaskFire(taskID: task.id, taskTitle: task.title, firedAt: task.fireAt)
        guard commit([
            .scheduledTaskChanged(rolled, at: now),
            .scheduledFireChanged(fire, at: now)
        ]) else { return }
        #if os(macOS)
        ScheduledTaskNotificationService().notifyFired(rolled, firedAt: now)
        #endif
        if let persisted = snapshot.scheduledTasks[taskID], persisted.status == .scheduled {
            scheduledTaskCoordinator.startMonitoring(persisted)
        }
        if task.collectSceneOnFire {
            attachCheckpointScene(to: fire.id)
        }
    }

    /// 收一份现场检查点：触发那一刻屏幕上的一切，与目标无关。
    /// 不做 AI 相关性筛选（没有目标可参照）、不生成回场线索，全部保留；
    /// 隐私排除规则照常在读取时生效。
    @discardableResult
    func captureCheckpointScene(now: Date = Date()) async -> SceneSnapshot? {
        let capsule = contextCapture(intelligencePreferences, sceneCapturePreferences)
        guard capsule.hasSceneContent else { return nil }
        let scene = await SceneSnapshotBuilder.buildSnapshot(
            from: capsule,
            targetID: nil,
            targetName: "",
            targetNote: "",
            filterMode: .saveAll,
            engine: intelligenceEngine,
            generateReturnCue: false
        )
        guard commit([.sceneSnapshotChanged(scene, at: now)]) else { return nil }
        return snapshot.sceneSnapshots[scene.id]
    }

    /// 异步收检查点并挂到触发记录上。fire 在采集期间被清掉就当没收到。
    private func attachCheckpointScene(to fireID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            guard let scene = await self.captureCheckpointScene() else { return }
            let now = Date()
            guard var fire = self.snapshot.scheduledFires[fireID] else { return }
            fire.sceneSnapshotID = scene.id
            _ = self.commit([.scheduledFireChanged(fire, at: now)])
        }
    }

    // MARK: - 过程记录

    /// 主动录制一个过程（不依赖当前工作）。标题留空时用时刻起名。
    @discardableResult
    func startManualRecording(title: String = "", now: Date = Date()) -> RecordingSession? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(
            format: tr("recording_started_at_time"),
            now.formatted(date: .omitted, time: .shortened)
        )
        return recordingCoordinator.start(
            title: trimmed.isEmpty ? fallback : trimmed,
            now: now
        )
    }

    /// 给当前这件事录一份过程（单次开启；生命周期跟随 episode）。
    @discardableResult
    func startRecordingCurrentEpisode(now: Date = Date()) -> RecordingSession? {
        guard let episode = currentEpisode,
              let target = snapshot.targets[episode.targetID]
        else { return nil }
        let session = recordingCoordinator.start(
            title: target.name,
            targetID: target.id,
            episodeID: episode.id,
            autoFollowed: true,
            now: now
        )
        recordingCoordinator.note(
            kind: .episode,
            title: String(format: tr("recording_episode_started"), target.name),
            at: now
        )
        return session
    }

    @discardableResult
    func stopRecording(now: Date = Date()) -> RecordingSession? {
        recordingCoordinator.stop(now: now)
    }

    var activeRecordingSession: RecordingSession? {
        snapshot.activeRecordingSession
    }

    /// 会话的 trace 条目（详情页与成稿生成用）。
    func recordingEntries(for sessionID: UUID) -> [RecordingEntry] {
        recordingTraceStore.load(for: sessionID)
    }

    /// 改标题/手改成稿（状态流转归协调器管，这里不碰 status）。
    @discardableResult
    func updateRecordingSession(
        _ sessionID: UUID,
        title: String? = nil,
        markdown: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard var session = snapshot.recordingSessions[sessionID] else { return false }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { session.title = trimmed }
        }
        if let markdown {
            session.markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        session.updatedAt = now
        return commit([.recordingSessionChanged(session, at: now)])
    }

    @discardableResult
    func deleteRecordingSession(_ sessionID: UUID, now: Date = Date()) -> Bool {
        guard snapshot.recordingSessions[sessionID] != nil else { return false }
        recordingCoordinator.discard(sessionID)
        return commit([.recordingSessionDeleted(id: sessionID, at: now)])
    }

    /// AI 整理：把 trace 事实行交给当前引擎生成成稿并存回。
    /// 失败把错误原样亮出来（lastError），不做冒名降级。
    @discardableResult
    func composeRecordingMarkdown(
        _ sessionID: UUID,
        style: RecordingStyle
    ) async -> RecordingSession? {
        guard let session = snapshot.recordingSessions[sessionID] else { return nil }
        let entries = recordingEntries(for: sessionID)
        guard !entries.isEmpty else {
            lastError = tr("this_recording_has_no_entries")
            return nil
        }
        let engine = intelligenceEngine
        do {
            let markdown = try await engine.composeRecordMarkdown(RecordComposeInput(
                title: session.title,
                style: style,
                factLines: entries.map { $0.factLine() }
            ))
            let now = Date()
            guard var updated = snapshot.recordingSessions[sessionID] else { return nil }
            updated.style = style
            updated.markdown = markdown
            updated.composedBy = engine.name
            updated.updatedAt = now
            guard commit([.recordingSessionChanged(updated, at: now)]) else { return nil }
            return snapshot.recordingSessions[sessionID]
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// 协调器的元数据落盘入口（事件日志的唯一写入口在 commit）。
    @discardableResult
    func persistRecordingSession(_ session: RecordingSession, at now: Date) -> Bool {
        commit([.recordingSessionChanged(session, at: now)])
    }

    #if DEBUG
    /// 测试后门：往在录会话里塞一条事实（相邻去重逻辑的单测入口）。
    func noteRecordingFactForTesting(
        kind: RecordingEntryKind,
        title: String,
        detail: String = ""
    ) {
        recordingCoordinator.note(kind: kind, title: title, detail: detail)
    }
    #endif

    /// 给在录的会话记一条生命周期事实。跟随工作的会话只记自己那段 episode 的事；
    /// 主动录制的会话什么都记（它录的就是「这台机器上正在发生的过程」）。
    private func recordingNote(
        kind: RecordingEntryKind,
        title: String,
        detail: String = "",
        episodeID: UUID?,
        now: Date
    ) {
        guard let active = snapshot.activeRecordingSession else { return }
        if active.autoFollowed, let episodeID, active.episodeID != episodeID { return }
        recordingCoordinator.note(kind: kind, title: title, detail: detail, at: now)
    }

    /// episode 生命周期对录制的驱动：跟随中的会话随它暂停/继续/收尾；
    /// 全局自动录制打开时，新开始的事自动起一份。
    private func handleRecordingOnEpisodeStart(
        _ episode: AttentionEpisode,
        now: Date
    ) {
        if let active = snapshot.activeRecordingSession, active.autoFollowed {
            if active.episodeID == episode.id {
                recordingCoordinator.note(
                    kind: .episode,
                    title: tr("recording_episode_resumed"),
                    at: now
                )
                recordingCoordinator.resume(now: now)
                return
            }
            // 切到别件事：上一份就地收尾。
            _ = recordingCoordinator.stop(now: now)
        }
        guard intelligencePreferences.autoRecordEpisodes,
              snapshot.activeRecordingSession == nil,
              let target = snapshot.targets[episode.targetID]
        else { return }
        _ = recordingCoordinator.start(
            title: target.name,
            targetID: target.id,
            episodeID: episode.id,
            autoFollowed: true,
            now: now
        )
        recordingCoordinator.note(
            kind: .episode,
            title: String(format: tr("recording_episode_started"), target.name),
            at: now
        )
    }

    private func handleRecordingOnEpisodePause(_ episodeID: UUID, now: Date) {
        guard let active = snapshot.activeRecordingSession,
              active.autoFollowed,
              active.episodeID == episodeID
        else { return }
        recordingCoordinator.note(kind: .episode, title: tr("recording_episode_paused"), at: now)
        recordingCoordinator.pause(now: now)
    }

    private func handleRecordingOnEpisodeResume(_ episodeID: UUID, now: Date) {
        guard let active = snapshot.activeRecordingSession,
              active.autoFollowed,
              active.episodeID == episodeID
        else { return }
        recordingCoordinator.note(kind: .episode, title: tr("recording_episode_resumed"), at: now)
        recordingCoordinator.resume(now: now)
    }

    private func handleRecordingOnEpisodeEnd(_ episodeID: UUID, now: Date) {
        guard let active = snapshot.activeRecordingSession,
              active.autoFollowed,
              active.episodeID == episodeID
        else { return }
        recordingCoordinator.note(kind: .episode, title: tr("recording_episode_ended"), at: now)
        _ = recordingCoordinator.stop(now: now)
    }

    // MARK: - 现场快照

    @Published private(set) var intelligencePreferences: IntelligencePreferences = .load()

    var intelligenceEngine: IntelligenceEngineProtocol {
        IntelligenceEngineFactory.make(preferences: intelligencePreferences)
    }

    var currentSceneSnapshot: SceneSnapshot? {
        snapshot.currentSceneSnapshot
    }

    /// 捕获现场快照。可指定 episode（自动钩子在切换前捕获被暂停的 episode）。
    /// 从该 episode 的 ContextCapsule 构建，用智能引擎筛选并生成「回来先做」。
    /// `refreshingContext` 供手动「记录当前现场」使用：现读一次桌面现场并
    /// 写回 episode，而不是重放 episode 里可能为空的旧上下文。
    @discardableResult
    func captureSceneSnapshot(
        for episodeID: UUID? = nil,
        refreshingContext: Bool = false,
        now: Date = Date()
    ) async -> SceneSnapshot? {
        var episode: AttentionEpisode?
        if let episodeID {
            episode = snapshot.episodes[episodeID]
        } else {
            episode = currentEpisode
        }
        guard var episode else { return nil }

        if refreshingContext {
            var capsule = contextCapture(intelligencePreferences, sceneCapturePreferences)
            if capsule.hasSceneContent {
                capsule.note = episode.context.note
                if updateContext(for: episode.id, context: capsule, now: now) {
                    episode.context = capsule
                }
            }
        }

        guard episode.context.hasSceneContent else { return nil }

        let target = snapshot.targets[episode.targetID]
        let targetName = target?.name ?? ""
        let targetNote = target?.note ?? ""
        let filterMode = target?.sceneFilterMode ?? intelligencePreferences.sceneFilterDefault

        var sceneSnapshot = await SceneSnapshotBuilder.buildSnapshot(
            from: episode.context,
            targetID: episode.targetID,
            targetName: targetName,
            targetNote: targetNote,
            filterMode: filterMode,
            engine: intelligenceEngine,
            generateReturnCue: intelligencePreferences.generateReturnCue
        )
        sceneSnapshot.episodeID = episode.id

        #if os(macOS)
        // 「保存窗口截图」：切走瞬间存一张全桌面截图进现场舱。
        // 每个目标只留最新一张，换新时删旧文件。
        let previousScreenshotURL = snapshot
            .latestSceneSnapshot(for: episode.targetID)?
            .screenshotAssetURL
        if intelligencePreferences.saveWindowScreenshot,
           let imageData = await SceneScreenshotRecorder.captureDesktop(),
           let storedURL = try? assetStore.save(data: imageData, fileExtension: "jpg") {
            sceneSnapshot.screenshotAssetURL = storedURL
        }
        #endif

        guard commit([.sceneSnapshotChanged(sceneSnapshot, at: now)]) else {
            #if os(macOS)
            assetStore.removeIfPresent(at: sceneSnapshot.screenshotAssetURL)
            #endif
            return sceneSnapshot
        }
        #if os(macOS)
        if let previousScreenshotURL,
           previousScreenshotURL != sceneSnapshot.screenshotAssetURL {
            assetStore.removeIfPresent(at: previousScreenshotURL)
        }
        #endif
        return sceneSnapshot
    }

    /// 切换/暂停/等待时自动捕获现场。fire-and-forget，不阻塞状态流转。
    /// 无 AI 时引擎立即返回（相关性不猜、全部保留），不会在测试环境挂起。
    /// announcingSetAside：这次捕获属于「放下」——存好后把结果亮给用户
    /// （「现在」页的已放下确认卡），而不是只在背后默默存一份。
    private func scheduleSceneAutoCapture(
        for episodeID: UUID,
        announcingSetAside: Bool = false
    ) {
        guard !sceneCapturePreferences.isAutomaticCapturePaused,
              snapshot.episodes[episodeID]?.context.hasSceneContent == true
        else { return }
        Task { [weak self] in
            guard let self else { return }
            let captured = await self.captureSceneSnapshot(for: episodeID)
            guard announcingSetAside,
                  let captured,
                  !captured.restorableItems.isEmpty || !captured.clipboardText.isEmpty,
                  let episode = self.snapshot.episodes[episodeID],
                  let target = self.snapshot.targets[episode.targetID]
            else { return }
            self.recentSetAside = RecentSetAside(
                targetID: target.id,
                targetName: target.name,
                snapshotID: captured.id,
                at: Date()
            )
        }
    }

    /// 用户看过「已放下」确认卡后收起它。
    func dismissRecentSetAside() {
        recentSetAside = nil
    }

    #if DEBUG
    /// 调试后门（截图/验收用）：真实放下当前这件，但确认弹窗用这件事已有的
    /// 现场快照亮出来——不依赖这台机器的实时捕获权限。
    func debugAnnounceSetAside(of episodeID: UUID) {
        guard let episode = snapshot.episodes[episodeID],
              let target = snapshot.targets[episode.targetID] else { return }
        _ = pauseEpisode(episodeID, returnCue: episode.returnCue)
        let existing = snapshot.sceneSnapshots.values
            .filter { $0.targetID == episode.targetID }
            .max { $0.capturedAt < $1.capturedAt }
        guard let existing else { return }
        recentSetAside = RecentSetAside(
            targetID: target.id,
            targetName: target.name,
            snapshotID: existing.id,
            at: Date()
        )
    }
    #endif

    /// 从一份现场快照删除一条（「已放下」确认卡 / 现场卡里的手动剔除）。
    @discardableResult
    func removeSceneItem(_ snapshotID: UUID, itemID: UUID, now: Date = Date()) -> Bool {
        guard var sceneSnapshot = snapshot.sceneSnapshots[snapshotID] else { return false }
        let countBefore = sceneSnapshot.items.count
        sceneSnapshot.items.removeAll { $0.id == itemID }
        guard sceneSnapshot.items.count < countBefore else { return false }
        return commit([.sceneSnapshotChanged(sceneSnapshot, at: now)])
    }

    /// 直接提交一份现场快照到事件存储（同步）。
    @discardableResult
    func commitSceneSnapshot(_ sceneSnapshot: SceneSnapshot, now: Date = Date()) -> Bool {
        commit([.sceneSnapshotChanged(sceneSnapshot, at: now)])
    }
    @discardableResult
    func updateSceneFilterMode(
        for targetID: UUID,
        mode: SceneFilterMode,
        now: Date = Date()
    ) -> Bool {
        guard var target = snapshot.targets[targetID] else { return false }
        target.sceneFilterMode = mode
        target.updatedAt = now
        return commit([.targetChanged(target, at: now)])
    }

    /// 更新现场快照的「回来先做」。
    @discardableResult
    func updateSceneReturnCue(
        _ snapshotID: UUID,
        returnCue: String,
        now: Date = Date()
    ) -> Bool {
        guard var sceneSnapshot = snapshot.sceneSnapshots[snapshotID] else { return false }
        sceneSnapshot.returnCue = returnCue.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit([.sceneSnapshotChanged(sceneSnapshot, at: now)])
    }

    /// 手动切换某条现场条目的相关性（用户手动加回或收起）。
    @discardableResult
    func toggleSceneItemRelevance(
        _ snapshotID: UUID,
        itemID: UUID,
        now: Date = Date()
    ) -> Bool {
        guard var sceneSnapshot = snapshot.sceneSnapshots[snapshotID] else { return false }
        guard let index = sceneSnapshot.items.firstIndex(where: { $0.id == itemID }) else { return false }
        sceneSnapshot.items[index].isRelevant.toggle()
        sceneSnapshot.items[index].relevanceSource = .manual
        return commit([.sceneSnapshotChanged(sceneSnapshot, at: now)])
    }

    /// 更新智能偏好。
    func updateIntelligencePreferences(_ preferences: IntelligencePreferences) {
        preferences.save()
        intelligencePreferences = preferences
    }

    func updateSceneCapturePreferences(_ preferences: SceneCapturePreferences) {
        let normalized = preferences.normalized()
        normalized.save()
        sceneCapturePreferences = normalized
    }

    struct SceneHistoryClearResult: Equatable {
        let sceneSnapshotCount: Int
        let episodeCount: Int
        let waitingCount: Int

        var totalRecordCount: Int { sceneSnapshotCount + episodeCount + waitingCount }
    }

    /// 从事件日志中真正移除近期或全部现场事实，同时保留目标、状态迁移、
    /// 专注时长与用户主动写下的备注。`nil` cutoff 表示全部历史。
    @discardableResult
    func clearSceneHistory(capturedSince cutoff: Date?) -> SceneHistoryClearResult? {
        guard isEventLogReadable else {
            lastError = Self.unreadableLogRefusalMessage
            return nil
        }

        let sceneIDs = Set(events.compactMap { event -> UUID? in
            guard let scene = event.sceneSnapshot,
                  cutoff.map({ scene.capturedAt >= $0 }) ?? true
            else { return nil }
            return scene.id
        })
        let episodeIDs = Set(events.compactMap { event -> UUID? in
            guard let episode = event.episode,
                  episode.context.hasSceneContent,
                  cutoff.map({ episode.context.capturedAt >= $0 }) ?? true
            else { return nil }
            return episode.id
        })
        let waitingIDs = Set(events.compactMap { event -> UUID? in
            guard let waiting = event.waiting,
                  waiting.originalContext.hasSceneContent,
                  cutoff.map({ waiting.originalContext.capturedAt >= $0 }) ?? true
            else { return nil }
            return waiting.id
        })
        let result = SceneHistoryClearResult(
            sceneSnapshotCount: sceneIDs.count,
            episodeCount: episodeIDs.count,
            waitingCount: waitingIDs.count
        )
        guard result.totalRecordCount > 0 else {
            lastError = nil
            return result
        }

        let screenshotCandidates = snapshot.sceneSnapshots.values
            .filter { sceneIDs.contains($0.id) }
            .compactMap(\.screenshotAssetURL)
        let retainedEvents = events.compactMap {
            $0.scrubbingSceneContent(capturedSince: cutoff)
        }

        do {
            try store.save(events: retainedEvents)
            let persistedEvents = try store.load()
            events = persistedEvents
            snapshot = AttentionSnapshot.replay(persistedEvents)
            let retainedScreenshots = Set(snapshot.sceneSnapshots.values.compactMap(\.screenshotAssetURL))
            for url in screenshotCandidates where !retainedScreenshots.contains(url) {
                assetStore.removeIfPresent(at: url)
            }
            lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - 环境执行会话（撤销 / 收场）

    /// 一次环境执行的现场记录：收场时按相反顺序还原显示状态，
    /// 并可选退出本次新打开的应用。只记内存——应用的显示状态本就不跨重启。
    struct EnvironmentRunSession: Identifiable, Equatable {
        let id: UUID
        let profileID: UUID
        let profileName: String
        let execution: EnvironmentExecution
        let startedAt: Date
    }

    @Published private(set) var environmentRunSession: EnvironmentRunSession?

    /// 记录一次环境执行，让「环境」页出现收场入口。没有可还原内容时不记。
    func recordEnvironmentRun(
        profile: EnvironmentProfile,
        execution: EnvironmentExecution,
        now: Date = Date()
    ) {
        guard execution.isCloseOutMeaningful else { return }
        environmentRunSession = EnvironmentRunSession(
            id: UUID(),
            profileID: profile.id,
            profileName: profile.name,
            execution: execution,
            startedAt: now
        )
    }

    func dismissEnvironmentRunSession() {
        environmentRunSession = nil
    }

    /// 收场：还原被这次执行改变的应用显示状态；可选退出本次新打开的应用。
    /// 返回一句可展示的结果。
    func closeOutEnvironmentRun(quitLaunchedApplications: Bool) async -> String {
        guard let session = environmentRunSession else {
            return tr("no_environment_run_to_close_out")
        }
        environmentRunSession = nil
        let results = await EnvironmentActionRunner().closeOut(
            session.execution,
            quitLaunchedApplications: quitLaunchedApplications
        )
        let failed = results.filter { $0.status == .failed }.count
        if results.isEmpty {
            return String(format: tr("nothing_to_undo_for_environment"), session.profileName)
        }
        if failed == 0 {
            return String(
                format: results.count == 1
                    ? tr("environment_wound_down_n_restored_one")
                    : tr("environment_wound_down_n_restored"),
                session.profileName,
                results.count
            )
        }
        let details = results
            .filter { $0.status == .failed }
            .map(\.message)
            .joined(separator: " ")
        return String(
            format: failed == 1
                ? tr("environment_wound_down_with_n_failures_one")
                : tr("environment_wound_down_with_n_failures"),
            session.profileName,
            failed,
            details
        )
    }

    // MARK: - 一键重返

    /// 执行现场恢复。只恢复用户选中的条目类别。
    /// 如果恢复来自等待结果（waitingID 非空），同时把等待标记为已解决、episode 恢复为 active。
    @discardableResult
    func restoreScene(
        _ snapshotID: UUID,
        selectedKinds: Set<SceneItemKind>? = nil,
        resolvingWaitingID: UUID? = nil,
        now: Date = Date()
    ) -> ContextRestoreReport {
        guard let sceneSnapshot = snapshot.sceneSnapshots[snapshotID] else {
            return ContextRestoreReport()
        }
        // 现场既已恢复，「已放下」确认卡的使命就结束了。
        if recentSetAside?.snapshotID == snapshotID {
            recentSetAside = nil
        }
        let items: [SceneItem]
        if let selectedKinds {
            items = sceneSnapshot.restorableItems.filter { selectedKinds.contains($0.kind) }
        } else {
            items = sceneSnapshot.restorableItems
        }

        // 先完成等待/episode 状态流转，再执行恢复动作
        if let waitingID = resolvingWaitingID {
            _ = resumeWaitingEpisode(waitingID, now: now)
        }

        #if os(macOS)
        let restorer = MacContextRestorer()
        var capsule = ContextCapsule(capturedAt: sceneSnapshot.capturedAt)
        capsule.note = sceneSnapshot.returnCue

        for item in items {
            switch item.kind {
            case .file:
                if let url = URL(string: item.address) { capsule.files.append(url) }
            case .link:
                if let url = URL(string: item.address) { capsule.links.append(url) }
            case .terminal:
                if let url = URL(string: item.address) {
                    capsule.terminalWorkingDirectories.append(url)
                }
            case .application:
                if !capsule.applicationBundleIdentifiers.contains(item.address) {
                    capsule.applicationBundleIdentifiers.append(item.address)
                    capsule.applications.append(item.sourceApplication)
                }
            }
        }
        return restorer.restore(capsule)
        #else
        return ContextRestoreReport()
        #endif
    }

    private func commit(_ newEvents: [AttentionEvent]) -> Bool {
        guard !newEvents.isEmpty else { return true }
        guard isEventLogReadable else {
            lastError = Self.unreadableLogRefusalMessage
            return false
        }
        let proposedEvents = events + newEvents

        do {
            try store.save(events: proposedEvents)
            let persistedEvents = try store.load()
            events = persistedEvents
            snapshot = AttentionSnapshot.replay(persistedEvents)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
