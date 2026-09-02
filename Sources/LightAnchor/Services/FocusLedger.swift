import Foundation

// MARK: - 时间账本
//
// 从事件流重建专注分段：active / returning 计时，paused / waiting / ended
// 停表——与快照 accumulateFocus 的迁移语义一致。分段按天切开，所以
// 跨午夜的一段工作会诚实地记在两天上。只陈述事实，不打分。

/// 一段连续的专注区间（已按天切开，end 不跨午夜）。
struct FocusLedgerSegment: Equatable, Sendable {
    let targetID: UUID
    let episodeID: UUID
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// 某目标在一个周期内的专注事实。
struct FocusTargetStat: Equatable, Identifiable {
    let targetID: UUID
    let duration: TimeInterval
    let segmentCount: Int

    var id: UUID { targetID }
}

/// 一个周期（日/周/月）的注意力事实汇总。
struct FocusPeriodSummary: Equatable {
    let interval: DateInterval
    let focusDuration: TimeInterval
    let segmentCount: Int
    /// 按时长降序。
    let targetStats: [FocusTargetStat]
    /// 期内完成的目标段数（不含后台 episode）。
    let completedCount: Int
    /// 期内到达「可以返回」的等待结果数（按状态迁移计，重开再完成算两次）。
    let readyWaitingCount: Int
    /// 期内捕获的内容条数。
    let captureCount: Int
}

enum FocusLedger {
    private static func isFocusState(_ state: AttentionEpisodeState) -> Bool {
        state == .active || state == .returning
    }

