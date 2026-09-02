import Foundation

enum AttentionEventKind: String, Codable, Equatable {
    case targetChanged
    case environmentChanged
    case episodeChanged
    case captureChanged
    case captureArchived
    case captureDeleted
    case waitingChanged
    case sceneSnapshotChanged
    case scheduledTaskChanged
    case scheduledTaskDeleted
    case scheduledFireChanged
    case recordingSessionChanged
    case recordingSessionDeleted
}

struct AttentionEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let occurredAt: Date
    let kind: AttentionEventKind
    let entityID: UUID
    let target: AttentionTarget?
    let environment: EnvironmentProfile?
    let episode: AttentionEpisode?
    let capture: CaptureItem?
    let waiting: WaitingItem?
    let sceneSnapshot: SceneSnapshot?
    let scheduledTask: ScheduledTask?
    let scheduledFire: ScheduledTaskFire?
    let recordingSession: RecordingSession?

    private init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        kind: AttentionEventKind,
        entityID: UUID,
        target: AttentionTarget? = nil,
        environment: EnvironmentProfile? = nil,
        episode: AttentionEpisode? = nil,
        capture: CaptureItem? = nil,
        waiting: WaitingItem? = nil,
        sceneSnapshot: SceneSnapshot? = nil,
        scheduledTask: ScheduledTask? = nil,
        scheduledFire: ScheduledTaskFire? = nil,
        recordingSession: RecordingSession? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.entityID = entityID
        self.target = target
        self.environment = environment
        self.episode = episode
        self.capture = capture
        self.waiting = waiting
        self.sceneSnapshot = sceneSnapshot
        self.scheduledTask = scheduledTask
        self.scheduledFire = scheduledFire
        self.recordingSession = recordingSession
    }

    static func targetChanged(_ target: AttentionTarget, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .targetChanged,
            entityID: target.id,
            target: target
        )
    }

    static func environmentChanged(_ environment: EnvironmentProfile, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .environmentChanged,
            entityID: environment.id,
            environment: environment
        )
    }

    static func episodeChanged(_ episode: AttentionEpisode, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .episodeChanged,
            entityID: episode.id,
            episode: episode
        )
    }

    static func captureChanged(_ capture: CaptureItem, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .captureChanged,
            entityID: capture.id,
            capture: capture
        )
    }

    static func captureArchived(_ capture: CaptureItem, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .captureArchived,
            entityID: capture.id,
            capture: capture
        )
    }

    static func captureDeleted(id: UUID, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .captureDeleted,
            entityID: id
        )
    }

    static func waitingChanged(_ waiting: WaitingItem, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .waitingChanged,
            entityID: waiting.id,
            waiting: waiting
        )
    }

    static func sceneSnapshotChanged(_ snapshot: SceneSnapshot, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .sceneSnapshotChanged,
            entityID: snapshot.id,
            sceneSnapshot: snapshot
        )
    }

    static func scheduledTaskChanged(_ task: ScheduledTask, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .scheduledTaskChanged,
            entityID: task.id,
            scheduledTask: task
        )
    }

    static func scheduledTaskDeleted(id: UUID, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .scheduledTaskDeleted,
            entityID: id
        )
    }

    static func scheduledFireChanged(_ fire: ScheduledTaskFire, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .scheduledFireChanged,
            entityID: fire.id,
            scheduledFire: fire
        )
    }

    static func recordingSessionChanged(_ session: RecordingSession, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .recordingSessionChanged,
            entityID: session.id,
            recordingSession: session
        )
    }

    static func recordingSessionDeleted(id: UUID, at date: Date = Date()) -> Self {
        Self(
            occurredAt: date,
            kind: .recordingSessionDeleted,
            entityID: id
        )
    }

    /// 物理清除事件日志里的现场事实。返回 nil 表示整条现场事件应移除；
    /// episode / waiting 的状态与用户备注保留，只擦掉采集到的上下文。
    func scrubbingSceneContent(capturedSince cutoff: Date?) -> Self? {
        func shouldScrub(_ capturedAt: Date) -> Bool {
            cutoff.map { capturedAt >= $0 } ?? true
        }

        switch kind {
        case .sceneSnapshotChanged:
            guard let sceneSnapshot,
                  shouldScrub(sceneSnapshot.capturedAt)
            else { return self }
            return nil

        case .episodeChanged:
            guard var episode,
                  episode.context.hasSceneContent,
                  shouldScrub(episode.context.capturedAt)
            else { return self }
            episode.context = episode.context.scrubbedSceneContent
            return replacing(episode: episode)

        case .waitingChanged:
            guard var waiting,
                  waiting.originalContext.hasSceneContent,
                  shouldScrub(waiting.originalContext.capturedAt)
            else { return self }
            waiting.originalContext = waiting.originalContext.scrubbedSceneContent
            return replacing(waiting: waiting)

        default:
            return self
        }
    }

    private func replacing(
        episode: AttentionEpisode? = nil,
        waiting: WaitingItem? = nil
    ) -> Self {
        Self(
            id: id,
            occurredAt: occurredAt,
            kind: kind,
            entityID: entityID,
            target: target,
            environment: environment,
            episode: episode ?? self.episode,
            capture: capture,
            waiting: waiting ?? self.waiting,
            sceneSnapshot: sceneSnapshot,
            scheduledTask: scheduledTask,
            scheduledFire: scheduledFire,
            recordingSession: recordingSession
        )
    }
}

