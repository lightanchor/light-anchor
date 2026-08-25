import Foundation

enum WaitingSurfaceStatus: String, Codable, Equatable, Sendable {
    case waiting
    case ready
}

struct WaitingSurfaceItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let targetTitle: String
    let status: WaitingSurfaceStatus
    let evidence: String
    let startedAt: Date
    let completedAt: Date?

    var detail: String {
        switch status {
        case .waiting:
            String(format: tr("waiting_on_target"), targetTitle)
        case .ready:
            String(format: tr("done_with_detail"), evidence.isEmpty ? targetTitle : evidence)
        }
    }
}

struct WaitingSurfaceSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let waitingCount: Int
    let readyCount: Int
    let items: [WaitingSurfaceItem]

    var summary: String {
        if readyCount > 0 {
            return String(
                format: readyCount == 1
                    ? tr("n_results_ready_to_return_one") : tr("n_results_ready_to_return"),
                readyCount
            )
        }
        if waitingCount > 0 {
            return String(
                format: waitingCount == 1 ? tr("n_still_waiting_one") : tr("n_still_waiting"),
                waitingCount
            )
        }
        return tr("nothing_is_waiting")
    }

    static func make(
        from snapshot: AttentionSnapshot,
        now: Date = Date(),
        limit: Int = 3
    ) -> Self {
        let waiting = snapshot.activeWaitingItems.filter { $0.status == .waiting }
        let ready = snapshot.readyWaitingItems
        let ordered = ready + waiting
        let items = ordered.prefix(max(limit, 0)).map { waitingItem in
            let targetTitle = snapshot.episodes[waitingItem.episodeID]
                .flatMap { snapshot.targets[$0.targetID]?.name }
                ?? tr("untitled_target")
            return WaitingSurfaceItem(
                id: waitingItem.id,
                title: waitingItem.description,
                targetTitle: targetTitle,
                status: waitingItem.status == .ready ? .ready : .waiting,
                evidence: waitingItem.evidence,
                startedAt: waitingItem.startedAt,
                completedAt: waitingItem.completedAt
            )
        }
        return Self(
            generatedAt: now,
            waitingCount: waiting.count,
            readyCount: ready.count,
            items: Array(items)
        )
    }
}

extension AttentionSnapshot {
    var waitingSurface: WaitingSurfaceSnapshot {
        WaitingSurfaceSnapshot.make(from: self)
    }
}