    /// 重建全部专注分段（按天切开、按开始时间排序）。
    /// 进行中的段用 `now` 收口。
    static func segments(
        events: [AttentionEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> [FocusLedgerSegment] {
        struct Track {
            var state: AttentionEpisodeState
            var focusSince: Date?
            var targetID: UUID
        }
        var tracks: [UUID: Track] = [:]
        var raw: [(targetID: UUID, episodeID: UUID, start: Date, end: Date)] = []

        for event in events {
            guard event.kind == .episodeChanged, let episode = event.episode else { continue }
            let previous = tracks[episode.id]
            let wasFocused = previous.map { isFocusState($0.state) } ?? false
            let nowFocused = isFocusState(episode.state)

            var track = previous ?? Track(state: episode.state, focusSince: nil, targetID: episode.targetID)
            switch (wasFocused, nowFocused) {
            case (false, true):
                // 首个事件用 startedAt——事件写入可能晚于实际开始。
                track.focusSince = previous == nil ? episode.startedAt : event.occurredAt
            case (true, false):
                let since = track.focusSince ?? episode.startedAt
                if event.occurredAt > since {
                    raw.append((episode.targetID, episode.id, since, event.occurredAt))
                }
                track.focusSince = nil
            case (true, true), (false, false):
                break
            }
            track.state = episode.state
            track.targetID = episode.targetID
            tracks[episode.id] = track
        }

        // 仍在专注中的段：用 now 收口。
        for (episodeID, track) in tracks
        where isFocusState(track.state) {
            let since = track.focusSince ?? now
            if now > since {
                raw.append((track.targetID, episodeID, since, now))
            }
        }

        return raw
            .flatMap { splitAtMidnights($0, calendar: calendar) }
            .sorted { $0.start < $1.start }
    }

    private static func splitAtMidnights(
        _ segment: (targetID: UUID, episodeID: UUID, start: Date, end: Date),
        calendar: Calendar
    ) -> [FocusLedgerSegment] {
        var result: [FocusLedgerSegment] = []
        var cursor = segment.start
        while cursor < segment.end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let sliceEnd = min(segment.end, nextDay)
            if sliceEnd > cursor {
                result.append(FocusLedgerSegment(
                    targetID: segment.targetID,
                    episodeID: segment.episodeID,
                    start: cursor,
                    end: sliceEnd
                ))
            }
            cursor = sliceEnd
        }
        return result
    }

    /// 天（startOfDay）→ 专注时长，热力图的时长档用。
    static func dayDurations(
        segments: [FocusLedgerSegment],
        calendar: Calendar = .current
    ) -> [Date: TimeInterval] {
        var totals: [Date: TimeInterval] = [:]
        for segment in segments {
            totals[calendar.startOfDay(for: segment.start), default: 0] += segment.duration
        }
        return totals
    }

    /// 一个周期的注意力事实汇总。
    static func summary(
        events: [AttentionEvent],
        interval: DateInterval,
        now: Date,
        calendar: Calendar = .current
    ) -> FocusPeriodSummary {
        let clipped = segments(events: events, now: now, calendar: calendar)
            .compactMap { segment -> FocusLedgerSegment? in
                let start = max(segment.start, interval.start)
                let end = min(segment.end, interval.end)
                guard end > start else { return nil }
                return FocusLedgerSegment(
                    targetID: segment.targetID,
                    episodeID: segment.episodeID,
                    start: start,
                    end: end
                )
            }

        var perTarget: [UUID: (duration: TimeInterval, count: Int)] = [:]
        for segment in clipped {
            var entry = perTarget[segment.targetID] ?? (0, 0)
            entry.duration += segment.duration
            entry.count += 1
            perTarget[segment.targetID] = entry
        }
        let targetStats = perTarget
            .map { FocusTargetStat(targetID: $0.key, duration: $0.value.duration, segmentCount: $0.value.count) }
            .sorted {
                if $0.duration != $1.duration { return $0.duration > $1.duration }
                return $0.targetID.uuidString < $1.targetID.uuidString
            }

        var completedEpisodeIDs = Set<UUID>()
        var readyTransitionCount = 0
        var previousWaitingStatus: [UUID: WaitingStatus] = [:]
        var capturedIDs = Set<UUID>()

        for event in events {
            switch event.kind {
            case .episodeChanged:
                guard let episode = event.episode,
                      episode.state == .ended,
                      episode.endedReason == .completed,
                      interval.contains(event.occurredAt)
                else { break }
                completedEpisodeIDs.insert(episode.id)

            case .waitingChanged:
                guard let waiting = event.waiting else { break }
                let previous = previousWaitingStatus[waiting.id]
                if waiting.status == .ready,
                   previous != .ready,
                   interval.contains(event.occurredAt) {
                    readyTransitionCount += 1
                }
                previousWaitingStatus[waiting.id] = waiting.status

            case .captureChanged:
                guard let capture = event.capture,
                      interval.contains(capture.capturedAt)
                else { break }
                capturedIDs.insert(capture.id)

            default:
                break
            }
        }

        return FocusPeriodSummary(
            interval: interval,
            focusDuration: clipped.reduce(0) { $0 + $1.duration },
            segmentCount: clipped.count,
            targetStats: targetStats,
            completedCount: completedEpisodeIDs.count,
            readyWaitingCount: readyTransitionCount,
            captureCount: capturedIDs.count
        )
    }
}

// MARK: - 回顾周期（日 / 周 / 月，可前后翻）

enum ReviewPeriodUnit: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: tr("day")
        case .week: tr("week")
        case .month: tr("month")
        }
    }
}

/// 回顾页的周期选择：单位 + 相对当前期的偏移（0 = 本期，-1 = 上一期）。
struct ReviewPeriod: Equatable {
    var unit: ReviewPeriodUnit
    var offset: Int

    static let currentWeek = ReviewPeriod(unit: .week, offset: 0)

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component = switch unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        let anchor = calendar.date(byAdding: component, value: offset, to: now) ?? now
        return calendar.dateInterval(of: component, for: anchor)
            ?? DateInterval(start: anchor, duration: 24 * 3600)
    }

    /// 「本周」「8月18日–8月24日」式的标题。
    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        if offset == 0 {
            switch unit {
            case .day: return tr("today")
            case .week: return tr("this_week")
            case .month: return tr("this_month")
            }
        }
        if offset == -1 {
            switch unit {
            case .day: return tr("yesterday_period")
            case .week: return tr("last_week")
            case .month: return tr("last_month")
            }
        }
        let interval = interval(now: now, calendar: calendar)
        switch unit {
        case .day:
            return interval.start.formatted(.dateTime.month().day())
        case .week:
            let endDay = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(.dateTime.month().day()))–\(endDay.formatted(.dateTime.month().day()))"
        case .month:
            return interval.start.formatted(.dateTime.year().month())
        }
    }
}