struct AttentionSnapshot: Codable, Equatable {
    var targets: [UUID: AttentionTarget] = [:]
    var environments: [UUID: EnvironmentProfile] = [:]
    var episodes: [UUID: AttentionEpisode] = [:]
    var captures: [UUID: CaptureItem] = [:]
    var waitingItems: [UUID: WaitingItem] = [:]
    var sceneSnapshots: [UUID: SceneSnapshot] = [:]
    var scheduledTasks: [UUID: ScheduledTask] = [:]
    var scheduledFires: [UUID: ScheduledTaskFire] = [:]
    var recordingSessions: [UUID: RecordingSession] = [:]
    /// 每段工作累计的专注时长（只计 active/returning 的区间，暂停和等待
    /// 不计入）——回放 episodeChanged 事件时按状态迁移累加。
    var episodeFocusDurations: [UUID: TimeInterval] = [:]
    /// 仍在专注中的段：最近一次进入 active/returning 的时刻。
    var episodeFocusSince: [UUID: Date] = [:]
    var currentEpisodeID: UUID?


    static func replay(_ events: [AttentionEvent]) -> Self {
        var snapshot = Self()
        events.forEach { snapshot.apply($0) }

        // 从后往前找最近一件仍占着「现在」的前台工作。写成显式循环而不是
        // reversed().compactMap {}.first——后者在 Swift 6.1 上会被解析到
        // LazySequenceProtocol 的重载上编译失败，而且这样也不用建中间数组。
        snapshot.currentEpisodeID = nil
        for event in events.reversed() {
            guard event.kind == .episodeChanged,
                  let episode = event.episode,
                  let latest = snapshot.episodes[episode.id],
                  Self.occupiesNow(latest)
            else { continue }
            snapshot.currentEpisodeID = episode.id
            break
        }
        return snapshot
    }

    mutating func apply(_ event: AttentionEvent) {
        switch event.kind {
        case .targetChanged:
            guard let target = event.target else { return }
            targets[target.id] = target

        case .environmentChanged:
            guard let environment = event.environment else { return }
            environments[environment.id] = environment

        case .episodeChanged:
            guard let episode = event.episode else { return }
            accumulateFocus(for: episode, at: event.occurredAt)
            episodes[episode.id] = episode
            if Self.occupiesNow(episode) {
                currentEpisodeID = episode.id
            } else if currentEpisodeID == episode.id {
                // 手上这件放下/结束了：「现在」落到干净状态，
                // 不把之前放下的事顶回来——下一件由用户挑，不由它蹦。
                currentEpisodeID = nil
            }

        case .captureChanged, .captureArchived:
            guard let capture = event.capture else { return }
            captures[capture.id] = capture

        case .captureDeleted:
            captures.removeValue(forKey: event.entityID)

        case .waitingChanged:
            guard let waiting = event.waiting else { return }
            waitingItems[waiting.id] = waiting

        case .sceneSnapshotChanged:
            guard let sceneSnapshot = event.sceneSnapshot else { return }
            sceneSnapshots[sceneSnapshot.id] = sceneSnapshot

        case .scheduledTaskChanged:
            guard let scheduledTask = event.scheduledTask else { return }
            scheduledTasks[scheduledTask.id] = scheduledTask

        case .scheduledTaskDeleted:
            scheduledTasks.removeValue(forKey: event.entityID)

        case .scheduledFireChanged:
            guard let scheduledFire = event.scheduledFire else { return }
            scheduledFires[scheduledFire.id] = scheduledFire

        case .recordingSessionChanged:
            guard let recordingSession = event.recordingSession else { return }
            recordingSessions[recordingSession.id] = recordingSession

        case .recordingSessionDeleted:
            recordingSessions.removeValue(forKey: event.entityID)
        }
    }

    var currentEpisode: AttentionEpisode? {
        guard let currentEpisodeID else { return nil }
        return episodes[currentEpisodeID]
    }

