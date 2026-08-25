import Foundation

// MARK: - 应用内工作记忆的检索层
//
// 纯函数：输入事件流与快照，输出带来源标注的事实行。只读用户主动留下的记录
// （专注分段、等待、捕获、现场、今天层），不做任何被动采集；
// 剪贴板内容、终端命令这类现场细节一律不进事实行——喂给模型的只有可复述的事实。

/// 一条带来源标注的记忆事实。label 是来源类别（现在/今天/账本/目标/工作/等待/捕获），
/// text 是一句可复述的中文事实。模型只许复述这些行，「对话」页用它渲染「依据」。
struct MemoryFact: Equatable, Sendable {
    let label: String
    let text: String

    var line: String { "[\(label)] \(text)" }
}

/// 一次「问记忆」的检索结果：时间范围标题 + 事实行。
struct MemoryQuestionContext: Equatable, Sendable {
    var periodTitle: String
    var facts: [MemoryFact]

    var factLines: [String] { facts.map(\.line) }
}

enum MemoryRecall {
    /// 事实行上限：再多模型也读不过来，检索质量靠排序不靠堆量。
    static let maximumFacts = 30

    // MARK: - 问答检索

    static func questionContext(
        question: String,
        events: [AttentionEvent],
        snapshot: AttentionSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        includeCaptureSearch: Bool = true
    ) -> MemoryQuestionContext {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parsedPeriod(question: trimmed, now: now, calendar: calendar)
        let interval = parsed?.interval ?? defaultInterval(now: now, calendar: calendar)
        let periodTitle = parsed?.title ?? tr("last_7_days")

        var facts: [MemoryFact] = []

        // 现在：当前这一件事。永远给一行，让「我现在在干嘛」有落点。
        if let episodeID = snapshot.currentEpisodeID,
           let episode = snapshot.episodes[episodeID],
           let target = snapshot.targets[episode.targetID] {
            var text = String(
                format: tr("working_on_name_focused_for"),
                target.name,
                durationText(snapshot.focusDuration(of: episodeID, now: now))
            )
            if !episode.returnCue.isEmpty {
                text += String(format: tr("semicolon_look_at_first"), episode.returnCue)
            }
            facts.append(MemoryFact(label: tr("fact_label_now"), text: text))
        } else {
            facts.append(
                MemoryFact(label: tr("fact_label_now"), text: tr("no_work_in_progress_right_now"))
            )
        }

        // 账本：范围内的总量与去向。
        let summary = FocusLedger.summary(events: events, interval: interval, now: now, calendar: calendar)
        if summary.segmentCount > 0 {
            var text = String(
                format: tr("period_total_focus_and_segments"),
                periodTitle,
                durationText(summary.focusDuration),
                summary.segmentCount
            )
            if summary.completedCount > 0 {
                text += String(format: tr("semicolon_n_finished"), summary.completedCount)
            }
            if summary.captureCount > 0 {
                text += String(format: tr("semicolon_n_captured"), summary.captureCount)
            }
            facts.append(MemoryFact(label: tr("fact_label_ledger"), text: text))

            let topStats = summary.targetStats.prefix(3).compactMap { stat -> String? in
                guard stat.duration >= 60 else { return nil }
                let name = snapshot.targets[stat.targetID]?.name ?? tr("a_deleted_target")
                let share = summary.focusDuration > 0
                    ? Int((stat.duration / summary.focusDuration * 100).rounded())
                    : 0
                return String(
                    format: tr("name_duration_share"),
                    name,
                    durationText(stat.duration),
                    share
                )
            }
            if !topStats.isEmpty {
                facts.append(
                    MemoryFact(
                        label: tr("fact_label_ledger"),
                        text: String(
                            format: tr("mostly_spent_on"),
                            topStats.joined(separator: tr("list_joiner"))
                        )
                    )
                )
            }
        } else {
            facts.append(
                MemoryFact(
                    label: tr("fact_label_ledger"),
                    text: String(format: tr("no_focus_records_in_period"), periodTitle)
                )
            )
        }

        // 目标历史：问题里点名的事，给全程纵深（不限本次时间范围）。
        let matchedTargets = matchedTargets(question: trimmed, snapshot: snapshot)
        for target in matchedTargets.prefix(3) {
            if let digest = targetHistoryDigest(
                targetID: target.id,
                targetName: target.name,
                events: events,
                snapshot: snapshot,
                now: now,
                calendar: calendar
            ) {
                facts.append(digest)
            }
        }

        // 工作经过：范围内每段可读的经过（复用回顾页的 trace 推导）。
        let traces = WorkHistoryBuilder.traces(
            events: events,
            snapshot: snapshot,
            interval: interval,
            now: now,
            calendar: calendar
        )
        for trace in traces.prefix(6) {
            var text = String(
                format: tr("quoted_name_date"),
                trace.targetTitle,
                dateText(trace.lastActivityAt)
            )
            if trace.focusDuration >= 60 {
                text += String(format: tr("dot_focused"), durationText(trace.focusDuration))
            }
            if !trace.summary.isEmpty {
                text += String(format: tr("semicolon_text"), trace.summary)
            }
            if !trace.nextCue.isEmpty {
                text += String(format: tr("semicolon_next_step"), trace.nextCue)
            }
            facts.append(MemoryFact(label: tr("fact_label_work"), text: clipped(text, limit: 140)))
        }

        // 等待面：可返回的优先。
        for waiting in snapshot.readyWaitingItems.prefix(3) {
            var text = String(format: tr("ready_to_return_to"), waiting.description)
            if !waiting.evidence.isEmpty {
                text += String(format: tr("parenthetical"), clipped(waiting.evidence, limit: 60))
            }
            facts.append(MemoryFact(label: tr("fact_label_waiting"), text: text))
        }
        for waiting in snapshot.waitingItems.values
            .filter({ $0.status == .waiting })
            .sorted(by: { $0.startedAt > $1.startedAt })
            .prefix(3) {
            let text = String(
                format: tr("waiting_on_for_duration"),
                waiting.description,
                durationText(now.timeIntervalSince(waiting.startedAt))
            )
            facts.append(MemoryFact(label: tr("fact_label_waiting"), text: text))
        }

        // 捕获检索：按问题关键词打分（标题>标签>正文>截图文字），归档也可及。
        // 「对话」页已改走 MemoryIndex（FTS5+向量），传 includeCaptureSearch: false；
        // 这一段留给不经索引的同步调用方与测试。
        let fragments = includeCaptureSearch ? searchFragments(question: trimmed) : []
        if !fragments.isEmpty {
            let scored = snapshot.captures.values
                .filter { $0.status != .attached }
                .compactMap { capture -> (CaptureItem, Double)? in
                    let fields = [
                        WorkspaceSearchScoring.Field(capture.title ?? "", weight: WorkspaceSearchScoring.titleWeight),
                        WorkspaceSearchScoring.Field(capture.tags.joined(separator: " "), weight: WorkspaceSearchScoring.tagWeight),
                        WorkspaceSearchScoring.Field(capture.body, weight: WorkspaceSearchScoring.bodyWeight),
                        WorkspaceSearchScoring.Field(capture.extractedText, weight: WorkspaceSearchScoring.extractedWeight)
                    ]
                    guard let best = bestScore(
                        fragments: fragments,
                        fields: fields,
                        recency: capture.capturedAt,
                        now: now
                    ) else { return nil }
                    return (capture, best)
                }
                .sorted { $0.1 > $1.1 }
            for (capture, _) in scored.prefix(6) {
                let title = capture.title?.isEmpty == false ? (capture.title ?? "") : capture.body
                let summaryText = title.isEmpty ? (capture.sourceURL?.absoluteString ?? "") : title
                var text = String(
                    format: tr("capture_fact_line"),
                    dateText(capture.capturedAt),
                    statusTitle(capture.status),
                    capture.kind.title,
                    clipped(summaryText, limit: 60)
                )
                if let app = capture.sourceApplication, !app.isEmpty {
                    text += String(format: tr("parenthetical_from_app"), app)
                }
                facts.append(MemoryFact(label: tr("fact_label_capture"), text: text))
            }
        }

        return MemoryQuestionContext(
            periodTitle: periodTitle,
            facts: Array(facts.prefix(maximumFacts))
        )
    }

