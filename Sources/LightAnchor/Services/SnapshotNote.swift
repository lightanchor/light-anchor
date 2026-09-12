import Foundation

struct SnapshotNote: Sendable, Equatable {
    let subject: String
    var isBackground = false
    var captureCount = 0

    static func summarize(_ events: [AttentionEvent], before snapshot: AttentionSnapshot) -> Self {
        func named(_ format: String, _ name: String) -> Self {
            Self(subject: String(format: format, clipped(name)))
        }

        func targetName(_ targetID: UUID) -> String {
            events.last { $0.target?.id == targetID }?.target?.name
                ?? snapshot.targets[targetID]?.name
                ?? tr("snapshot_note_unnamed_work")
        }

        let transitions = events.compactMap(\.episode).filter {
            snapshot.episodes[$0.id]?.state != $0.state
        }
        if let episode = transitions.last(where: { $0.state != .paused }) {
            let name = targetName(episode.targetID)
            switch episode.state {
            case .active, .returning:
                if let current = snapshot.currentEpisode, current.targetID != episode.targetID {
                    return named(tr("snapshot_note_switched"), name)
                }
                return named(
                    snapshot.episodes[episode.id] == nil
                        ? tr("snapshot_note_started") : tr("snapshot_note_resumed"),
                    name
                )
            case .ended:
                return named(
                    episode.endedReason == .abandoned
                        ? tr("snapshot_note_abandoned") : tr("snapshot_note_completed"),
                    name
                )
            case .paused:
                break
            }
        }

        if let waiting = events.compactMap(\.waiting).last {
            let previous = snapshot.waitingItems[waiting.id]
            if previous == nil || previous?.status != waiting.status {
                switch waiting.status {
                case .waiting: return named(tr("snapshot_note_waiting"), waiting.description)
                case .ready: return named(tr("snapshot_note_waiting_ready"), waiting.description)
                case .resolved: return named(tr("snapshot_note_waiting_resolved"), waiting.description)
                case .cancelled: return named(tr("snapshot_note_waiting_cancelled"), waiting.description)
                }
            }
        }

        if let episode = transitions.last {
            return named(tr("snapshot_note_paused"), targetName(episode.targetID))
        }
        if let target = events.compactMap(\.target).last {
            return named(
                snapshot.targets[target.id] == nil ? tr("snapshot_note_created") : tr("snapshot_note_target_updated"),
                target.name
            )
        }

        let newCaptures = Set(events.filter {
            $0.kind == .captureChanged && snapshot.captures[$0.entityID] == nil
        }.map(\.entityID))
        if !newCaptures.isEmpty {
            return Self(subject: captureSubject(count: newCaptures.count), captureCount: newCaptures.count)
        }
        if events.contains(where: { $0.kind == .captureDeleted || $0.kind == .captureArchived }) {
            return Self(subject: tr("snapshot_note_inbox_organized"))
        }
        if events.contains(where: { $0.kind == .scheduledTaskChanged || $0.kind == .scheduledTaskDeleted }) {
            return Self(subject: tr("snapshot_note_schedule_updated"))
        }
        if events.contains(where: { $0.kind == .environmentChanged }) {
            return Self(subject: tr("snapshot_note_environment_updated"))
        }
        if events.contains(where: { $0.kind == .recordingSessionChanged || $0.kind == .recordingSessionDeleted }) {
            return Self(subject: tr("snapshot_note_recording_updated"), isBackground: true)
        }
        if events.contains(where: { $0.kind == .sceneSnapshotChanged }) {
            return Self(subject: tr("snapshot_note_scene_saved"), isBackground: true)
        }
        if let episode = events.compactMap(\.episode).last {
            return Self(
                subject: String(format: tr("snapshot_note_context_updated"), clipped(targetName(episode.targetID))),
                isBackground: true
            )
        }
        if events.contains(where: { $0.kind == .captureChanged }) {
            return Self(subject: tr("snapshot_note_capture_updated"), isBackground: true)
        }
        if events.contains(where: { $0.kind == .waitingChanged }) {
            return Self(subject: tr("snapshot_note_waiting_updated"), isBackground: true)
        }
        if events.contains(where: { $0.kind == .scheduledFireChanged }) {
            return Self(subject: tr("snapshot_note_schedule_fired"), isBackground: true)
        }
        return Self(subject: tr("snapshot_note_saved"), isBackground: true)
    }

    static func combined(_ notes: [Self]) -> String {
        let actions = notes.filter { !$0.isBackground }
        let captureCount = actions.reduce(0) { $0 + $1.captureCount }
        var subjects: [String] = []
        for note in actions.isEmpty ? notes : actions {
            let text = note.captureCount > 0 ? captureSubject(count: captureCount) : note.subject
            let subject = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !subject.isEmpty, !subjects.contains(subject) {
                subjects.append(subject)
            }
        }
        guard !subjects.isEmpty else { return tr("snapshot_note_saved") }
        let summary = subjects.prefix(3).joined(separator: tr("snapshot_note_separator"))
        return subjects.count > 3
            ? summary + String(format: tr("snapshot_note_more"), subjects.count - 3)
            : summary
    }

    private static func captureSubject(count: Int) -> String {
        count == 1 ? tr("snapshot_note_captured_one") : String(format: tr("snapshot_note_captured_many"), count)
    }

    private static func clipped(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return singleLine.count > 24 ? String(singleLine.prefix(24)) + "…" : singleLine
    }
}
