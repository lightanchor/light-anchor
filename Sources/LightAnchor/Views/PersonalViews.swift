import SwiftUI

/// 专注热力（GitHub 贡献图形态）：过去一年，每天的专注时长或段数。
/// 量级用单色渐变（品牌蓝 浅→深），零值 = 凹陷米灰；数值不靠颜色
/// 单独传达——悬停有原生提示，卡头有合计。
struct LightAnchorContributionGrid: View {
    enum Metric: String, CaseIterable, Identifiable {
        case duration
        case count

        var id: String { rawValue }

        var title: String {
            switch self {
            case .duration: tr("duration")
            case .count: tr("sessions_2")
            }
        }
    }

    /// 天（startOfDay）→ 次数。
    let counts: [Date: Int]
    /// 天（startOfDay）→ 专注时长。
    var durations: [Date: TimeInterval] = [:]
    var metric: Metric = .count

    private static let cellGap: CGFloat = 2
    private static let weekCount = 52
    /// 星期标签列宽（一/三/五）。
    private static let weekdayLabelWidth: CGFloat = 16
    /// 图例小方块保持定长，不随格子伸缩。
    private static let legendSwatchSize: CGFloat = 10

    private var calendar: Calendar { Calendar.current }

    /// 周列（旧→新），每列 7 天（周一开头）；今天所在周靠右。
    private var weeks: [[Date]] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        // 周一 = 0 … 周日 = 6。
        let mondayOffset = (weekday + 5) % 7
        guard let thisMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today) else {
            return []
        }
        return (0..<Self.weekCount).reversed().compactMap { weekAgo in
            guard let monday = calendar.date(byAdding: .day, value: -7 * weekAgo, to: thisMonday) else {
                return nil
            }
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        }
    }

    private func level(for count: Int) -> Int {
        switch count {
        case ..<1: 0
        case 1: 1
        case 2: 2
        case 3...4: 3
        default: 4
        }
    }

    /// 时长档位：0 / <30 分 / <2 小时 / <4 小时 / ≥4 小时。
    private func level(forDuration duration: TimeInterval) -> Int {
        switch duration {
        case ..<60: 0
        case ..<(30 * 60): 1
        case ..<(2 * 3600): 2
        case ..<(4 * 3600): 3
        default: 4
        }
    }

    private func level(on day: Date) -> Int {
        switch metric {
        case .count: level(for: counts[day] ?? 0)
        case .duration: level(forDuration: durations[day] ?? 0)
        }
    }

    private func helpText(on day: Date) -> String {
        let dayLabel = day.formatted(.dateTime.month().day())
        switch metric {
        case .count:
            let dayCount = counts[day] ?? 0
            return String(
                format: dayCount == 1 ? tr("day_n_focus_sessions_one") : tr("day_n_focus_sessions"),
                dayLabel,
                dayCount
            )
        case .duration:
            let minutes = Int((durations[day] ?? 0) / 60)
            return minutes < 1
                ? String(format: tr("day_no_focus_records"), dayLabel)
                : String(
                    format: tr("day_focused_for"),
                    dayLabel,
                    UserFacingCopy.focusDuration(minutes)
                  )
        }
    }

    /// 单色渐变（浅→深）：0 = 凹陷米灰，1–4 = 品牌蓝加深。
    private func fill(forLevel level: Int) -> LightAnchorThemeColor {
        switch level {
        case 0: LightAnchorTheme.recessed
        case 1: LightAnchorTheme.primary.opacity(0.30)
        case 2: LightAnchorTheme.primary.opacity(0.55)
        case 3: LightAnchorTheme.primary
        default: LightAnchorTheme.accentInkStrong
        }
    }

    private var totalCount: Int {
        counts.values.reduce(0, +)
    }

    private var totalLabel: (value: String, unit: String) {
        switch metric {
        case .count:
            return ("\(totalCount)", tr("unit_focus_sessions"))
        case .duration:
            let minutes = Int(durations.values.reduce(0, +) / 60)
            return (UserFacingCopy.focusDuration(minutes), tr("unit_focused"))
        }
    }

    var body: some View {
        let weeks = self.weeks
        let today = calendar.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("past_year"))
                    .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text(tr("total"))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                    Text(totalLabel.value)
                        .font(LightAnchorTheme.supportingFont(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.accentInk)
                    Text(totalLabel.unit)
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
            }

            // 弹性网格：52 列等分铺满可用宽度，格子随列宽保持正方形。
            // 不量宽、不反推——窄到放不下时列自己收窄，永远不会把容器撑破
            // （上一版按测量宽反推格长，窄窗下会溢出，把整窗内容挤偏）。
            VStack(alignment: .leading, spacing: 3) {
                monthLabelsRow(weeks: weeks)
                VStack(alignment: .leading, spacing: Self.cellGap) {
                    ForEach(0..<7, id: \.self) { weekdayIndex in
                        HStack(spacing: Self.cellGap) {
                            // 隔行标注（GitHub 惯例）：一 / 三 / 五。
                            // macOS 系统最小字级是 10（caption2），9.5 的中文字形在非视网膜屏退化。
                            Text([tr("weekday_mon_short"), "", tr("weekday_wed_short"), "", tr("weekday_fri_short"), "", ""][weekdayIndex])
                                .font(LightAnchorTheme.supportingFont(size: 10))
                                .foregroundStyle(LightAnchorTheme.faintInk)
                                .frame(width: Self.weekdayLabelWidth, alignment: .trailing)
                            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                                cell(for: week[weekdayIndex], today: today)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text(tr("less"))
                    .font(LightAnchorTheme.supportingFont(size: 10.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill(forLevel: level))
                        .frame(width: Self.legendSwatchSize, height: Self.legendSwatchSize)
                }
                Text(tr("more"))
                    .font(LightAnchorTheme.supportingFont(size: 10.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: tr("focus_heatmap_over_the_past_year_2"), totalLabel.value, totalLabel.unit))
        // 单格数值只在悬停 tooltip 里，旁白/键盘拿不到——指路到有同一数据的地方。
        .accessibilityHint(tr("heatmap_daily_hint"))
    }

    @ViewBuilder
    private func cell(for day: Date, today: Date) -> some View {
        Group {
            if day > today {
                // 未来的日子留空占位，保持列宽一致。
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill(forLevel: level(on: day)))
                    .help(helpText(on: day))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func monthLabelsRow(weeks: [[Date]]) -> some View {
        HStack(spacing: Self.cellGap) {
            Color.clear.frame(width: Self.weekdayLabelWidth, height: 12)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                let showsMonth = week.contains { calendar.component(.day, from: $0) == 1 }
                // fixedSize 让月名溢出自己那格、盖到后续空格上；等分框架不受影响。
                Text(showsMonth ? shortMonth(of: week) : "")
                    .font(LightAnchorTheme.supportingFont(size: 10))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 12)
            }
        }
    }

    private func shortMonth(of week: [Date]) -> String {
        guard let first = week.first(where: { calendar.component(.day, from: $0) == 1 }) else { return "" }
        return Self.monthShortLabel(calendar.component(.month, from: first))
    }

    /// 月份短标签逐 key 直写：英文要的是 Jan/Feb 这类名字，格式串给不出；
    /// 守门测试只认字面量 key 的 tr 调用，所以不走拼接 key。
    static func monthShortLabel(_ month: Int) -> String {
        switch month {
        case 1: tr("month_short_1")
        case 2: tr("month_short_2")
        case 3: tr("month_short_3")
        case 4: tr("month_short_4")
        case 5: tr("month_short_5")
        case 6: tr("month_short_6")
        case 7: tr("month_short_7")
        case 8: tr("month_short_8")
        case 9: tr("month_short_9")
        case 10: tr("month_short_10")
        case 11: tr("month_short_11")
        case 12: tr("month_short_12")
        default: ""
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    var onOpenTarget: (UUID) -> Void = { _ in }
    @State private var heatmapMetric: LightAnchorContributionGrid.Metric = .duration
    @State private var ledgerPeriod: ReviewPeriod = .currentWeek
    @State private var selectedHistoryScene: SceneSnapshot?
    @State private var narrativeText: String?
    @State private var narrativeEngineName: String?
    @State private var isGeneratingNarrative = false
    @AppStorage(LightAnchorNarrativePreference.storageKey) private var autoGenerateNarrative = false

    /// 每天开始的专注段数（不含后台 episode；过去一年足够，字典本身很小）。
    private var dailyFocusCounts: [Date: Int] {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for episode in workspace.snapshot.episodes.values {
            counts[calendar.startOfDay(for: episode.startedAt), default: 0] += 1
        }
        return counts
    }

    /// 过去 7 天 / 再前 7 天的完成情况（样机 page-review 的摘要行）。
    private struct WeeklyDigest {
        let completedCount: Int
        let averageFocusMinutes: Int
        /// 与上一个 7 天相比的完成数变化；上周没有记录时为 nil。
        let deltaPercent: Int?
    }

    private var weeklyDigest: WeeklyDigest {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let ended = workspace.snapshot.episodes.values.filter { $0.endedAt != nil }
        let thisWeek = ended.filter { ($0.endedAt ?? now) > weekAgo }
        let lastWeek = ended.filter {
            let end = $0.endedAt ?? now
            return end > twoWeeksAgo && end <= weekAgo
        }
        let average: Int
        if thisWeek.isEmpty {
            average = 0
        } else {
            let total = thisWeek.reduce(0.0) { $0 + workspace.snapshot.focusDuration(of: $1.id, now: now) }
            average = max(0, Int(total / Double(thisWeek.count) / 60))
        }
        let delta: Int? = lastWeek.isEmpty
            ? nil
            : Int((Double(thisWeek.count - lastWeek.count) / Double(lastWeek.count) * 100).rounded())
        return WeeklyDigest(
            completedCount: thisWeek.count,
            averageFocusMinutes: average,
            deltaPercent: delta
        )
    }

    var body: some View {
        // 样机 page-review：.readout + 摘要 listpanel 行。原始事件流水
        // 对用户没有意义，不展示。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LightAnchorReadout(tr("review_2"), status: tr("where_attention_went_this_week_facts")) {
                    EmptyView()
                }

                // 本周摘要（样机 page-review 的 listpanel 行）。
                LightAnchorListPanel {
                    weeklySummaryRow
                }
                groupGap

                // 组头行统一构图：标签与控件真垂直居中（两个组件都不再自带
                // 外边距，居中就是对文字/胶囊本体），行下与行上同款 14——
                // 上边是 groupGap 的 14，组头到自家卡也给 14，上下间距相同。
                HStack(alignment: .center) {
                    LightAnchorSectionLabel(tr("focus_heatmap"))
                    Spacer(minLength: 12)
                    LightAnchorSegSoft(
                        selection: $heatmapMetric,
                        options: LightAnchorContributionGrid.Metric.allCases,
                        title: \.title
                    )
                }
                .padding(.bottom, 14)
                LightAnchorContributionGrid(
                    counts: dailyFocusCounts,
                    durations: workspace.focusDayDurations(),
                    metric: heatmapMetric
                )
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lightAnchorPanel(radius: LightAnchorDesign.radiusCard)
                groupGap

                ledgerSection
                groupGap

                if ledgerPeriod.unit == .day {
                    recentWorkSection
                    groupGap
                }

                // 定时：即将到来的管理 + 触发历史时间线（点开看当时的现场）。
                ScheduleReviewSection { scene in
                    selectedHistoryScene = scene
                }
                .environmentObject(workspace)
                groupGap

                // 过程记录：软件对每段工作/过程的自动留痕与成稿。
                RecordingReviewSection()
                    .environmentObject(workspace)
                groupGap

                narrativeSection
            }
            .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .sheet(item: $selectedHistoryScene) { scene in
            RecentWorkSceneSheet(
                snapshot: scene,
                onOpenTarget: {
                    selectedHistoryScene = nil
                    if let targetID = scene.targetID { onOpenTarget(targetID) }
                }
            )
        }
    }

    private var groupGap: some View {
        Color.clear.frame(height: 14)
    }

    private var weeklySummaryRow: some View {
        let digest = weeklyDigest
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    digest.completedCount == 0
                        ? tr("nothing_finished_this_week_yet")
                        : String(
                            format: tr("finished_n_this_week_average_focus"),
                            digest.completedCount,
                            UserFacingCopy.focusDuration(digest.averageFocusMinutes)
                          )
                )
                .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.ink)
                Text(weeklyComparisonText(digest))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }

            Spacer(minLength: 14)
        }
        .lightAnchorListRow()
    }

    private func weeklyComparisonText(_ digest: WeeklyDigest) -> String {
        guard digest.completedCount > 0 else {
            return tr("finish_something_and_this_week_s")
        }
        guard let delta = digest.deltaPercent else {
            return tr("no_records_last_week")
        }
        if delta == 0 { return tr("same_as_last_week") }
        return delta > 0
            ? String(format: tr("up_from_last_week"), delta)
            : String(format: tr("down_from_last_week"), abs(delta))
    }

    // MARK: - 叙事回顾

    private var narrativeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 与两个组头行同一节奏：标签到卡 14。
            LightAnchorSectionLabel(tr("narrative_review"))
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 10) {
                if let narrativeText {
                    Text(narrativeText)
                        .font(LightAnchorTheme.interfaceFont(size: 13))
                        .foregroundStyle(LightAnchorTheme.ink)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let narrativeEngineName {
                        Text(String(format: tr("written_by_from_this_s_ledger"), narrativeEngineName, ledgerPeriod.title()))
                            .font(LightAnchorTheme.supportingFont(size: 11))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }
                } else {
                    Text(String(format: tr("turn_this_s_ledger_facts_into"), ledgerPeriod.title()))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }

                HStack(spacing: 10) {
                    Button(narrativeText == nil ? tr("write_a_narrative") : tr("regenerate")) {
                        generateNarrative()
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                    .disabled(isGeneratingNarrative)
                    if isGeneratingNarrative {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    Toggle(tr("generate_when_review_opens"), isOn: $autoGenerateNarrative)
                        .toggleStyle(.checkbox)
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lightAnchorPanel(radius: LightAnchorDesign.radiusCard)
        }
        .onAppear { reloadNarrative(autoGenerate: autoGenerateNarrative) }
        .onChange(of: ledgerPeriod) { _, _ in
            reloadNarrative(autoGenerate: autoGenerateNarrative)
        }
    }

    private func reloadNarrative(autoGenerate: Bool) {
        narrativeText = NarrativeStore.text(forKey: NarrativeStore.key(for: ledgerPeriod))
        narrativeEngineName = narrativeText == nil ? nil : narrativeEngineName
        if autoGenerate, narrativeText == nil, !isGeneratingNarrative {
            generateNarrative()
        }
    }

    private func generateNarrative() {
        guard !isGeneratingNarrative else { return }
        let period = ledgerPeriod
        let input = workspace.makeNarrativeInput(for: period)
        guard !input.factLines.isEmpty else {
            narrativeText = nil
            workspace.presentNotice(
                String(format: tr("no_facts_to_write_about_yet"), period.title())
            )
            return
        }
        isGeneratingNarrative = true
        let engine = workspace.intelligenceEngine
        Task { @MainActor in
            if let text = await engine.generateNarrative(input) {
                NarrativeStore.save(text, forKey: NarrativeStore.key(for: period))
                if period == ledgerPeriod {
                    narrativeText = text
                    narrativeEngineName = engine.name
                }
            }
            isGeneratingNarrative = false
        }
    }

    // MARK: - 时间账本

    private var ledgerSection: some View {
        let summary = workspace.focusPeriodSummary(in: ledgerPeriod.interval())
        return VStack(alignment: .leading, spacing: 0) {
            // 与专注热力的组头同一构图（见上）：真居中、行下同款 14。
            HStack(alignment: .center, spacing: 10) {
                LightAnchorSectionLabel(tr("time_ledger"))
                Spacer(minLength: 12)
                LightAnchorSegSoft(
                    selection: $ledgerPeriod.unit,
                    options: ReviewPeriodUnit.allCases,
                    title: \.title
                )
                periodStepper
            }
            .padding(.bottom, 14)
            LightAnchorListPanel {
                ledgerSummaryRow(summary)
                if !summary.targetStats.isEmpty {
                    LightAnchorRowSeparator()
                    ForEach(summary.targetStats.prefix(8)) { stat in
                        ledgerTargetRow(stat, totalDuration: summary.focusDuration)
                        if stat.id != summary.targetStats.prefix(8).last?.id {
                            LightAnchorRowSeparator()
                        }
                    }
                }
            }
        }
    }

    private var periodStepper: some View {
        HStack(spacing: 4) {
            Button {
                ledgerPeriod.offset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            .accessibilityLabel(tr("previous"))

            Text(ledgerPeriod.title())
                .font(LightAnchorTheme.supportingFont(size: 12, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .frame(minWidth: 64)
                .monospacedDigit()

            Button {
                ledgerPeriod.offset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            .disabled(ledgerPeriod.offset >= 0)
            .accessibilityLabel(tr("next"))
        }
    }

    private func ledgerSummaryRow(_ summary: FocusPeriodSummary) -> some View {
        let minutes = Int(summary.focusDuration / 60)
        let headline = minutes < 1
            ? String(format: tr("period_has_no_focus_records"), ledgerPeriod.title())
            : String(
                format: summary.segmentCount == 1
                    ? tr("period_focus_and_segments_one") : tr("period_focus_and_segments"),
                ledgerPeriod.title(),
                UserFacingCopy.focusDuration(minutes),
                summary.segmentCount
              )
        var facts: [String] = []
        if summary.completedCount > 0 {
            facts.append(String(format: tr("n_finished"), summary.completedCount))
        }
        if summary.readyWaitingCount > 0 {
            facts.append(String(
                format: summary.readyWaitingCount == 1
                    ? tr("n_results_arrived_one") : tr("n_results_arrived"),
                summary.readyWaitingCount
            ))
        }
        if summary.captureCount > 0 {
            facts.append(String(format: tr("n_captured"), summary.captureCount))
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.ink)
                Text(facts.isEmpty ? tr("facts_only_no_scoring") : facts.joined(separator: " · "))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            Spacer(minLength: 14)
        }
        .lightAnchorListRow()
    }

    private func ledgerTargetRow(_ stat: FocusTargetStat, totalDuration: TimeInterval) -> some View {
        let name = workspace.snapshot.targets[stat.targetID]?.name ?? tr("deleted_focus")
        let minutes = Int(stat.duration / 60)
        let share = totalDuration > 0 ? stat.duration / totalDuration : 0
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                    .help(name)
                Text(String(
                    format: stat.segmentCount == 1 ? tr("sessions_one") : tr("sessions"),
                    UserFacingCopy.focusDuration(minutes),
                    stat.segmentCount
                ))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            Spacer(minLength: 14)
            // 占比条：品牌蓝水洗，宽度与该目标的时长占比成正比。
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(LightAnchorTheme.recessed)
                    Capsule(style: .continuous)
                        .fill(LightAnchorTheme.primary.opacity(0.55))
                        .frame(width: max(3, proxy.size.width * share))
                }
            }
            .frame(width: 120, height: 6)
            .accessibilityHidden(true)
        }
        .lightAnchorListRow()
    }

    // MARK: - 近期经过

    private var recentWorkSection: some View {
        let traces = workspace.recentWorkTraces(in: ledgerPeriod.interval())
        return VStack(alignment: .leading, spacing: 0) {
            // 与两个组头行同一节奏：标签到卡 14。
            LightAnchorSectionLabel(tr("recent_activity"))
                .padding(.bottom, 14)
            LightAnchorListPanel {
                if traces.isEmpty {
                    Text(tr("no_work_story_for_this_day"))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lightAnchorListRow()
                } else {
                    ForEach(Array(traces.enumerated()), id: \.element.id) { index, trace in
                        recentWorkRow(trace)
                        if index < traces.count - 1 { LightAnchorRowSeparator() }
                    }
                }
            }
        }
    }

    private func recentWorkRow(_ trace: RecentWorkTrace) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(trace.startedAt.formatted(.dateTime.hour().minute()))
                    .font(LightAnchorTheme.monoFont(size: 11.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Circle()
                    .fill(trace.endedReason == .abandoned
                        ? LightAnchorTheme.faintInk
                        : LightAnchorTheme.primary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            .frame(width: 48, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                Text(trace.targetTitle)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                Text(trace.summary)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !trace.applications.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(trace.applications.prefix(3)), id: \.self) { application in
                            Text(application)
                                .font(LightAnchorTheme.supportingFont(size: 10.5, weight: .medium))
                                .foregroundStyle(LightAnchorTheme.faintInk)
                                // 21pt 定高胶囊：窗口收窄时不许折行，折了字形会被裁。
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 7)
                                .frame(height: 21)
                                .background(
                                    LightAnchorTheme.recessed,
                                    in: Capsule(style: .continuous)
                                )
                        }
                        if trace.applications.count > 3 {
                            Text("+\(trace.applications.count - 3)")
                                .font(LightAnchorTheme.supportingFont(size: 10.5, weight: .medium))
                                .foregroundStyle(LightAnchorTheme.faintInk)
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Text("\(trace.statusTitle) · \(UserFacingCopy.focusDuration(Int(trace.focusDuration / 60)))")
                    .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
                if let scene = trace.sceneSnapshot, !scene.items.isEmpty {
                    Button(tr("view_scene")) { selectedHistoryScene = scene }
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                        .accessibilityHint(tr("see_the_files_pages_and_apps"))
                }
            }
        }
        .lightAnchorListRow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                format: tr("trace_accessibility_label"),
                trace.targetTitle,
                trace.statusTitle,
                UserFacingCopy.focusDuration(Int(trace.focusDuration / 60))
            )
        )
        .accessibilityValue(trace.summary)
    }
}

