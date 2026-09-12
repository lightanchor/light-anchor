import Foundation

// MARK: - 稍后清单的两组
//
// 「等待」不再是单独一页，它就是稍后清单上「等着别人」那一组。分组只问一句：
// 下一步在谁手里——这件事身上有没有一条还没等到的结果。**不看那段工作此刻是
// 什么状态**：一旦你真的去干别的，它自己会变成「放下」，可 CI 还在跑、合同还
// 没签回来，这件事仍然在等。稍后页、侧栏计数、换一件事面板共用这一份口径，
// 谁都别再自己重算一遍过滤条件。

/// 「可以动」的一条：一件放下的事，可能带着一条刚到的结果。
struct LaterActionableEntry: Identifiable, Equatable {
    let target: AttentionTarget
    let episode: AttentionEpisode
    /// 非空表示这条是刚解冻的：回去时连带把这条等待销账。
    let readyWaiting: WaitingItem?

    var id: UUID { episode.id }

    /// 刚从「等着别人」解冻过来——排在这一组最上面，行上标一句「结果到了」。
    var isThawed: Bool { readyWaiting != nil }

    var dueAt: Date? { target.dueAt }
}

/// 「等着别人」的一条：一条还没到的结果 + 它属于哪件事。
/// 一件事同时等好几个结果时就是好几条——「结果到了」得落在具体哪一条上，
/// 揉成一行就没法说清是哪个结果来了。
struct LaterBlockedEntry: Identifiable, Equatable {
    let target: AttentionTarget
    let waiting: WaitingItem

    var id: UUID { waiting.id }
}

struct LaterListProjection: Equatable {
    /// 球在你手里的事。刚解冻的在前，其余按放下时间。
    var actionable: [LaterActionableEntry]
    /// 球在别人手里的事。等得最久的在前——它最可能已经凉了。
    var blocked: [LaterBlockedEntry]

    var total: Int { actionable.count + blocked.count }

    /// 折起来那行尾巴要报的那一条：收着也得知道里面有没有火。
    /// 押了期限的排在最前，所以这里报的是**最近要到期的那条**；
    /// 一条都没押期限时，退回「等得最久的那条」。
    var blockedLead: WaitingItem? { blocked.first?.waiting }

    static func make(from snapshot: AttentionSnapshot) -> Self {
        // 正占着「现在」的那件事不进稍后：它就在眼前，列两遍是重影。
        let currentTargetID = snapshot.currentEpisode?.targetID

        func liveOwner(of waiting: WaitingItem) -> (AttentionTarget, AttentionEpisode)? {
            guard let episode = snapshot.episodes[waiting.episodeID],
                  episode.state != .ended,
                  episode.targetID != currentTargetID,
                  let target = snapshot.targets[episode.targetID]
            else { return nil }
            return (target, episode)
        }

        // 先认「结果到了」：有东西到了就该去看它，哪怕这件事还在等别的结果。
        var claimed: Set<UUID> = []
        var actionable: [LaterActionableEntry] = []
        for waiting in snapshot.readyWaitingItems {
            guard let (target, episode) = liveOwner(of: waiting),
                  claimed.insert(target.id).inserted
            else { continue }
            actionable.append(
                LaterActionableEntry(target: target, episode: episode, readyWaiting: waiting)
            )
        }

        var blocked: [LaterBlockedEntry] = []
        var blockedTargetIDs: Set<UUID> = []
        for waiting in snapshot.waitingItems.values
            .filter({ $0.status == .waiting })
            .sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let (target, _) = liveOwner(of: waiting),
                  !claimed.contains(target.id)
            else { continue }
            blocked.append(LaterBlockedEntry(target: target, waiting: waiting))
            blockedTargetIDs.insert(target.id)
        }

        // 剩下的放下的事：没人替你推进，什么时候回去你说了算。
        // 押了期限的往上排、没押的往下沉——日期不是分组条件，只管顺序。
        var setAside: [LaterActionableEntry] = []
        for episode in snapshot.setAsideEpisodes
        where episode.targetID != currentTargetID
            && !claimed.contains(episode.targetID)
            && !blockedTargetIDs.contains(episode.targetID) {
            guard let target = snapshot.targets[episode.targetID] else { continue }
            setAside.append(
                LaterActionableEntry(target: target, episode: episode, readyWaiting: nil)
            )
        }
        setAside.sort { lhs, rhs in
            switch (lhs.dueAt, rhs.dueAt) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.episode.updatedAt > rhs.episode.updatedAt
            }
        }
        actionable += setAside

        // 等着别人的：押了期限的按期限排在最前，其余按等得最久。
        blocked.sort { lhs, rhs in
            switch (lhs.waiting.dueAt, rhs.waiting.dueAt) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.waiting.startedAt < rhs.waiting.startedAt
            }
        }

        return Self(actionable: actionable, blocked: blocked)
    }
}

extension AttentionSnapshot {
    var laterList: LaterListProjection {
        LaterListProjection.make(from: self)
    }
}