    /// 一个目标的全程纵深（结构化）：供问答检索、回场简报、现在页共用。
    struct TargetHistoryDigest: Equatable, Sendable {
        let totalFocus: TimeInterval
        let segmentCount: Int
        let lastEnd: Date?
        let lastCue: String
    }

    static func targetHistory(
        targetID: UUID,
        events: [AttentionEvent],
        snapshot: AttentionSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TargetHistoryDigest? {
        let segments = FocusLedger.segments(events: events, now: now, calendar: calendar)
            .filter { snapshot.episodes[$0.episodeID]?.targetID == targetID }
        guard !segments.isEmpty else { return nil }
        return TargetHistoryDigest(
            totalFocus: segments.reduce(0) { $0 + $1.duration },
            segmentCount: segments.count,
            lastEnd: segments.map(\.end).max(),
            lastCue: snapshot.latestSceneSnapshot(for: targetID)?.returnCue ?? ""
        )
    }

    /// 问答用的目标事实行。
    static func targetHistoryDigest(
        targetID: UUID,
        targetName: String,
        events: [AttentionEvent],
        snapshot: AttentionSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MemoryFact? {
        guard let digest = targetHistory(
            targetID: targetID, events: events, snapshot: snapshot, now: now, calendar: calendar
        ) else { return nil }
        return MemoryFact(
            label: tr("fact_label_target"),
            text: briefingHistoryLine(targetName: targetName, digest: digest)
        )
    }

    /// 回场简报里「这件事的历史」一句话。
    static func briefingHistoryLine(targetName: String, digest: TargetHistoryDigest) -> String {
        var text = String(
            format: digest.segmentCount == 1
                ? tr("name_total_focus_and_segments_one") : tr("name_total_focus_and_segments"),
            targetName,
            durationText(digest.totalFocus),
            digest.segmentCount
        )
        if let last = digest.lastEnd {
            text += String(format: tr("semicolon_last_time"), dateText(last))
        }
        if !digest.lastCue.isEmpty {
            text += String(format: tr("semicolon_last_cue"), clipped(digest.lastCue, limit: 40))
        }
        return text
    }

    /// 现在页 hero 的历史小字：「累计 6 小时 40 分 · 9 段 · 上次 8月20日」。
    /// 只有一段历史时不值得说，返回 nil。
    static func targetHistoryLine(_ digest: TargetHistoryDigest) -> String? {
        guard digest.segmentCount >= 2, digest.totalFocus >= 300 else { return nil }
        var parts = [
            String(format: tr("total_duration"), durationText(digest.totalFocus)),
            String(
                format: digest.segmentCount == 1 ? tr("n_segments_one") : tr("n_segments"),
                digest.segmentCount
            )
        ]
        if let last = digest.lastEnd {
            parts.append(String(format: tr("last_time_date"), dateText(last)))
        }
        return parts.joined(separator: " · ")
    }

    /// 一条捕获的「历史去向」提示：同域名的历史捕获最终去了哪（其次同标签）。
    /// 样本少于 2 条不说话——提示必须有据。
    static func captureDispositionHint(
        for capture: CaptureItem,
        snapshot: AttentionSnapshot,
        now: Date = Date()
    ) -> String {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let settled = snapshot.captures.values.filter {
            $0.id != capture.id
                && ($0.status == .reference || $0.status == .archived)
                && $0.capturedAt >= cutoff
        }

        if let host = capture.sourceURL?.host {
            let sameHost = settled.filter { $0.sourceURL?.host == host }
            if sameHost.count >= 2 {
                let referenced = sameHost.filter { $0.status == .reference }.count
                let archived = sameHost.count - referenced
                var parts: [String] = []
                if referenced > 0 {
                    parts.append(String(format: tr("n_kept_as_reference"), referenced))
                }
                if archived > 0 { parts.append(String(format: tr("n_archived"), archived)) }
                return String(
                    format: tr("captures_from_host_in_last_30_days"),
                    host,
                    sameHost.count,
                    parts.joined(separator: tr("list_joiner"))
                )
            }
        }

        for tag in capture.tags {
            let sameTag = settled.filter { $0.tags.contains(tag) }
            if sameTag.count >= 2 {
                let referenced = sameTag.filter { $0.status == .reference }.count
                let archived = sameTag.count - referenced
                var parts: [String] = []
                if referenced > 0 {
                    parts.append(String(format: tr("n_kept_as_reference"), referenced))
                }
                if archived > 0 { parts.append(String(format: tr("n_archived"), archived)) }
                return String(
                    format: tr("captures_with_tag_in_last_30_days"),
                    tag,
                    sameTag.count,
                    parts.joined(separator: tr("list_joiner"))
                )
            }
        }
        return ""
    }

    /// 本期 vs 上一周期的账本对比事实句；任一侧没有记录就不说。
    static func periodComparison(
        period: ReviewPeriod,
        events: [AttentionEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let current = FocusLedger.summary(
            events: events, interval: period.interval(now: now, calendar: calendar),
            now: now, calendar: calendar
        )
        let previousPeriod = ReviewPeriod(unit: period.unit, offset: period.offset - 1)
        let previous = FocusLedger.summary(
            events: events, interval: previousPeriod.interval(now: now, calendar: calendar),
            now: now, calendar: calendar
        )
        guard current.segmentCount > 0, previous.segmentCount > 0 else { return nil }
        let delta = current.focusDuration - previous.focusDuration
        guard abs(delta) >= 60 else {
            return String(
                format: tr("about_the_same_focus_as_period"),
                previousPeriod.title(now: now, calendar: calendar)
            )
        }
        return String(
            format: delta > 0 ? tr("focused_more_than_period") : tr("focused_less_than_period"),
            previousPeriod.title(now: now, calendar: calendar),
            durationText(abs(delta))
        )
    }

    // MARK: - 时间词

    /// 解析出来的时间范围。带上 `period` 是为了让调用方按结构判断问的是哪一档
    /// （以前拿 `title` 和「今天」比字符串，标题一进本地化表就永远为假）。
    struct ParsedPeriod: Equatable, Sendable {
        let interval: DateInterval
        let title: String
        let period: ReviewPeriod?

        var isToday: Bool { period == ReviewPeriod(unit: .day, offset: 0) }
    }

    /// 从问题里解析时间范围。认：今天/昨天/前天/本周/上周/本月/上个月/最近 N 天。
    /// 没有时间词返回 nil，调用方用默认范围（最近 7 天）。
    ///
    /// 时间词与下面的 `stopPhrases` 刻意留在中文，它们不是界面文案而是分词表：
    /// 英文提问（"yesterday"、"last week"）现在解析不出时间范围，只会退到默认的
    /// 最近 7 天。那是一个还没做的功能，不是漏译——真要支持得按语言各配一套词表。
    static func parsedPeriod(
        question: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ParsedPeriod? {
        func review(_ unit: ReviewPeriodUnit, _ offset: Int) -> ParsedPeriod {
            let period = ReviewPeriod(unit: unit, offset: offset)
            return ParsedPeriod(
                interval: period.interval(now: now, calendar: calendar),
                title: period.title(now: now, calendar: calendar),
                period: period
            )
        }
        if let range = question.range(of: #"(最近|过去)\s*[0-9]{1,3}\s*天"#, options: .regularExpression) {
            let digits = question[range].filter(\.isNumber)
            if let days = Int(digits), days > 0 {
                let clamped = min(days, 366)
                let start = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: -(clamped - 1), to: now) ?? now
                )
                return ParsedPeriod(
                    interval: DateInterval(start: start, end: now),
                    title: String(format: tr("last_n_days"), clamped),
                    period: nil
                )
            }
        }
        if question.contains("前天") { return review(.day, -2) }
        if question.contains("昨天") || question.contains("昨日") { return review(.day, -1) }
        if question.contains("今天") || question.contains("今日") { return review(.day, 0) }
        if question.contains("上周") || question.contains("上个星期") || question.contains("上星期") {
            return review(.week, -1)
        }
        if question.contains("本周") || question.contains("这周") || question.contains("这个星期") {
            return review(.week, 0)
        }
        if question.contains("上个月") || question.contains("上月") { return review(.month, -1) }
        if question.contains("本月") || question.contains("这个月") { return review(.month, 0) }
        return nil
    }

    // MARK: - 关键词

    /// 把问题拆成可检索的片段：先剥时间词与问句套话，再按标点/空白切分。
    /// 中文没有空格分词，靠的是「剥掉已知的壳，剩下的就是实体」。
    static func searchFragments(question: String) -> [String] {
        var cleaned = question.replacingOccurrences(
            of: #"(最近|过去)\s*[0-9]{1,3}\s*天"#,
            with: " ",
            options: .regularExpression
        )
        for phrase in stopPhrases {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: " ")
        }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .reduce(into: [String]()) { result, fragment in
                if !result.contains(fragment) { result.append(fragment) }
            }
            .prefix(4)
            .map { $0 }
    }

    /// 片段（含其子串变体）对一组字段的最好命中分。
    static func bestScore(
        fragments: [String],
        fields: [WorkspaceSearchScoring.Field],
        recency: Date?,
        now: Date
    ) -> Double? {
        var best: Double?
        for fragment in fragments {
            let fragmentLength = max(1, fragment.count)
            for variant in queryVariants(for: fragment) {
                guard let raw = WorkspaceSearchScoring.score(
                    query: variant,
                    fields: fields,
                    recency: recency,
                    now: now
                ) else { continue }
                // 子串命中按长度占比折算：「蓝点重构」占「蓝点重构记过」六分之四。
                let scaled = raw * Double(variant.count) / Double(fragmentLength)
                if scaled > (best ?? 0) { best = scaled }
            }
        }
        return best
    }

    /// 中文问句没有分词：把一个中文片段展开成全部 ≥2 字的连续子串（长的优先，
    /// 封顶 30 个），让「蓝点重构记过」也能命中「蓝点重构」。拉丁片段保持原样。
    static func queryVariants(for fragment: String) -> [String] {
        let characters = Array(fragment)
        let hasCJK = fragment.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard hasCJK, characters.count > 2 else { return [fragment] }
        var variants: [String] = []
        for length in stride(from: characters.count, through: 2, by: -1) {
            for start in 0...(characters.count - length) {
                variants.append(String(characters[start..<(start + length)]))
                if variants.count >= 30 { return variants }
            }
        }
        return variants
    }

    /// 问题里点名的目标（名字整串出现即命中）。
    static func matchedTargets(question: String, snapshot: AttentionSnapshot) -> [AttentionTarget] {
        snapshot.targets.values
            .filter { $0.name.count >= 2 && question.contains($0.name) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 问句套话与时间词，长的先剥（避免「上个月」剩下「月」）。
    private static let stopPhrases: [String] = [
        "这个星期", "上个星期", "什么时候", "做了什么", "干了什么", "干了些什么",
        "多长时间", "怎么样", "有哪些", "有什么", "是什么", "告诉我", "帮我看看",
        "上星期", "这个月", "上个月", "最近", "过去", "今天", "今日", "昨天", "昨日",
        "前天", "本周", "这周", "上周", "本月", "上月", "主要", "进展", "情况",
        "记录", "记忆", "专注", "一共", "总共", "花了", "在忙", "请问", "帮我",
        "看看", "查查", "多久", "多少", "哪些", "哪个", "那个", "这个", "一下",
        "什么", "时候", "现在", "当前", "正在", "刚才", "我们", "我的", "都在",
        "如何", "怎么", "为什么", "为啥",
        "了", "吗", "呢", "啊", "呀", "的", "我", "你", "在", "做", "干", "是",
        "有", "把", "被", "和", "与", "还", "都", "些", "过", "又", "再"
    ].sorted { $0.count > $1.count }

    // MARK: - 小工具

    static func defaultInterval(now: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -6, to: now) ?? now
        )
        return DateInterval(start: start, end: now)
    }

    /// 时长人话：与回顾页同一口径（分钟以内报分钟，以上拆时+分）。
    static func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        guard minutes >= 1 else { return tr("under_a_minute") }
        return UserFacingCopy.focusDuration(minutes)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month().day())
    }

    static func statusTitle(_ status: CaptureStatus) -> String {
        switch status {
        case .inbox: tr("inbox")
        case .attached: tr("attached_to_work")
        case .reference: tr("reference")
        case .archived: tr("archived")
        }
    }

    static func clipped(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