private struct RecentWorkSceneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: AttentionWorkspace
    let snapshot: SceneSnapshot
    let onOpenTarget: () -> Void
    @State private var showingEnvironmentEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("historical_scene"))
                        .font(LightAnchorTheme.headingFont(size: 16))
                    Text(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }
                Spacer(minLength: 12)
                Text(String(
                    format: snapshot.items.count == 1 ? tr("items_one") : tr("items"),
                    snapshot.items.count
                ))
                    .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .monospacedDigit()
            }
            .padding(20)

            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !snapshot.returnCue.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("resume_with"))
                                .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                                .foregroundStyle(LightAnchorTheme.faintInk)
                            Text(snapshot.returnCue)
                                .font(LightAnchorTheme.bodyFont(size: 13))
                                .lineSpacing(3)
                                .foregroundStyle(LightAnchorTheme.ink)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LightAnchorTheme.recessed,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }

                    ForEach(snapshot.items) { item in
                        SceneItemRow(
                            item: item,
                            isTucked: snapshot.filterMode == .aiFiltered && !item.isRelevant
                        )
                    }
                    if !snapshot.clipboardText.isEmpty {
                        SceneClipboardRow(text: snapshot.clipboardText)
                    }
                    SceneScreenshotRow(assetURL: snapshot.screenshotAssetURL)
                }
                .padding(20)
            }

            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
            HStack(spacing: 8) {
                if snapshot.targetID != nil {
                    Button(tr("open_focus"), action: onOpenTarget)
                        .buttonStyle(LightAnchorPrimaryButtonStyle())
                }
                if !EnvironmentSnapshotBuilder.draft(from: snapshot).actions.isEmpty {
                    Button(tr("save_as_environment")) { showingEnvironmentEditor = true }
                        .buttonStyle(LightAnchorQuietButtonStyle())
                        .help(tr("review_the_generated_actions_before_deciding"))
                }
                Spacer(minLength: 8)
                Button(UserFacingCopy.close) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .background(LightAnchorTheme.contentBackground)
        .sheet(isPresented: $showingEnvironmentEditor) {
            EnvironmentEditorView(
                profile: nil,
                draft: EnvironmentSnapshotBuilder.draft(from: snapshot)
            )
            .environmentObject(workspace)
        }
    }
}

/// 「打开回顾时自动生成」偏好键：设置行与 LocalDataErasure 清单共用。
enum LightAnchorNarrativePreference {
    static let storageKey = "lightanchor.narrativeAutoGenerate"
}
