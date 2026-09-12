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
    /// 刚放下的一件事（仅会话内，不落盘）：「现在」页据此出确认卡，
    /// 让用户看到保存了什么、能逐条剔除，由用户点掉。
    @Published private(set) var recentSetAside: RecentSetAside?

    struct RecentSetAside: Equatable, Identifiable {
        let targetID: UUID
        let targetName: String
        /// 现场快照要等异步采集落盘才有，所以是可选的：放下那一刻先把确认卡亮出来
        /// （趁记忆还热写「回来先看」），清单随后自己长出来。等采完再弹的话，用户
        /// 早已开始下一件事，那张卡看着就像凭空冒出来的。
        var snapshotID: UUID?
        let at: Date

        /// 一件事同时只有一张确认卡：身份认目标，好让补上 snapshotID 时弹窗不重开。
        var id: UUID { targetID }
    }

    private let store: LocalEventStore
    private let assetStore: LocalAssetStore
    private var events: [AttentionEvent]
    private var isEventLogReadable = true
    private lazy var waitingCoordinator = WaitingCoordinator(workspace: self)
    private lazy var scheduledTaskCoordinator = ScheduledTaskCoordinator(workspace: self)
    private let recordingTraceStore: RecordingTraceStore
    private lazy var recordingCoordinator = RecordingCoordinator(
        workspace: self,
        traceStore: recordingTraceStore,
        capture: { [weak self] in
            guard let self else { return ContextCapsule() }
            // 录制采样跟自动场景采集共用一个暂停开关：暂停就是暂停，不分入口。
            guard !self.sceneCapturePreferences.isAutomaticCapturePaused else { return ContextCapsule() }
            return self.contextCapture(self.intelligencePreferences, self.sceneCapturePreferences)
        }
    )
    private let contextCapture: (IntelligencePreferences, SceneCapturePreferences) -> ContextCapsule
    /// 测试注入的智能引擎；为 nil 时按偏好现造一套。
    private let injectedIntelligenceEngine: IntelligenceEngineProtocol?
    private let clipboardHistoryStore: ClipboardHistoryStore
    /// 测试注入的剪贴板读取；为 nil 时读系统剪贴板。
    private let injectedClipboardSample: (() -> ClipboardSample)?
    /// 跟随事情的剪贴板历史：谁在专注就记谁的，放下 / 等待 / 结束即停。
    /// 开关与现场那一次读取同一个（「保存剪贴板内容」），自动记录暂停时也停。
    private lazy var clipboardHistoryCoordinator = ClipboardHistoryCoordinator(
        store: clipboardHistoryStore,
        sample: { [weak self] in
            if let injected = self?.injectedClipboardSample { return injected() }
            guard let self else { return ClipboardSample(changeCount: 0, text: "", sourceApplication: "") }
            return MacClipboardSampler.sample(
                characterLimit: ContextCaptureOptions.default.clipboardCharacterLimit,
                sourcePreferences: self.sceneCapturePreferences
            )
        },
        isEnabled: { [weak self] in
            guard let self else { return false }
            return self.intelligencePreferences.saveClipboardContent
                && !self.sceneCapturePreferences.isAutomaticCapturePaused
        },
        onChange: { [weak self] in self?.clipboardHistoryRevision &+= 1 }
    )
    /// 每记下一条剪贴板 +1：正在跟随那段事的现场卡据此重算复写条。
    @Published private(set) var clipboardHistoryRevision = 0

    @Published private(set) var sceneCapturePreferences: SceneCapturePreferences = .load()

    init(
        store: LocalEventStore = LocalEventStore(),
        assetStore: LocalAssetStore? = nil,
        sceneCapturePreferences: SceneCapturePreferences? = nil,
        recordingTraceStore: RecordingTraceStore? = nil,
        clipboardHistoryStore: ClipboardHistoryStore? = nil,
        clipboardSample: (() -> ClipboardSample)? = nil,
        contextCapture: ((IntelligencePreferences, SceneCapturePreferences) -> ContextCapsule)? = nil,
        intelligenceEngine: IntelligenceEngineProtocol? = nil
    ) {
        self.injectedIntelligenceEngine = intelligenceEngine
        self.store = store
        self.assetStore = assetStore ?? LocalAssetStore()
        self.recordingTraceStore = recordingTraceStore ?? RecordingTraceStore()
        self.clipboardHistoryStore = clipboardHistoryStore ?? ClipboardHistoryStore()
        self.injectedClipboardSample = clipboardSample
        self.sceneCapturePreferences = sceneCapturePreferences ?? .load()
        self.contextCapture = contextCapture ?? { intelligence, sourcePreferences in
            MacContextRecorder().capture(
                options: ContextCaptureOptions(
                    preferences: intelligence,
                    sourcePreferences: sourcePreferences
                )
            ).capsule
        }

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

    func runBackgroundMaintenance(now: Date = Date()) {
        _ = archiveConfiguredInbox(now: now)
        backfillCaptureText()
        backfillInboxOrganization()
        startActiveWaitingMonitors()
        scheduledTaskCoordinator.startMonitoringScheduledTasks(now: now)
        recordingCoordinator.finalizeOrphanedSessions(now: now)
        // 重新打开应用时手上那件事还在专注，剪贴板历史接着往它的文件里写。
        syncClipboardHistory(now: now)
    }

    // MARK: - 剪贴板历史

    /// 让剪贴板历史跟上 episode 状态：占着「现在」且在专注（进行中 / 回场）的那段
    /// 在跟随；放下、等待、结束或没有事在做就停。每次提交里有 episode 变化都会
    /// 来一趟，所以不必在每个状态迁移入口各挂一次钩子。
    private func syncClipboardHistory(now: Date) {
        if let episode = currentEpisode,
           episode.state == .active || episode.state == .returning {
            clipboardHistoryCoordinator.follow(episode.id, now: now)
        } else {
            clipboardHistoryCoordinator.stopFollowing()
        }
    }

    /// 某段工作期间复制过的文字，最早的在前。开关关着或那段事没复制过时为空。
    func clipboardHistory(for episodeID: UUID) -> [ClipboardHistoryEntry] {
        clipboardHistoryCoordinator.entries(for: episodeID)
    }

    /// 立刻看一次剪贴板（测试用；正常由轮询驱动）。
    func sampleClipboardNow(at now: Date = Date()) {
        clipboardHistoryCoordinator.sampleNow(at: now)
    }

    /// 某段工作的专注区间（进行中 / 回场），按时间先后；午夜切开的接回一段。
    func focusIntervals(for episodeID: UUID, now: Date = Date()) -> [DateInterval] {
        var intervals: [DateInterval] = []
        for segment in FocusLedger.segments(events: events, now: now)
        where segment.episodeID == episodeID {
            if let last = intervals.last, last.end >= segment.start {
                intervals[intervals.count - 1] = DateInterval(
                    start: last.start,
                    end: max(last.end, segment.end)
                )
            } else {
                intervals.append(DateInterval(start: segment.start, end: segment.end))
            }
        }
        return intervals
    }

    /// 一份现场的复写条：这段事期间复制过的文字按专注区间分纸，放下那一刻手上
    /// 的那条（现场里的 clipboardText）若没在历史里就补成最新的一条。
    func clipboardStrips(for sceneSnapshot: SceneSnapshot, now: Date = Date()) -> [ClipboardStrip] {
        var entries = sceneSnapshot.episodeID.map { clipboardHistory(for: $0) } ?? []
        if !sceneSnapshot.clipboardText.isEmpty,
           entries.last?.text != sceneSnapshot.clipboardText {
            entries.append(ClipboardHistoryEntry(
                at: sceneSnapshot.capturedAt,
                text: sceneSnapshot.clipboardText
            ))
        }
        guard !entries.isEmpty else { return [] }
        let intervals = sceneSnapshot.episodeID.map { focusIntervals(for: $0, now: now) } ?? []
        return ClipboardStrip.build(entries: entries, focusIntervals: intervals)
    }

    /// 现场卡要不要画复写条：放下那一刻有剪贴板，或这段事里复制过东西。
    func hasClipboardContent(_ sceneSnapshot: SceneSnapshot) -> Bool {
        !sceneSnapshot.clipboardText.isEmpty
            || sceneSnapshot.episodeID.map { !clipboardHistory(for: $0).isEmpty } ?? false
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
            // 等待证据可能来自外部事件，进提示词前截短。
            waitingEvidence: String((waiting?.evidence ?? "").prefix(300)),
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
            .filter { $0.retiredAt == nil }
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
        guard createTarget(
            name: String(name.prefix(60)),
            note: "从稍后处理箱整理而来。",
            now: now
        ) != nil else { return false }
        return archiveCapture(capture.id, now: now)
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

    /// 用户删了捕获 / 记录 / 场景之后立刻清索引：被删掉的东西不该还能被搜出来，
    /// 哪怕只是到下一次节流刷新之前的那一分钟。空集也要传——最后一条被删时
    /// 恰恰要把索引清空。
    func pruneMemoryIndex(index: MemoryIndex = .shared, now: Date = Date()) {
        let validKeys = Set(
            MemoryIndexSource.items(events: events, snapshot: snapshot, now: now).map(\.key)
        )
        Task.detached(priority: .utility) {
            await index.pruneNow(validKeys: validKeys)
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
        clipboardHistoryCoordinator.stopFollowing()
    }

    /// - Parameter quarantiningRestoredAutomation: 从备份恢复后为 true。备份是外部
    ///   文件，里面的 shell 命令与快捷指令不能因为「恢复」这个动作就自动获得执行权。
    @discardableResult
    func reloadFromDisk(quarantiningRestoredAutomation: Bool = false, now: Date = Date()) -> Bool {
        waitingCoordinator.cancelAllMonitoring()
        scheduledTaskCoordinator.cancelAllMonitoring()
        do {
            let loadedEvents = try store.load()
            events = loadedEvents
            snapshot = AttentionSnapshot.replay(loadedEvents)
            lastError = nil
            isEventLogReadable = true
            syncClipboardHistory(now: now)
            if quarantiningRestoredAutomation {
                quarantineAutomation(now: now)
            }
            // 数据目录可能刚被整体换掉：旧句柄指着被改名的旧库，必须关掉重开。
            Task.detached(priority: .utility) { await MemoryIndex.shared.close() }
            runBackgroundMaintenance(now: now)
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

    /// 把日志里所有会执行外部代码的东西解除武装：环境里的「运行命令 / 运行快捷指令」
    /// 动作关掉。用户在界面里重新打开，才算授权。返回处理过的条目数。
    @discardableResult
    func quarantineAutomation(now: Date = Date()) -> Int {
        var newEvents: [AttentionEvent] = []
        for var environment in snapshot.environments.values {
            var changed = false
            environment.actions = environment.actions.map { action in
                guard action.isEnabled, action.kind == .runCommand || action.kind == .runShortcut else {
                    return action
                }
                var disabled = action
                disabled.isEnabled = false
                changed = true
                return disabled
            }
            if changed {
                newEvents.append(.environmentChanged(environment, at: now))
            }
        }
        guard !newEvents.isEmpty else { return 0 }
        return commit(newEvents) ? newEvents.count : 0
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
            // 同理：先丢内存里的剪贴板历史，免得停跟随时再把文件写回刚删的目录。
            clipboardHistoryCoordinator.discardAll()
            // 数据根目录取自事件存储本身：位置可注入，照默认路径删会删到别处。
            let dataRoot = store.directoryURL.deletingLastPathComponent()
            let fileManager = FileManager.default
            // 事件目录、旧的整份日志以及其余数据文件都在 LocalDataErasure 清单里。
            for url in LocalDataErasure.fileURLs(in: dataRoot)
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            // Drop the in-memory history as soon as its files are gone. If a later
            // step fails, the next commit must not write the deleted events back.
            events = []
            snapshot = AttentionSnapshot()
            isEventLogReadable = false
            _ = try store.load()
            isEventLogReadable = true
            try assetStore.removeAll()
            // 索引文件已经 unlink，但 actor 手里的句柄还能读到全部旧行；关掉它。
            Task.detached(priority: .utility) { await MemoryIndex.shared.removeAll() }
            // 每次恢复备份留下的整目录旧副本也算「这台 Mac 上的数据」。
            LocalDataArchiveService.removePreRestoreCopies(of: dataRoot)
            for key in LocalDataErasure.erasableUserDefaultsKeys {
                defaults.removeObject(forKey: key)
            }
            // 云端凭据住在保留下来的偏好 blob 里，单独抹。
            IntelligencePreferences.eraseCloudConfiguration(in: defaults)
            // GitHub 令牌住在 Keychain，不在 UserDefaults 清单里，单独抹。
            GitHubAuthService.eraseStoredToken()
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
        dueAt: Date? = nil,
        now: Date = Date()
    ) -> AttentionTarget? {
        let target = AttentionTarget(
            name: name,
            note: note,
            createdAt: now,
            updatedAt: now,
            environmentProfileID: environmentProfileID,
            dueAt: dueAt
        )
        guard target.isValid else { return nil }
        guard commit([.targetChanged(target, at: now)]) else { return nil }
        if dueAt != nil { waitingCoordinator.startMonitoringDueDates() }
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
        // 改字段而不是重建：目标身上还有别的记忆（现场筛选偏好、步骤归属、
        // 收起墓碑、期限），重建会把没列出来的字段悄悄抹掉。
        guard var target = snapshot.targets[targetID] else { return false }
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        target.environmentProfileID = environmentProfileID
        target.updatedAt = now
        guard target.isValid else { return false }
        return commit([.targetChanged(target, at: now)])
    }

    /// 改一件事的期限。传 nil 就是撤掉——撤掉之后它只是一笔账，不再打扰你。
    /// 改期会把「已经催过」一并清掉：新期限是新的承诺，到点该重新催一次。
    @discardableResult
    func setTargetDueDate(_ targetID: UUID, to dueAt: Date?, now: Date = Date()) -> Bool {
        guard var target = snapshot.targets[targetID], target.dueAt != dueAt else { return false }
        target.dueAt = dueAt
        target.nudgedAt = nil
        target.updatedAt = now
        guard commit([.targetChanged(target, at: now)]) else { return false }
        waitingCoordinator.startMonitoringDueDates()
        return true
    }

    // MARK: - 步骤（大任务里的小步骤）

    /// 给一件大任务加一个步骤：步骤是完整的目标（自己的段/现场/计时），
    /// 只允许一层——步骤不能再拆步骤。
    @discardableResult
    func addStep(named name: String, to parentID: UUID, now: Date = Date()) -> AttentionTarget? {
        guard let parent = snapshot.targets[parentID], parent.parentTargetID == nil else { return nil }
        let step = AttentionTarget(
            name: name,
            createdAt: now,
            updatedAt: now,
            parentTargetID: parentID
        )
        guard step.isValid else { return nil }
        guard commit([.targetChanged(step, at: now)]) else { return nil }
        return step
    }

    /// 完成一件大任务并连带收起没做完的步骤（UI 在按下前负责提醒确认）：
    /// 步骤还开着的段按「放弃」收束（等待一并关掉），再盖上 retiredAt 墓碑——
    /// 从此不进任何清单；事件日志保留全部历史。
    @discardableResult
    func endEpisodeCollapsingSteps(_ episodeID: UUID, now: Date = Date()) -> Bool {
        guard let episode = snapshot.episodes[episodeID] else { return false }
        let parentID = episode.targetID
        guard endEpisode(episodeID, now: now) else { return false }
        var retireEvents: [AttentionEvent] = []
        for step in snapshot.unfinishedSteps(of: parentID) {
            if let open = snapshot.latestEpisode(of: step.id), open.state != .ended {
                _ = abandonEpisode(open.id, now: now)
            }
            guard var retired = snapshot.targets[step.id] else { continue }
            retired.retiredAt = now
            retired.updatedAt = now
            retireEvents.append(.targetChanged(retired, at: now))
        }
        return retireEvents.isEmpty || commit(retireEvents)
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
    func unfinishedEpisode(for targetID: UUID) -> AttentionEpisode? {
        snapshot.episodes.values
            .filter { $0.targetID == targetID && $0.state != .ended }
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
        var shouldCapturePreviousScene = false
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
            scheduleEpisodeSummary(for: episodeID)
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
            scheduleEpisodeSummary(for: episodeID)
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
            scheduleEpisodeSummary(for: episodeID)
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
              assetStore.isManaged(assetURL),
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
            .filter {
                $0.kind == .screenshot && assetStore.isManaged($0.assetURL) && $0.textExtractedAt == nil
            }
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
        return target
    }

    @discardableResult
    func beginWaitingFromCapture(
        _ captureID: UUID,
        episodeID: UUID? = nil,
        completionCondition: String = "用户确认已到达",
        dueAt: Date? = nil,
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
            description: description,
            completionCondition: completionCondition,
            startedAt: now,
            dueAt: dueAt,
            originalContext: episode.context
        )
        guard waiting.isValid else { return nil }
        // 球交到别人手里 = 这件事被放下了。没有单独的「等待中」状态：
        // 它归哪一组由「身上有没有一条还没等到的结果」决定。
        episode.state = .paused
        episode.updatedAt = now
        episode.waitingIDs.append(waiting.id)
        var archivedCapture = capture
        archivedCapture.status = .archived
        guard commit([
            .episodeChanged(episode, at: now),
            .waitingChanged(waiting, at: now),
            .captureArchived(archivedCapture, at: now)
        ]) else { return nil }
        waitingCoordinator.startMonitoringDueDates()
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
            pruneMemoryIndex()
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
        description: String,
        completionCondition: String = "",
        dueAt: Date? = nil,
        now: Date = Date()
    ) -> WaitingItem? {
        guard var episode = snapshot.episodes[episodeID],
              episode.state != .ended
        else { return nil }

        if episode.state == .active || episode.state == .returning {
            episode.context = boundaryContext(for: episode, at: now)
        }

        let waiting = WaitingItem(
            episodeID: episodeID,
            description: description,
            completionCondition: completionCondition,
            startedAt: now,
            dueAt: dueAt,
            originalContext: episode.context
        )
        guard waiting.isValid else { return nil }

        // 球交到别人手里 = 这件事被放下了。它离开「现在」页，你顺手挑下一件——
        // 你在等的时候本来就一定在做别的。
        episode.state = .paused
        episode.updatedAt = now
        episode.waitingIDs.append(waiting.id)
        guard commit([
            .episodeChanged(episode, at: now),
            .waitingChanged(waiting, at: now)
        ]) else { return nil }
        waitingCoordinator.startMonitoringDueDates()
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
        // 不再推「你在等的一个结果到了」——**是你自己说它到了的**，
        // 再回头通知你一遍是自说自话。软件只在「快到期了」时开口。
        let committed = commit([
            .waitingChanged(waiting, at: now)
        ])
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
        // 球回到你手里：这条从「等着别人」挪进「可以动」。那段工作本来就是
        // 放下状态，不用再改——归属只看还有没有没等到的结果。
        return commit([.waitingChanged(waiting, at: now)])
    }

    /// 启动与维护循环的入口：把还没催过的期限重新挂上表。
    func startActiveWaitingMonitors() {
        waitingCoordinator.startMonitoringDueDates()
    }

    // MARK: - 到期来找你

    /// 把已经进了窗口、还没催过的都催一遍，然后盖上「催过了」。
    ///
    /// **一件事到期只说一次**，说完就过去了——不累积愧疚，不隔天又冒出来。
    /// 你要是选了「算了」，撤掉期限，它就真的算了。
    func deliverDueNudges(now: Date = Date()) {
        var events: [AttentionEvent] = []

        for target in snapshot.dueTargets(now: now) where target.needsNudge(now: now) {
            var nudged = target
            nudged.nudgedAt = now
            events.append(.targetChanged(nudged, at: now))
            DueNudgeNotification(
                kind: .ownWork,
                title: target.name,
                dueLabel: UserFacingCopy.dueDayLabel(target.dueAt ?? now, now: now),
                countdown: DueCountdown(due: target.dueAt ?? now, now: now)
            ).post(identifier: "light-anchor.due.target.\(target.id.uuidString)")
        }

        for waiting in snapshot.dueWaitingItems(now: now) where waiting.needsNudge(now: now) {
            var nudged = waiting
            nudged.nudgedAt = now
            events.append(.waitingChanged(nudged, at: now))
            DueNudgeNotification(
                kind: .waitingOnOthers,
                title: waiting.description,
                dueLabel: UserFacingCopy.dueDayLabel(waiting.dueAt ?? now, now: now),
                countdown: DueCountdown(due: waiting.dueAt ?? now, now: now)
            ).post(identifier: "light-anchor.due.waiting.\(waiting.id.uuidString)")
        }

        guard !events.isEmpty else { return }
        _ = commit(events)
    }

    /// 下一次该醒来的时刻：最近一个还没进窗口的期限，减去提前量。
    /// 已经进了窗口的这一轮就催掉了，不用再等。
    func nextNudgeDate(after now: Date = Date()) -> Date? {
        let lead = Double(DueCountdown.leadDays) * 86_400
        var candidates: [Date] = []
        for target in snapshot.activeTargets where target.dueAt != nil {
            candidates.append(target.dueAt!.addingTimeInterval(-lead))
        }
        for waiting in snapshot.waitingItems.values
        where waiting.status == .waiting && waiting.dueAt != nil {
            candidates.append(waiting.dueAt!.addingTimeInterval(-lead))
        }
        return candidates.filter { $0 > now }.min()
    }

    @discardableResult
    func resumeWaitingEpisode(_ waitingID: UUID, now: Date = Date()) -> Bool {
        guard let waiting = snapshot.waitingItems[waitingID], waiting.status == .ready,
              var episode = snapshot.episodes[waiting.episodeID],
              episode.state != .ended
        else { return false }

        var resolvedWaiting = waiting
        resolvedWaiting.status = .resolved
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

    private func changeEpisodeState(
        _ episodeID: UUID,
        state: AttentionEpisodeState,
        now: Date
    ) -> Bool {
        guard var episode = snapshot.episodes[episodeID], episode.state != .ended else {
            return false
        }
        episode.state = state
        episode.updatedAt = now
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
        ScheduledTaskNotificationService().notifyFired(rolled, firedAt: now)
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
        // 「暂停自动采集」对定时检查点同样有效：它和切换、等待一样没人在场确认。
        guard !sceneCapturePreferences.isAutomaticCapturePaused else { return nil }
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
        let committed = commit([.recordingSessionDeleted(id: sessionID, at: now)])
        if committed { pruneMemoryIndex(now: now) }
        return committed
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
        injectedIntelligenceEngine ?? IntelligenceEngineFactory.make(preferences: intelligencePreferences)
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

        // 「保存窗口截图」：切走瞬间存一张全桌面截图进现场舱。
        // 每个目标只留最新一张，换新时删旧文件。
        let previousScreenshotURL = snapshot
            .latestSceneSnapshot(for: episode.targetID)?
            .screenshotAssetURL
        if intelligencePreferences.saveWindowScreenshot,
           let imageData = await SceneScreenshotRecorder.captureDesktop(
               allowsApplication: sceneCapturePreferences.allowsApplication
           ),
           let storedURL = try? assetStore.save(data: imageData, fileExtension: "jpg") {
            sceneSnapshot.screenshotAssetURL = storedURL
        }

        guard commit([.sceneSnapshotChanged(sceneSnapshot, at: now)]) else {
            assetStore.removeIfPresent(at: sceneSnapshot.screenshotAssetURL)
            return sceneSnapshot
        }
        if let previousScreenshotURL,
           previousScreenshotURL != sceneSnapshot.screenshotAssetURL {
            assetStore.removeIfPresent(at: previousScreenshotURL)
        }
        return sceneSnapshot
    }

    /// 切换/暂停/等待时自动捕获现场。fire-and-forget，不阻塞状态流转。
    /// 无 AI 时引擎立即返回（相关性不猜、全部保留），不会在测试环境挂起。
    /// announcingSetAside：这次捕获属于「放下」——把结果亮给用户
    /// （「现在」页的已放下确认卡），而不是只在背后默默存一份。
    ///
    /// 确认卡在**放下那一刻**就置好（此时上面那道 `hasSceneContent` 已经保证有东西
    /// 可收），采集落盘后只是回来补一个 snapshotID。
    private func scheduleSceneAutoCapture(
        for episodeID: UUID,
        announcingSetAside: Bool = false
    ) {
        guard !sceneCapturePreferences.isAutomaticCapturePaused,
              snapshot.episodes[episodeID]?.context.hasSceneContent == true
        else { return }
        let announcingSetAside = announcingSetAside && !isSwitchingQuietly
        if announcingSetAside,
           let episode = snapshot.episodes[episodeID],
           let target = snapshot.targets[episode.targetID] {
            recentSetAside = RecentSetAside(
                targetID: target.id,
                targetName: target.name,
                snapshotID: nil,
                at: Date()
            )
        }
        Task { [weak self] in
            guard let self else { return }
            let captured = await self.captureSceneSnapshot(for: episodeID)
            guard announcingSetAside,
                  let captured,
                  let pending = self.recentSetAside,
                  pending.targetID == captured.targetID
            else { return }
            // 卡还在（用户没点掉、也没回到这件事），把刚存好的那份挂上去。
            self.recentSetAside?.snapshotID = captured.id
        }
    }

    /// 用户看过「已放下」确认卡后收起它。
    func dismissRecentSetAside() {
        recentSetAside = nil
    }

    // MARK: - 「换一件事」

    /// 换一件事时，手上这件怎么放：暂时放下 / 转成等待（在等什么）/ 做完了。
    enum SetAsideMode: Equatable {
        case pause
        case wait(String)
        case done
    }

    /// 手上现场的实时预览（不落盘）。「换一件事」卡上的「现场 N 样」和现场页
    /// 用它：放下的那份快照要到切换之后才异步生成，但用户在切换前就要看见、
    /// 并能逐条划掉。划掉的条目由 `setAsideCurrent` 从上下文里剔除后再放下。
    struct ScenePreview: Equatable {
        var context: ContextCapsule
        var items: [SceneItem]
    }

    func previewCurrentScene() -> ScenePreview? {
        guard let episode = currentEpisode else { return nil }
        var capsule = episode.context
        if !sceneCapturePreferences.isAutomaticCapturePaused {
            let fresh = contextCapture(intelligencePreferences, sceneCapturePreferences)
            if fresh.hasSceneContent {
                capsule = fresh
                capsule.note = episode.context.note
            }
        }
        return ScenePreview(context: capsule, items: SceneSnapshotBuilder.items(from: capsule))
    }

    /// 放下手上这件：`keeping` 是用户划掉之后剩下的现场（nil = 不改现场）。
    /// 上下文的采集时间对齐到 `now`，`boundaryContext` 便会沿用它而不再读一遍桌面
    /// ——否则用户刚划掉的东西会被切换瞬间的重新采集原样捞回来。
    @discardableResult
    func setAsideCurrent(
        _ mode: SetAsideMode,
        keeping kept: ContextCapsule? = nil,
        returnCue: String,
        now: Date = Date()
    ) -> Bool {
        guard let episode = currentEpisode, episode.state != .ended else { return false }
        var context = kept ?? episode.context
        context.capturedAt = now
        guard updateContext(for: episode.id, context: context, returnCue: returnCue, now: now) else {
            return false
        }
        switch mode {
        case .pause:
            return pauseEpisode(episode.id, now: now)
        case .wait(let description):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            return beginWaiting(
                episodeID: episode.id,
                description: trimmed.isEmpty ? tr("waiting_for_something") : trimmed,
                now: now
            ) != nil
        case .done:
            return endEpisode(episode.id, now: now)
        }
    }

    /// 「换一件事」卡已经让用户写了回来先看、逐条剔了现场，随后不必再弹
    /// 「已放下」确认卡。`body` 里发生的放下都静默存现场。
    private var isSwitchingQuietly = false

    func performQuietSwitch<T>(_ body: () -> T) -> T {
        isSwitchingQuietly = true
        defer { isSwitchingQuietly = false }
        return body()
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
        return commit([.sceneSnapshotChanged(sceneSnapshot, at: now)])
    }

    // MARK: - 这一段的总结（「上次做到哪」）
    //
    // 现场答「东西在哪」，总结答「当时在干什么、卡在哪」。总结必须在你回来
    // 之前就写好——放下和做完的那一刻自动整理（偏好可关），所以它是 fire-and-forget：
    // 失败只记诊断，不在用户放下一件事时弹错误。用户改过的那份不会被自动覆盖。

    /// 正在整理的段：UI 据此显示「正在整理…」，也防同一段并发跑两遍。
    @Published private(set) var summarizingEpisodeIDs: Set<UUID> = []

    /// 总结的署名：云端报模型名（用户看得出是哪套写的），端侧/离线报引擎名。
    var intelligenceCreditName: String {
        if let injectedIntelligenceEngine { return injectedIntelligenceEngine.name }
        switch intelligencePreferences.engine {
        case .cloud:
            let model = intelligencePreferences.activeCloudProfile.model
            return model.isEmpty ? intelligenceEngine.name : model
        case .onDevice:
            return intelligenceEngine.name
        }
    }

    /// 组装某一段的总结输入：全部是这一段自己的本机事实。
    /// 事实不足（没现场、没剪贴板、没捕获、没留话）时返回 nil——
    /// 无话可说时不该生出一段像模像样的空话。
    func makeEpisodeSummaryInput(
        episodeID: UUID,
        now: Date = Date()
    ) -> EpisodeSummaryInput? {
        guard let episode = snapshot.episodes[episodeID],
              let target = snapshot.targets[episode.targetID]
        else { return nil }

        var facts: [String] = []

        let minutes = snapshot.focusMinutes(of: episodeID, now: now)
        if minutes >= 1 {
            facts.append(String(
                format: tr("fact_episode_focused"),
                UserFacingCopy.focusDuration(minutes)
            ))
        }

        // 现场条目：这一段落盘的那份优先，没有就用段上的上下文现算一份。
        let sceneItems: [SceneItem] = snapshot.sceneSnapshots.values
            .filter { $0.episodeID == episodeID }
            .max { $0.capturedAt < $1.capturedAt }
            .map(\.restorableItems)
            ?? SceneSnapshotBuilder.items(from: episode.context)
        for item in sceneItems.prefix(12) {
            let place = item.detail.isEmpty ? item.sourceApplication : item.detail
            facts.append(place.isEmpty
                ? "[\(item.kind.title)] \(item.title)"
                : "[\(item.kind.title)] \(item.title) · \(place)")
        }

        // 这一段复制过的文字：最能说明「当时在动哪句话」的证据。
        for entry in clipboardHistory(for: episodeID).suffix(8) {
            facts.append(String(
                format: tr("fact_episode_copied"),
                Self.clockLabel(entry.at),
                String(entry.text.prefix(60))
            ))
        }

        // 这一段里捕获的想法。
        let captures = snapshot.captures.values
            .filter { capture in
                if capture.attachedEpisodeID == episodeID { return true }
                guard capture.capturedAt >= episode.startedAt else { return false }
                return capture.capturedAt <= (episode.endedAt ?? episode.updatedAt)
            }
            .sorted { $0.capturedAt < $1.capturedAt }
        for capture in captures.prefix(5) {
            let text = capture.title?.isEmpty == false ? (capture.title ?? "") : capture.body
            facts.append("[\(capture.kind.title)] \(String(text.prefix(60)))")
        }

        // 这一段交出去的结果：为什么停下，常常就写在这里。
        for waiting in snapshot.waitingItems.values
            .filter({ $0.episodeID == episodeID })
            .sorted(by: { $0.startedAt < $1.startedAt }) {
            facts.append(String(format: tr("fact_episode_waiting"), waiting.description))
        }

        // 步骤：这一段在大任务里的位置。
        if let parentID = target.parentTargetID,
           let parent = snapshot.targets[parentID] {
            let steps = snapshot.steps(of: parentID)
            if let index = steps.firstIndex(where: { $0.id == target.id }) {
                facts.append(String(
                    format: tr("fact_episode_step_of"),
                    parent.name, index + 1, steps.count
                ))
            }
        } else if let progress = snapshot.stepProgress(of: target.id) {
            facts.append(String(
                format: tr("fact_episode_step_progress"),
                progress.done, progress.total
            ))
        }

        guard facts.count >= 2 else { return nil }
        return EpisodeSummaryInput(
            targetName: target.name,
            targetNote: target.note,
            periodTitle: Self.episodePeriodTitle(episode, minutes: minutes),
            returnCue: episode.returnCue,
            factLines: facts
        )
    }

    /// 「9 月 6 日 15:30 那一段 · 专注 28 分」。
    private static func episodePeriodTitle(_ episode: AttentionEpisode, minutes: Int) -> String {
        let when = episode.startedAt.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        guard minutes >= 1 else {
            return String(format: tr("episode_period_title_short"), when)
        }
        return String(
            format: tr("episode_period_title"),
            when,
            UserFacingCopy.focusDuration(minutes)
        )
    }

    private static func clockLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// 每一段上次整理失败的原因（引擎没配、服务端报错、返回空）。
    /// 失败不静默：这一段的总结卡上如实写出来，用户看得见为什么没有总结。
    @Published private(set) var summaryFailures: [UUID: String] = [:]

    /// 整理某一段的总结。`force` 是用户点「重新整理」：连他自己改过的那份也重写。
    ///
    /// 失败**不降级**：没有可用引擎、服务端报错、模型返回空，都只记下原因，
    /// 绝不用「把事实按序拼一段话」冒充一份总结（用户定）。
    @discardableResult
    func summarizeEpisode(
        _ episodeID: UUID,
        force: Bool = false,
        now: Date = Date()
    ) async -> Bool {
        guard let episode = snapshot.episodes[episodeID] else { return false }
        if !force, let existing = episode.summary, existing.isEdited { return false }
        guard !summarizingEpisodeIDs.contains(episodeID) else { return false }
        guard let input = makeEpisodeSummaryInput(episodeID: episodeID, now: now) else { return false }

        summarizingEpisodeIDs.insert(episodeID)
        summaryFailures[episodeID] = nil
        let engine = intelligenceEngine
        let credit = intelligenceCreditName
        let text: String
        do {
            text = try await engine.summarizeEpisode(input)
        } catch {
            summarizingEpisodeIDs.remove(episodeID)
            let message = error.localizedDescription
            summaryFailures[episodeID] = message
            LocalDiagnostics.shared.record(
                operation: "episode.summarize",
                message: "engine \(engine.name): \(message)"
            )
            return false
        }
        summarizingEpisodeIDs.remove(episodeID)

        // 重取一遍：等模型的这段时间里这一段可能已经变了（用户接着做、又放下）。
        guard var latest = snapshot.episodes[episodeID] else { return false }
        latest.summary = EpisodeSummary(
            text: text,
            engineName: credit,
            factCount: input.factLines.count,
            generatedAt: now
        )
        return commit([.episodeChanged(latest, at: now)])
    }

    /// 用户改过的总结：原样存下，并盖上「改过」的记号。
    @discardableResult
    func updateEpisodeSummary(
        _ episodeID: UUID,
        text: String,
        now: Date = Date()
    ) -> Bool {
        guard var episode = snapshot.episodes[episodeID] else { return false }
        summaryFailures[episodeID] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard episode.summary != nil else { return false }
            episode.summary = nil
        } else {
            episode.summary = EpisodeSummary(
                text: trimmed,
                engineName: episode.summary?.engineName ?? intelligenceCreditName,
                factCount: episode.summary?.factCount ?? 0,
                generatedAt: episode.summary?.generatedAt ?? now,
                isEdited: true
            )
        }
        return commit([.episodeChanged(episode, at: now)])
    }

    /// 放下 / 做完 / 放弃时自动整理这一段。fire-and-forget，不阻塞状态流转。
    /// 现场那份快照是异步存的，这里刻意不等它——事实取自段上的上下文，
    /// 同一批采集，不多绕一道。
    private func scheduleEpisodeSummary(for episodeID: UUID) {
        guard intelligencePreferences.autoSummarizeEpisodes else { return }
        Task { [weak self] in
            await self?.summarizeEpisode(episodeID)
        }
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
            pruneMemoryIndex()
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

    /// 执行现场恢复。只恢复用户选中的条目。
    /// 如果恢复来自等待结果（waitingID 非空），同时把等待标记为已解决、episode 恢复为 active。
    @discardableResult
    func restoreScene(
        _ snapshotID: UUID,
        selectedItemIDs: Set<UUID>? = nil,
        resolvingWaitingID: UUID? = nil,
        now: Date = Date()
    ) -> ContextRestoreReport {
        guard let sceneSnapshot = snapshot.sceneSnapshots[snapshotID] else {
            return ContextRestoreReport()
        }
        // 现场既已恢复，「已放下」确认卡的使命就结束了。
        if let aside = recentSetAside, aside.targetID == sceneSnapshot.targetID {
            recentSetAside = nil
        }
        var items = sceneSnapshot.restorableItems
        // 「换一件事」现场页里逐条划掉的不开。
        if let selectedItemIDs {
            items = items.filter { selectedItemIDs.contains($0.id) }
        }

        // 先完成等待/episode 状态流转，再执行恢复动作
        if let waitingID = resolvingWaitingID {
            _ = resumeWaitingEpisode(waitingID, now: now)
        }

        let restorer = MacContextRestorer()
        var capsule = ContextCapsule(capturedAt: sceneSnapshot.capturedAt)
        capsule.note = sceneSnapshot.returnCue

        // 地址是从事件日志里读回来的字符串；恢复时按种类校验 scheme，别的一概不开。
        for item in items {
            switch item.kind {
            case .file:
                if let url = URL(string: item.address), url.isFileURL { capsule.files.append(url) }
            case .link:
                if let url = URL(string: item.address),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    capsule.links.append(url)
                }
            case .terminal:
                if let url = URL(string: item.address), url.isFileURL {
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
    }

    private func commit(_ newEvents: [AttentionEvent]) -> Bool {
        guard !newEvents.isEmpty else { return true }
        guard isEventLogReadable else {
            lastError = Self.unreadableLogRefusalMessage
            return false
        }
        let proposedEvents = events + newEvents
        // 旧 snapshot 留一份给 note 用：新事件还没回放时才分得清「新建」和「改动」。
        let priorSnapshot = snapshot

        do {
            try store.save(events: proposedEvents)
            let persistedEvents = try store.load()
            events = persistedEvents
            snapshot = AttentionSnapshot.replay(persistedEvents)
            lastError = nil
            let note = SnapshotNote.summarize(newEvents, before: priorSnapshot)
            // 快照控制器监听这一通知去做去抖提交；这里只负责发出，不碰 git。
            // note 是给这批事件的一句话（用旧 snapshot 解析名字：新事件还没回放）。
            NotificationCenter.default.post(
                name: .lightAnchorEventsChanged,
                object: self,
                userInfo: ["note": note]
            )
            if newEvents.contains(where: { $0.kind == .episodeChanged }) {
                syncClipboardHistory(now: newEvents.last?.occurredAt ?? Date())
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
