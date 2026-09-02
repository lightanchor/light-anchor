import Foundation

/// 一段可读的近期工作经过。它由现有事件、episode、等待与现场推导，
/// 不额外记录点击、按键或连续截图。
struct RecentWorkTrace: Identifiable, Equatable {
    let episodeID: UUID
    let targetID: UUID
    let targetTitle: String
    let startedAt: Date
    let endedAt: Date?
    let lastActivityAt: Date
    let state: AttentionEpisodeState
    let endedReason: AttentionEpisodeEndReason?
    let focusDuration: TimeInterval
    let summary: String
    let nextCue: String
    let applications: [String]
    let waitingItems: [WaitingItem]
    let sceneSnapshot: SceneSnapshot?

    var id: UUID { episodeID }

    var statusTitle: String {
        if endedReason == .completed { return tr("completed") }
        if endedReason == .abandoned { return tr("abandoned") }
        switch state {
        case .active: return tr("active")
        case .paused: return tr("paused")
        case .waiting: return tr("waiting_3")
        case .returning: return tr("returning")
        case .ended: return tr("ended")
        }
    }
}

enum WorkHistoryBuilder {
    static func traces(
        events: [AttentionEvent],
        snapshot: AttentionSnapshot,
        interval: DateInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RecentWorkTrace] {
        let focusSegments = FocusLedger.segments(events: events, now: now, calendar: calendar)
        var focusByEpisode: [UUID: TimeInterval] = [:]
        for segment in focusSegments {
            let start = max(segment.start, interval.start)
            let end = min(segment.end, interval.end)
            guard end > start else { continue }
            focusByEpisode[segment.episodeID, default: 0] += end.timeIntervalSince(start)
        }

        let scenesByEpisode = Dictionary(grouping: snapshot.sceneSnapshots.values.compactMap {
            scene -> (UUID, SceneSnapshot)? in
            guard let episodeID = scene.episodeID else { return nil }
            return (episodeID, scene)
        }, by: \.0)
        let waitsByEpisode = Dictionary(grouping: snapshot.waitingItems.values, by: \.episodeID)

        return snapshot.episodes.values.compactMap { episode in
            let waits = (waitsByEpisode[episode.id] ?? [])
                .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
            let scene = scenesByEpisode[episode.id]?
                .map(\.1)
                .max(by: { $0.capturedAt < $1.capturedAt })
            let focusDuration = focusByEpisode[episode.id] ?? 0
            guard isRelevant(
                episode: episode,
                scene: scene,
                waits: waits,
                focusDuration: focusDuration,
                interval: interval
            ) else { return nil }

            let target = snapshot.targets[episode.targetID]
            let nextCue = firstNonempty(scene?.returnCue, episode.returnCue)
            let summary = summary(
                episode: episode,
                targetNote: target?.note ?? "",
                scene: scene,
                waits: waits
            )
            let applications = orderedUnique(
                (scene?.items ?? []).compactMap { item in
                    let source = item.sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !source.isEmpty { return source }
                    return item.kind == .application ? item.title : nil
                }
            )
            let lastActivity = [
                episode.endedAt,
                Optional(episode.updatedAt),
                scene?.capturedAt,
                waits.first?.completedAt,
                waits.first?.startedAt
            ].compactMap { $0 }.max() ?? episode.startedAt

            return RecentWorkTrace(
                episodeID: episode.id,
                targetID: episode.targetID,
                targetTitle: target?.name ?? tr("deleted_focus"),
                startedAt: episode.startedAt,
                endedAt: episode.endedAt,
                lastActivityAt: lastActivity,
                state: episode.state,
                endedReason: episode.endedReason,
                focusDuration: focusDuration,
                summary: summary,
                nextCue: nextCue,
                applications: applications,
                waitingItems: waits,
                sceneSnapshot: scene
            )
        }
        .sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.startedAt > $1.startedAt
        }
    }

    private static func isRelevant(
        episode: AttentionEpisode,
        scene: SceneSnapshot?,
        waits: [WaitingItem],
        focusDuration: TimeInterval,
        interval: DateInterval
    ) -> Bool {
        if focusDuration > 0 { return true }
        if interval.contains(episode.startedAt) || interval.contains(episode.updatedAt) { return true }
        if let endedAt = episode.endedAt, interval.contains(endedAt) { return true }
        if let scene, interval.contains(scene.capturedAt) { return true }
        return waits.contains {
            interval.contains($0.startedAt)
                || $0.completedAt.map(interval.contains) == true
        }
    }

    private static func summary(
        episode: AttentionEpisode,
        targetNote: String,
        scene: SceneSnapshot?,
        waits: [WaitingItem]
    ) -> String {
        let completedEvidence = waits
            .filter { $0.status == .ready || $0.status == .resolved }
            .map(\.evidence)
            .first(where: { !$0.isEmpty })
        if let evidence = completedEvidence {
            return evidence
        }
        if let waiting = waits.first(where: { $0.status == .waiting }),
           !waiting.description.isEmpty {
            return String(format: tr("waiting_for"), waiting.description)
        }
        let cue = firstNonempty(scene?.returnCue, episode.returnCue)
        if !cue.isEmpty {
            return cue
        }
        let note = targetNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        if episode.endedReason == .completed { return tr("this_work_session_was_completed") }
        if episode.endedReason == .abandoned { return tr("this_work_session_was_abandoned") }
        switch episode.state {
        case .active, .returning: return tr("this_work_session_is_still_active")
        case .paused: return tr("this_work_session_is_paused_and")
        case .waiting: return tr("this_work_session_is_waiting_for")
        case .ended: return tr("this_work_session_has_ended")
        }
    }

    private static func firstNonempty(_ values: String?...) -> String {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