    /// 「现在」只属于 进行中 / 回场 / 等待中 的前台段；
    /// 放下（paused）的事住在边缘（今天条 / 最近的事），不占现在页。
    private static func occupiesNow(_ episode: AttentionEpisode) -> Bool {
        !episode.isBackground
            && (episode.state == .active || episode.state == .returning || episode.state == .waiting)
    }

    /// active 和 returning 都算专注；paused / waiting / ended 让时钟停下。
    private static func isFocusState(_ state: AttentionEpisodeState) -> Bool {
        state == .active || state == .returning
    }

    private mutating func accumulateFocus(for episode: AttentionEpisode, at date: Date) {
        let wasFocused = episodes[episode.id].map { Self.isFocusState($0.state) } ?? false
        let isFocused = Self.isFocusState(episode.state)
        switch (wasFocused, isFocused) {
        case (false, true):
            // 首个事件用 startedAt——事件写入可能晚于实际开始。
            episodeFocusSince[episode.id] = episodes[episode.id] == nil ? episode.startedAt : date
        case (true, false):
            let since = episodeFocusSince.removeValue(forKey: episode.id) ?? episode.startedAt
            episodeFocusDurations[episode.id, default: 0] += max(0, date.timeIntervalSince(since))
        case (true, true), (false, false):
            break
        }
    }

    /// 一段工作到 `now` 为止的专注时长（暂停、等待期间不计）。
    func focusDuration(of episodeID: UUID, now: Date = Date()) -> TimeInterval {
        var total = episodeFocusDurations[episodeID] ?? 0
        if let episode = episodes[episodeID],
           Self.isFocusState(episode.state),
           let since = episodeFocusSince[episodeID] {
            total += max(0, now.timeIntervalSince(since))
        }
        return total
    }

    /// 专注分钟数（UI 用）。
    func focusMinutes(of episodeID: UUID, now: Date = Date()) -> Int {
        max(0, Int(focusDuration(of: episodeID, now: now) / 60))
    }

    /// 放下的未完成事：每个目标只取最新一段（paused、非后台），按放下时间倒序。
    /// 稍后页的「暂时放下」组和侧栏计数共用——完整列表，不做挑选。
    var setAsideEpisodes: [AttentionEpisode] {
        var newestByTarget: [UUID: AttentionEpisode] = [:]
        for episode in episodes.values
        where episode.state == .paused && !episode.isBackground {
            if let existing = newestByTarget[episode.targetID],
               existing.updatedAt >= episode.updatedAt {
                continue
            }
            newestByTarget[episode.targetID] = episode
        }
        return newestByTarget.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var inbox: [CaptureItem] {
        captures.values
            .filter { $0.status == .inbox }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    var referenceCaptures: [CaptureItem] {
        captures.values
            .filter { $0.status == .reference }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 归档不是黑洞：可浏览、可还原（工作记忆·稍后第三档）。
    var archivedCaptures: [CaptureItem] {
        captures.values
            .filter { $0.status == .archived }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 所有未删除捕获上出现过的标签（按名称排序），用于标签选择和筛选。
    var allCaptureTags: [String] {
        var seen = Set<String>()
        return captures.values
            .flatMap(\.tags)
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    var activeWaitingItems: [WaitingItem] {
        waitingItems.values
            .filter { $0.status == .waiting || $0.status == .ready }
            .sorted { $0.startedAt > $1.startedAt }
    }

    var readyWaitingItems: [WaitingItem] {
        waitingItems.values
            .filter { $0.status == .ready }
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
    }

    /// 排定中的定时任务，按触发时间升序（最近的先来）。
    var upcomingScheduledTasks: [ScheduledTask] {
        scheduledTasks.values
            .filter { $0.status == .scheduled }
            .sorted { $0.fireAt < $1.fireAt }
    }

    /// 全部触发史，新的在前。
    var allScheduledFires: [ScheduledTaskFire] {
        scheduledFires.values
            .sorted { $0.firedAt > $1.firedAt }
    }

    /// 全部录制会话，按开始时间倒序；进行中/暂停的排最前。
    var allRecordingSessions: [RecordingSession] {
        recordingSessions.values
            .sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.startedAt > $1.startedAt
            }
    }

    /// 正在进行（录制中或暂停）的会话——同一时刻至多一个，由协调器保证。
    var activeRecordingSession: RecordingSession? {
        recordingSessions.values
            .filter(\.isActive)
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    /// 某目标最新的现场快照（按捕获时间）。
    func latestSceneSnapshot(for targetID: UUID) -> SceneSnapshot? {
        sceneSnapshots.values
            .filter { $0.targetID == targetID }
            .sorted { $0.capturedAt > $1.capturedAt }
            .first
    }

    /// 当前目标最新的现场快照。
    var currentSceneSnapshot: SceneSnapshot? {
        guard let episode = currentEpisode else { return nil }
        return latestSceneSnapshot(for: episode.targetID)
    }
}
