import AppKit
import SwiftUI

// MARK: - 「现在」页（定稿：docs/now-page-scrollrail-2026-09-09.html）
//
// 一整页顺着读，不切页签：
//   这件事（状态 / 名字 / 回来先看 / 步骤）
//   → 上次做到哪（这一段的总结）
//   → 东西在哪（现场清单 + 当时的剪贴板）
// 右缘一条不占版面的小轨：上面三枚是「读到哪一节」的切换，一道细线之下
// 三枚是这一页的操作（铺回桌面 / 问问记忆 / 回到顶部）。底部一枚浮岛动作条，
// 上面只有一枚实心主键。
//
// 被否过的形态不要回头：三个并列页签（这件事 / 上次做到哪 / 东西在哪）、
// 跳转条、粘性小节标题、引子句、接力行、轮播式的「上一段 / 下一段」为唯一入口。
// 总结和现场是同一段的两面，永远在同一页上、跟着同一个「第几段」走。

/// 滚动容器的坐标空间名：算「读到哪一节」用。放在类型外，
/// 好让 onGeometryChange 那个 Sendable 闭包能读它（主 actor 隔离的静态属性不行）。
private let nowPageScrollSpace = "now-page-scroll"

/// 页面的三节。小轨、滚动高亮共用这一个枚举。
enum NowChapter: String, CaseIterable, Identifiable {
    case task
    case summary
    case items

    var id: String { rawValue }

    var title: String {
        switch self {
        case .task: tr("this_thing")
        case .summary: tr("last_time_you_got_to")
        case .items: tr("where_things_are")
        }
    }

    var icon: String {
        switch self {
        case .task: "circle-dot"
        case .summary: "file-text"
        case .items: "layers"
        }
    }
}

struct NowSpaceView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let onStart: () -> Void
    let onSwitch: () -> Void
    /// 「切到这步」：打开换一件事并预选那一步（步骤切换算换一件事，仪式照走）。
    let onSwitchToStep: (UUID) -> Void
    let onCapture: () -> Void
    let onWait: () -> Void
    let onRestoreContext: (ContextCapsule) -> Void
    /// 铺回某一份现场：走「重返现场」确认面板，历史段和最近一段同一条路。
    let onRestoreSnapshot: (SceneSnapshot) -> Void
    let onOpenDestination: (WorkspaceDestination) -> Void

    // 步骤卡的输入态：点「加一步」现身，回车连着加，esc 收起。
    @State private var addingStep = false
    @State private var stepDraft = ""
    @FocusState private var stepFieldFocused: Bool
    /// 完成一件还有未完成步骤的大事：先提醒，确认了才连带收起。
    @State private var confirmingFinishSteps = false
    /// 做完的步骤默认折起来——清单里该显眼的是还没做的。
    @State private var showingDoneSteps = false

    /// 看的是第几段（0 = 最近一段）。总结与现场共用它：它们是同一段的两面。
    @State private var segmentIndex = 0
    /// 读到哪一节（小轨高亮）。
    @State private var chapter = NowChapter.task
    /// 每一节在滚动容器里的纵坐标，用来算「读到哪一节」。
    @State private var chapterOffsets: [NowChapter: CGFloat] = [:]

    @State private var editingCue = false
    @State private var cueDraft = ""
    @State private var editingSummary = false
    @State private var summaryDraft = ""



    var body: some View {
        GeometryReader { proxy in
            if let episode = workspace.currentEpisode,
               let target = workspace.snapshot.targets[episode.targetID] {
                longPage(episode: episode, target: target, size: proxy.size)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        emptyState
                    }
                    .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 24))
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - 长页

    private func longPage(
        episode: AttentionEpisode,
        target: AttentionTarget,
        size: CGSize
    ) -> some View {
        // 窄窗口收起小轨：132 的轨 + 40 的余量放不下时，正文优先。
        let showsRail = size.width >= 720
        let segment = selectedSegment(of: target)
        return ScrollViewReader { scroller in
            VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 到期条不摆在这页上（用户定）：手上这件事的页面只讲这件事，
                        // 「今天得动了」那类催促住在稍后页那张清单的最上面。
                        chapterBody(.task) {
                            taskChapter(episode: episode, target: target, segment: segment, scroller: scroller)
                        }
                        chapterBody(.summary) {
                            summaryChapter(target: target, segment: segment)
                        }
                        chapterBody(.items) {
                            itemsChapter(segment: segment)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, LightAnchorDesign.workspaceHorizontalPadding)
                    .padding(.trailing, showsRail ? 194 : LightAnchorDesign.workspaceHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 26)
                }
                .coordinateSpace(name: nowPageScrollSpace)
                .scrollIndicators(.never)
                .onChange(of: chapterOffsets) { _, _ in recomputeChapter() }

                if showsRail {
                NowRail(
                    current: chapter,
                    stepsBadge: stepsBadge(for: target),
                    summaryBadge: segment?.episode.summary.map { "\($0.characterCount)" } ?? "",
                    itemsBadge: (segment?.scene?.items.count).map { "\($0)" } ?? "",
                    restorableCount: segment?.scene?.restorableItems.count ?? 0,
                    onJump: { jump(to: $0, scroller: scroller) },
                    onRestore: { restore(segment: segment) },
                    onAskMemory: { onOpenDestination(.chat) },
                    onTop: { jump(to: .task, scroller: scroller) }
                )
                .padding(.top, 96)
                .padding(.trailing, 24)
                }

            }

                // 动作条是**窗底独立一条带**，不是浮在内容上的岛：浮起来的那版
                // 会压住正文最后一行，也会和窗底那条账重叠（用户指出）。
                NowActionDock(
                    episode: episode,
                    onSwitch: onSwitch,
                    onWait: onWait,
                    onFinish: {
                        if workspace.snapshot.unfinishedSteps(of: target.id).isEmpty {
                            _ = workspace.endEpisode(episode.id)
                        } else {
                            confirmingFinishSteps = true
                        }
                    }
                )
                .environmentObject(workspace)
                .confirmationDialog(
                    finishStepsTitle(for: target),
                    isPresented: $confirmingFinishSteps,
                    titleVisibility: .visible
                ) {
                    Button(tr("finish_and_collapse_steps")) {
                        if let current = workspace.currentEpisode {
                            _ = workspace.endEpisodeCollapsingSteps(current.id)
                        }
                    }
                    Button(tr("cancel"), role: .cancel) {}
                } message: {
                    Text(tr("finish_steps_alert_message"))
                }
            }
        }
        .onChange(of: episode.targetID) { _, _ in
            segmentIndex = 0
            editingSummary = false
            editingCue = false
        }
        #if DEBUG
        // 调试后门：LIGHTANCHOR_DEBUG_NOW_SEGMENT=<第几段> 直接翻到那一段（截图/验收用）。
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_NOW_SEGMENT"],
               let index = Int(raw) {
                segmentIndex = max(0, index)
            }
        }
        #endif
    }

    /// 一节的外壳：第二节起上面一道发丝线（章与章之间的唯一分隔）。
    @ViewBuilder
    private func chapterBody(
        _ chapter: NowChapter,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if chapter != .task {
                Rectangle()
                    .fill(LightAnchorTheme.hairlineBorder)
                    .frame(height: 1)
                    .padding(.top, 38)
                    .padding(.bottom, 24)
                    .accessibilityHidden(true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(chapter)
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(nowPageScrollSpace)).minY
        } action: { offset in
            chapterOffsets[chapter] = offset
        }
    }

    private func jump(to chapter: NowChapter, scroller: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) {
            scroller.scrollTo(chapter, anchor: .top)
            self.chapter = chapter
        }
    }

    /// 读到哪一节：容器顶下 140 以内、最靠下的那一节。
    private func recomputeChapter() {
        var current = NowChapter.task
        for candidate in NowChapter.allCases {
            guard let offset = chapterOffsets[candidate], offset <= 140 else { continue }
            current = candidate
        }
        guard current != chapter else { return }
        chapter = current
    }

    // MARK: - 第一节：这件事

    private func taskChapter(
        episode: AttentionEpisode,
        target: AttentionTarget,
        segment: WorkSegment?,
        scroller: ScrollViewProxy
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    statusLine(episode: episode)
                    Text(target.name)
                        .font(LightAnchorTheme.titleFont(size: 26, weight: .semibold))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !target.note.isEmpty {
                        Text(target.note)
                            .font(LightAnchorTheme.bodyFont(size: 13.5))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 6) {
                    LightAnchorFocusReadout(minutes: workspace.snapshot.focusMinutes(of: episode.id))
                    Text(tr("focused_caption"))
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
                .accessibilityElement(children: .combine)
            }

            cueBlock(episode: episode, segment: segment, scroller: scroller)

            // 期限那一行先不摆在这页上（用户定：之后自己加回来）。
            // 押期限的入口仍在「开始一件事」那张便笺和到期条的「改期」上。
            stepsSection(for: target)
        }
    }

    private func statusLine(episode: AttentionEpisode) -> some View {
        HStack(spacing: 10) {
            LightAnchorStatusDot(episode.state, size: 9)
            Text(UserFacingCopy.waitingState(episode.state))
                .font(LightAnchorTheme.bodyFont(size: 12.5, weight: .semibold))
                .foregroundStyle(stateColor(episode.state))
            statusSeparator
            Text(String(
                format: tr("started_3"),
                episode.startedAt.formatted(date: .omitted, time: .shortened)
            ))
            .font(LightAnchorTheme.supportingFont(size: 12))
            .monospacedDigit()
            .foregroundStyle(LightAnchorTheme.mutedInk)
            if let historyLine = workspace.currentTargetHistoryLine() {
                statusSeparator
                Text(historyLine)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .lineLimit(1)
            }
        }
    }

    private var statusSeparator: some View {
        Circle()
            .fill(LightAnchorTheme.iconDisabledStrong)
            .frame(width: 3, height: 3)
            .accessibilityHidden(true)
    }

    /// 「回来先看」：有话是一块水洗蓝，没话是一张白卡（空的那份不该比有话的更响）。
    @ViewBuilder
    private func cueBlock(
        episode: AttentionEpisode,
        segment: WorkSegment?,
        scroller: ScrollViewProxy
    ) -> some View {
        let cue = episode.returnCue
        let isEmpty = cue.isEmpty
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(tr("look_at_this_first"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(isEmpty ? LightAnchorTheme.mutedInk : LightAnchorTheme.accentInk)
                Button(isEmpty ? tr("write_a_line") : tr("change_a_line")) {
                    cueDraft = cue
                    editingCue = true
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                Spacer(minLength: 8)
                NowJumpLink(
                    title: tr("summary_read_last"),
                    detail: summaryBadge(of: segment)
                ) {
                    jump(to: .summary, scroller: scroller)
                }
            }

            if editingCue {
                HStack(spacing: 8) {
                    TextField(tr("what_to_look_at_first"), text: $cueDraft)
                        .textFieldStyle(LightAnchorTextFieldStyle())
                        .onSubmit { commitCue(episode: episode, segment: segment) }
                    Button(tr("save")) { commitCue(episode: episode, segment: segment) }
                        .buttonStyle(LightAnchorPrimaryButtonStyle())
                    Button(tr("cancel")) {
                        editingCue = false
                        cueDraft = ""
                    }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                }
            } else {
                Text(isEmpty ? tr("cue_empty_explainer") : cue)
                    .font(LightAnchorTheme.bodyFont(size: isEmpty ? 13.5 : 15))
                    .foregroundStyle(isEmpty ? LightAnchorTheme.mutedInk : LightAnchorTheme.ink)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            isEmpty ? LightAnchorTheme.surface : LightAnchorTheme.accentWash,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                .strokeBorder(
                    isEmpty ? LightAnchorTheme.hairlineBorder : LightAnchorTheme.accentInk.opacity(0.18),
                    lineWidth: 1
                )
        }
    }

    private func commitCue(episode: AttentionEpisode, segment: WorkSegment?) {
        _ = workspace.updateContext(
            for: episode.id,
            context: episode.context,
            returnCue: cueDraft
        )
        if let scene = segment?.scene {
            _ = workspace.updateSceneReturnCue(scene.id, returnCue: cueDraft)
        }
        editingCue = false
        cueDraft = ""
    }

    // MARK: 步骤（大任务拆小步骤）

    /// 步骤住在哪件大事名下：当前是步骤就看它的母任务——顺便看到大任务进度和兄弟步骤。
    private func stepsHostID(for target: AttentionTarget) -> UUID {
        target.parentTargetID ?? target.id
    }

    @ViewBuilder
    private func stepsSection(for target: AttentionTarget) -> some View {
        let hostID = stepsHostID(for: target)
        let steps = workspace.snapshot.steps(of: hostID).filter { $0.retiredAt == nil }
        if !steps.isEmpty || addingStep {
            let done = steps.filter { workspace.snapshot.isTargetCompleted($0.id) }
            NowCard {
                Text(stepsHeader(for: target))
                    .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                if !steps.isEmpty {
                    NowProgressBar(done: done.count, total: steps.count)
                    Text(verbatim: "\(done.count) / \(steps.count)")
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.accentInk)
                }
                Spacer(minLength: 8)
                if !addingStep {
                    Button(tr("add_a_step")) {
                        addingStep = true
                        stepFieldFocused = true
                    }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                }
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    if !done.isEmpty {
                        Button {
                            showingDoneSteps.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                LightAnchorIcon("check", size: 12)
                                    .foregroundStyle(LightAnchorTheme.accentInk)
                                Text(String(format: tr("steps_done_fold"), done.count))
                                    .font(LightAnchorTheme.supportingFont(size: 12.5))
                                LightAnchorIcon(showingDoneSteps ? "chevron-down" : "chevron-right", size: 9)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lightAnchorHoverFill(cornerRadius: LightAnchorDesign.radiusRow)
                    }
                    ForEach(steps) { step in
                        let isDone = workspace.snapshot.isTargetCompleted(step.id)
                        if !isDone || showingDoneSteps {
                            NowStepRow(
                                step: step,
                                isDone: isDone,
                                isCurrent: step.id == target.id,
                                minutes: workspace.snapshot
                                    .latestEpisode(of: step.id)
                                    .map { workspace.snapshot.focusMinutes(of: $0.id) } ?? 0,
                                onSwitch: { onSwitchToStep(step.id) }
                            )
                        }
                    }
                    if addingStep {
                        TextField(tr("step_name_placeholder"), text: $stepDraft)
                            .textFieldStyle(.plain)
                            .font(LightAnchorTheme.bodyFont(size: 13.5))
                            .focused($stepFieldFocused)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .onSubmit { commitStepDraft(hostID: hostID) }
                            .onExitCommand {
                                addingStep = false
                                stepDraft = ""
                            }
                    }
                }
                .padding(4)
            }
        } else if target.parentTargetID == nil {
            Button {
                addingStep = true
                stepFieldFocused = true
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LightAnchorTheme.accentWash)
                        LightAnchorIcon("layers", size: 13)
                            .foregroundStyle(LightAnchorTheme.accentInk)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("break_into_steps"))
                            .font(LightAnchorTheme.bodyFont(size: 12.5, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.ink)
                        Text(tr("break_into_steps_detail"))
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }

                    Spacer(minLength: 8)
                    LightAnchorIcon("plus", size: 13)
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous))
            }
            .buttonStyle(.plain)
            .lightAnchorHoverFill(cornerRadius: LightAnchorDesign.radiusRow)
        }
    }

    private func stepsHeader(for target: AttentionTarget) -> String {
        if let parentID = target.parentTargetID,
           let parent = workspace.snapshot.targets[parentID] {
            return String(format: tr("step_of_parent"), parent.name)
        }
        return tr("steps")
    }

    private func stepsBadge(for target: AttentionTarget) -> String {
        let hostID = stepsHostID(for: target)
        guard let progress = workspace.snapshot.stepProgress(of: hostID) else { return "" }
        return "\(progress.done)/\(progress.total)"
    }

    private func commitStepDraft(hostID: UUID) {
        let name = stepDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            addingStep = false
            return
        }
        if workspace.addStep(named: name, to: hostID) != nil {
            stepDraft = ""
            // 停在输入态：拆步骤往往一口气拆完。
            stepFieldFocused = true
        }
    }

    private func finishStepsTitle(for target: AttentionTarget) -> String {
        let count = workspace.snapshot.unfinishedSteps(of: target.id).count
        return String(
            format: count == 1 ? tr("finish_steps_alert_title_one") : tr("finish_steps_alert_title"),
            count
        )
    }

    // MARK: - 第二节：上次做到哪

    private func summaryChapter(target: AttentionTarget, segment: WorkSegment?) -> some View {
        let segments = workspace.snapshot.workSegments(for: target.id)
        return VStack(alignment: .leading, spacing: 12) {
            NowChapterHead(
                title: NowChapter.summary.title,
                detail: segment.map { segmentSavedLabel($0) } ?? tr("summary_not_written_yet")
            ) {
                if segments.count > 1 {
                    Button(tr("segment_newer")) { segmentIndex -= 1 }
                        .buttonStyle(LightAnchorInlineButtonStyle())
                        .disabled(segmentIndex <= 0)
                    Button(tr("segment_older")) { segmentIndex += 1 }
                        .buttonStyle(LightAnchorInlineButtonStyle())
                        .disabled(segmentIndex >= segments.count - 1)
                }
            }

            // 看的不是眼下这份时说清楚：在这儿改的只落在这一段上。
            if segmentIndex > 0, let segment {
                NowOldSegmentNotice(when: segmentWhen(segment)) {
                    segmentIndex = 0
                }
            }

            if let segment {
                NowSummaryCard(
                    segment: segment,
                    isEditing: $editingSummary,
                    draft: $summaryDraft
                )
                .environmentObject(workspace)
            } else {
                Text(tr("no_segment_yet"))
                    .font(LightAnchorTheme.bodyFont(size: 13.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            }
        }
    }

    /// 这一段是什么时候存下的：「9 月 6 日 15:30」。
    private func segmentWhen(_ segment: WorkSegment) -> String {
        (segment.scene?.capturedAt ?? segment.episode.updatedAt)
            .formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// 「9 月 6 日 15:30 存下的 · 186 字」。
    private func segmentSavedLabel(_ segment: WorkSegment) -> String {
        String(format: tr("summary_saved_at"), segmentWhen(segment))
            + " · " + summaryBadge(of: segment)
    }

    private func summaryBadge(of segment: WorkSegment?) -> String {
        guard let summary = segment?.episode.summary, !summary.isEmpty else {
            return tr("summary_not_written_yet")
        }
        return String(format: tr("summary_word_count"), summary.characterCount)
    }

    // MARK: - 第三节：东西在哪

    @ViewBuilder
    private func itemsChapter(segment: WorkSegment?) -> some View {
        if let segment, let scene = segment.scene, !scene.items.isEmpty {
            NowSceneSection(
                snapshot: scene,
                onRestore: { restore(segment: segment) }
            )
            .environmentObject(workspace)
        } else if let episode = workspace.currentEpisode {
            // 这一段还没有现场。章头照常在（这一节不该在空的时候换一副面孔），
            // 正文换成一张白卡：说清楚现场从哪来，外加一枚「记录当前现场」。
            VStack(alignment: .leading, spacing: 12) {
                NowChapterHead(title: NowChapter.items.title, detail: "") {
                    NowSceneFilterLink(targetID: episode.targetID)
                        .environmentObject(workspace)
                }
                NowSceneEmptyCard(episodeID: episode.id)
                    .environmentObject(workspace)
            }
        }
    }

    private func restore(segment: WorkSegment?) {
        guard let segment else { return }
        guard let scene = segment.scene, !scene.restorableItems.isEmpty else {
            onRestoreContext(segment.episode.context)
            return
        }
        onRestoreSnapshot(scene)
    }

    // MARK: - 段

    private func selectedSegment(of target: AttentionTarget) -> WorkSegment? {
        let all = workspace.snapshot.workSegments(for: target.id)
        guard !all.isEmpty else { return nil }
        return all[min(max(0, segmentIndex), all.count - 1)]
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 0) {
            LightAnchorEmptyIllustration()
                .padding(.bottom, 24)

            Text(tr("put_something_in_first"))
                .font(LightAnchorTheme.interfaceFont(size: 20, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .padding(.bottom, 5)
            Text(UserFacingCopy.noCurrentWorkMessage)
                .font(LightAnchorTheme.interfaceFont(size: 13))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .padding(.bottom, 18)

            HStack(spacing: 9) {
                Button(UserFacingCopy.startWork, action: onStart)
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                Button(UserFacingCopy.captureIdea, action: onCapture)
                    .buttonStyle(LightAnchorQuietButtonStyle())
            }

            Text(tr("start_with_something_you_can_finish"))
                .font(LightAnchorTheme.supportingFont(size: 11.5))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .padding(.top, 16)
        }
    }

    private func stateColor(_ state: AttentionEpisodeState) -> LightAnchorThemeColor {
        switch state {
        case .active, .returning: LightAnchorTheme.accentInk
        case .paused, .ended: LightAnchorTheme.mutedInk
        }
    }
}

// MARK: - 章头

/// 「东西在哪 ｜ 9 样 · 应用 3 · 文件 3 · 带走 7 样 ｜ 右侧几枚小字动作」。
struct NowChapterHead<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 11) {
            Text(title)
                .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .fixedSize()
            if !detail.isEmpty {
                Text(detail)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 4)
    }
}

/// 白卡：卡头（一条 4% 灰底的行）+ 卡体。
struct NowCard<Head: View, Content: View>: View {
    @ViewBuilder let head: () -> Head
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { head() }
                .padding(.horizontal, 16)
                .frame(minHeight: 42)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LightAnchorTheme.subtleFill)
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous))
    }
}

/// 内容里的入口：一枚贴着相关内容的小字 + 箭头（不是按钮、不是页签）。
struct NowJumpLink: View {
    let title: String
    var detail: String = ""
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(LightAnchorTheme.controlFont(size: 12.5, weight: .medium))
                    .foregroundStyle(hovered ? LightAnchorTheme.accentInkStrong : LightAnchorTheme.accentInk)
                if !detail.isEmpty {
                    Text(detail)
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
                LightAnchorIcon("chevron-right", size: 9)
                    .foregroundStyle(hovered ? LightAnchorTheme.accentInk : LightAnchorTheme.faintInk)
                    .offset(x: hovered ? 2 : 0)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// 步骤进度条（54×3）。
struct NowProgressBar: View {
    let done: Int
    let total: Int

    var body: some View {
        let ratio = total > 0 ? Double(done) / Double(total) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(LightAnchorTheme.hairlineBorder)
            Capsule().fill(LightAnchorTheme.primary)
                .frame(width: 54 * ratio)
        }
        .frame(width: 54, height: 3)
        .accessibilityHidden(true)
    }
}

/// 步骤一行：记号 + 名字 + 专注时长 / 「切到这步」。
struct NowStepRow: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let step: AttentionTarget
    let isDone: Bool
    let isCurrent: Bool
    let minutes: Int
    let onSwitch: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            if isDone {
                LightAnchorIcon("check", size: 11)
                    .foregroundStyle(LightAnchorTheme.accentInk)
                    .frame(width: 13)
            } else {
                LightAnchorStatusDot(
                    workspace.snapshot.latestEpisode(of: step.id)
                        .map { LightAnchorStatusDotForm($0.state) } ?? .ended,
                    size: 8
                )
                .frame(width: 13)
            }
            Text(step.name)
                .font(LightAnchorTheme.bodyFont(size: 13.5))
                .strikethrough(isDone)
                .foregroundStyle(isDone ? LightAnchorTheme.faintInk : LightAnchorTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 10)
            if isCurrent {
                Text(tr("step_current"))
                    .font(LightAnchorTheme.supportingFont(size: 12, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.accentInk)
            } else if hovered, !isDone {
                Button(tr("switch_to_this_step"), action: onSwitch)
                    .buttonStyle(LightAnchorInlineButtonStyle())
            } else if minutes > 0 {
                Text(String(format: tr("focused"), UserFacingCopy.focusDuration(minutes)))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            } else if !isDone {
                Text(tr("step_not_started"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            } else {
                Text(tr("step_done"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                    .fill(LightAnchorTheme.accentWash)
            } else if hovered {
                RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                    .fill(LightAnchorTheme.hoverFill)
            }
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(LightAnchorTheme.primary)
                    .frame(width: 3, height: 20)
                    .padding(.leading, 4)
            }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// 看的是旧的那一段时，顶上一条暖黄提示。
struct NowOldSegmentNotice: View {
    let when: String
    let onBackToLatest: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LightAnchorIcon("clock-3", size: 13)
                .foregroundStyle(LightAnchorTheme.iconAmber)
            Text(String(format: tr("segment_old_notice"), when))
                .font(LightAnchorTheme.supportingFont(size: 12))
                .foregroundStyle(LightAnchorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("back_to_latest_segment"), action: onBackToLatest)
                .buttonStyle(LightAnchorInlineButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            LightAnchorTheme.warningBackground.opacity(0.35),
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                .strokeBorder(LightAnchorTheme.warning.opacity(0.32), lineWidth: 1)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 总结卡

/// 这一段的总结：有就是一篇正文 + 署名行，没有就是一句解释 + 「整理一份」。
struct NowSummaryCard: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let segment: WorkSegment
    @Binding var isEditing: Bool
    @Binding var draft: String

    private var isBusy: Bool {
        workspace.summarizingEpisodeIDs.contains(segment.episode.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                editor
            } else if let summary = segment.episode.summary, !summary.isEmpty {
                NowSummaryDoc(text: summary.text)
                credit(summary)
            } else {
                empty
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $draft)
                .font(LightAnchorTheme.bodyFont(size: 14))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(10)
                .background(
                    LightAnchorTheme.recessed,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            HStack(spacing: 8) {
                Button(tr("summary_edit_done")) {
                    _ = workspace.updateEpisodeSummary(segment.episode.id, text: draft)
                    isEditing = false
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                Button(tr("cancel")) { isEditing = false }
                    .buttonStyle(LightAnchorInlineButtonStyle())
            }
        }
    }

    private func credit(_ summary: EpisodeSummary) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
                .padding(.top, 20)
            HStack(spacing: 16) {
                Text(summary.isEdited
                    ? String(format: tr("summary_credit_edited"), summary.engineName)
                    : String(
                        format: tr("summary_credit"),
                        summary.engineName,
                        summary.factCount
                    ))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Spacer(minLength: 8)
                Button(tr("summary_edit")) {
                    draft = summary.text
                    isEditing = true
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                Button(tr("summary_copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.text, forType: .string)
                    workspace.presentNotice(tr("summary_copied"))
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                regenerateButton(title: tr("summary_reorganize"), force: true)
            }
            .padding(.top, 13)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("summary_empty_explainer"))
                .font(LightAnchorTheme.bodyFont(size: 14))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)
            // 上次没整理成：如实写出原因（引擎没配 / 服务端报错 / 返回空），
            // 绝不用一段拼装的假总结顶上（用户定）。
            if let failure = workspace.summaryFailures[segment.episode.id], !failure.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LightAnchorIcon("alert-triangle", size: 13)
                        .foregroundStyle(LightAnchorTheme.warning)
                    Text(String(format: tr("summary_failed"), failure))
                        .font(LightAnchorTheme.supportingFont(size: 12.5))
                        .foregroundStyle(LightAnchorTheme.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 640, alignment: .leading)
                .background(
                    LightAnchorTheme.warningBackground.opacity(0.32),
                    in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                        .strokeBorder(LightAnchorTheme.warning.opacity(0.3), lineWidth: 1)
                }
            }
            if let facts = workspace
                .makeEpisodeSummaryInput(episodeID: segment.episode.id)?
                .factLines.count {
                regenerateButton(
                    title: workspace.summaryFailures[segment.episode.id] == nil
                        ? String(format: tr("summary_organize_one"), facts)
                        : tr("summary_retry"),
                    force: false
                )
            } else {
                Text(tr("summary_organize_no_facts"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
        }
    }

    private func regenerateButton(title: String, force: Bool) -> some View {
        Button {
            Task { await workspace.summarizeEpisode(segment.episode.id, force: force) }
        } label: {
            HStack(spacing: 6) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(isBusy ? tr("summary_organizing") : title)
            }
        }
        .buttonStyle(force ? AnyButtonStyleBox(LightAnchorInlineButtonStyle())
                           : AnyButtonStyleBox(LightAnchorRaisedButtonStyle(compact: true)))
        .disabled(isBusy)
    }
}

/// 两种按钮样式在同一处二选一时的擦除盒（SwiftUI 的 ButtonStyle 不能直接三元）。
struct AnyButtonStyleBox: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// 总结正文：Markdown-lite（`## 小标题` + 段落 + `- 列表`），行内加粗与
/// 反引号照 Markdown 解析。不做完整 Markdown——总结的骨架就这三样。
struct NowSummaryDoc: View {
    let text: String

    private enum Block: Identifiable {
        case heading(String, Int)
        case paragraph(String, Int)
        case bullet(String, Int)

        var id: String {
            switch self {
            case .heading(let value, let index): "h\(index)-\(value)"
            case .paragraph(let value, let index): "p\(index)-\(value)"
            case .bullet(let value, let index): "l\(index)-\(value)"
            }
        }
    }

    private var blocks: [Block] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .enumerated()
            .compactMap { index, line in
                guard !line.isEmpty else { return nil }
                if line.hasPrefix("#") {
                    return .heading(
                        line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces),
                        index
                    )
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return .bullet(String(line.dropFirst(2)), index)
                }
                return .paragraph(line, index)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let value, _):
                    Self.inline(value)
                        .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                        .foregroundStyle(LightAnchorTheme.ink)
                        .padding(.top, block.id == blocks.first?.id ? 0 : 20)
                        .padding(.bottom, 8)
                case .paragraph(let value, _):
                    Self.inline(value)
                        .font(LightAnchorTheme.bodyFont(size: 14.5))
                        .foregroundStyle(LightAnchorTheme.secondaryInk)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                case .bullet(let value, _):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(LightAnchorTheme.primary)
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                        Self.inline(value)
                            .font(LightAnchorTheme.bodyFont(size: 14.5))
                            .foregroundStyle(LightAnchorTheme.secondaryInk)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private static func inline(_ raw: String) -> Text {
        if let attributed = try? AttributedString(markdown: raw) {
            return Text(attributed)
        }
        return Text(raw)
    }
}

// MARK: - 现场那一节

/// 「东西在哪」+「当时的剪贴板」两张白卡。行首一枚记号（实心蓝点＝会带走 /
/// 空心灰圈＝不带），名字在上、位置在下；点一行就是改它带不带。
struct NowSceneSection: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let snapshot: SceneSnapshot
    let onRestore: () -> Void

    private var kept: Int { snapshot.restorableItems.count }

    /// 展示顺序：应用 · 网页 · 文件 · 终端（枚举声明顺序是数据顺序，不是读的顺序）。
    static let displayOrder: [SceneItemKind] = [.application, .link, .file, .terminal]

    /// 「9 样 · 应用 3 · 文件 3 · 带走 7 样」。章头和弹窗共用这一句。
    static func tallyLine(of snapshot: SceneSnapshot) -> String {
        let kinds = displayOrder
            .compactMap { kind -> String? in
                let count = snapshot.items.filter { $0.kind == kind }.count
                return count > 0 ? "\(kind.title) \(count)" : nil
            }
            .joined(separator: " · ")
        let kept = snapshot.restorableItems.count
        return kinds.isEmpty
            ? String(format: tr("scene_tally_plain"), snapshot.items.count, kept)
            : String(format: tr("scene_tally"), snapshot.items.count, kinds, kept)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowChapterHead(
                title: NowChapter.items.title,
                detail: Self.tallyLine(of: snapshot)
            ) {
                // 检查点现场可能不挂在任何一件事上，那就没有「这件事的口径」可改。
                if let targetID = snapshot.targetID {
                    NowSceneFilterLink(targetID: targetID)
                        .environmentObject(workspace)
                }
                Button(tr("scene_take_none")) { setAll(relevant: false) }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                Button(tr("scene_take_all")) { setAll(relevant: true) }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                NowJumpLink(title: String(format: tr("scene_restore_n"), kept), action: onRestore)
                    .disabled(kept == 0)
            }

            NowThingsCard(snapshot: snapshot)
                .environmentObject(workspace)
            NowClipboardCard(snapshot: snapshot)
                .environmentObject(workspace)
            SceneScreenshotRow(assetURL: snapshot.screenshotAssetURL)
                .environmentObject(workspace)
        }
    }

    private func setAll(relevant: Bool) {
        for item in snapshot.items where item.isRelevant != relevant {
            _ = workspace.toggleSceneItemRelevance(snapshot.id, itemID: item.id)
        }
    }
}

/// 一份现场的清单白卡。「现在」页的「东西在哪」和「已放下」确认弹窗共用，
/// 两处逐像素同源——点一行就是改它带不带走。
struct NowThingsCard: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let snapshot: SceneSnapshot

    var body: some View {
        NowCard {
            Text(tr("scene_click_to_drop"))
                .font(LightAnchorTheme.supportingFont(size: 11.5))
                .foregroundStyle(LightAnchorTheme.mutedInk)
            Spacer(minLength: 8)
        } content: {
            SceneThingsGrid(
                items: snapshot.items,
                isOff: { !$0.isRelevant },
                placeText: { place(of: $0) },
                takeTitle: tr("scene_take_it"),
                dropTitle: tr("scene_drop_it"),
                toggle: { _ = workspace.toggleSceneItemRelevance(snapshot.id, itemID: $0.id) }
            )
            .padding(4)
        }
    }

    /// 位置那行：终端条目报命令，AI 收起的报「判为无关」，其余报来源应用。
    private func place(of item: SceneItem) -> String {
        if !item.detail.isEmpty { return item.detail }
        if !item.isRelevant, item.sourceApplication.isEmpty { return tr("scene_judged_irrelevant") }
        return item.sourceApplication
    }
}

/// 「当时的剪贴板」白卡：一列复写条，中间停过就断开。没有内容时整块不出现。
struct NowClipboardCard: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let snapshot: SceneSnapshot

    @State private var strips: [ClipboardStrip] = []

    var body: some View {
        Group {
            if !strips.isEmpty {
                NowCard {
                    Text(tr("clipboard_then"))
                        .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                        .foregroundStyle(LightAnchorTheme.ink)
                    Text(String(
                        format: tr("clipboard_count"),
                        strips.reduce(0) { $0 + $1.entries.count }
                    ))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    Spacer(minLength: 8)
                    Button(tr("clipboard_copy_all")) {
                        let text = strips
                            .flatMap(\.entries)
                            .map(\.text)
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        workspace.presentNotice(tr("clipboard_all_copied"))
                    }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                } content: {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(strips.enumerated()), id: \.element.id) { index, strip in
                            if index > 0, let pause = strips[index - 1].pauseAfter {
                                NowClipboardGap(pause: pause)
                            }
                            ForEach(Array(strip.entries.enumerated()), id: \.element.id) { row, entry in
                                NowClipboardRow(
                                    entry: entry,
                                    isLatest: index == 0 && row == 0
                                )
                                .environmentObject(workspace)
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: snapshot.id) { _, _ in reload() }
        .onChange(of: workspace.clipboardHistoryRevision) { _, _ in reload() }
    }

    private func reload() {
        strips = workspace.hasClipboardContent(snapshot)
            ? workspace.clipboardStrips(for: snapshot)
            : []
    }
}

/// 这一段还没有现场时的那张白卡：一句说清现场从哪来，加一枚凸起白面键
/// 「记录当前现场」。空态不该比有内容的那份更响，所以没有实心键、没有凹槽底。
struct NowSceneEmptyCard: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let episodeID: UUID

    @State private var isCapturing = false
    /// 点了「记录当前现场」之后的结果：空/失败必须说清楚，否则点了跟没点一样。
    @State private var feedback: Feedback?

    private enum Feedback {
        case saved(Int)
        case empty(accessibilityGranted: Bool)
        case failed

        var message: String {
            switch self {
            case .saved(let count): String(
                format: count == 1 ? tr("recorded_n_scene_items_one") : tr("recorded_n_scene_items"),
                count
            )
            // 已授权时不能再让用户去开权限——那是死胡同。
            case .empty(true): tr("nothing_recorded_the_open_apps_have")
            case .empty(false): tr("nothing_recorded_reading_other_apps_windows")
            case .failed: tr("couldn_t_record_start_something_first")
            }
        }

        var isPositive: Bool {
            if case .saved = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr("no_scene_recorded_yet_when_you"))
                .font(LightAnchorTheme.bodyFont(size: 13.5))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .lineSpacing(4)
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await capture() }
            } label: {
                HStack(spacing: 6) {
                    if isCapturing { ProgressView().controlSize(.small) }
                    Text(isCapturing ? tr("recording") : tr("record_current_scene"))
                }
            }
            .buttonStyle(LightAnchorRaisedButtonStyle(compact: true))
            .disabled(isCapturing)

            if let feedback {
                Text(feedback.message)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(
                        feedback.isPositive ? LightAnchorTheme.accentInk : LightAnchorTheme.warning
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
    }

    private func capture() async {
        isCapturing = true
        feedback = nil
        let captured = await workspace.captureSceneSnapshot(for: episodeID, refreshingContext: true)
        isCapturing = false
        // 成功时这张卡会被真正的清单顶掉，反馈只在空/失败时还有观众。
        if let captured {
            feedback = captured.items.isEmpty
                ? .empty(
                    accessibilityGranted: PrivacyPermissionService()
                        .status(for: .accessibility) == .granted
                )
                : .saved(captured.items.count)
        } else {
            feedback = .failed
        }
    }
}

/// 现场清单：自适应两列网格，按 应用 / 网页 / 文件 / 终端 排序但**不分组**。
/// 「现在」页和「换一件事」的现场页共用这一个——两处逐像素同源。
struct SceneThingsGrid: View {
    let items: [SceneItem]
    /// 这一条不带走 / 这次不开。
    let isOff: (SceneItem) -> Bool
    /// 位置那行的文字（终端命令、来源应用、或「当时判为无关」这类状态词）。
    let placeText: (SceneItem) -> String
    /// 行尾那枚小字：划掉的说「带上 / 开上」，没划掉的说「不带 / 不开」。
    let takeTitle: String
    let dropTitle: String
    let toggle: (SceneItem) -> Void

    private var ordered: [SceneItem] {
        let order = NowSceneSection.displayOrder
        return items.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.kind) ?? 0
            let right = order.firstIndex(of: rhs.kind) ?? 0
            if left != right { return left < right }
            return lhs.title.localizedCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: 14)],
            alignment: .leading,
            spacing: 2
        ) {
            ForEach(ordered) { item in
                NowItemRow(
                    item: item,
                    isOff: isOff(item),
                    place: placeText(item),
                    takeTitle: takeTitle,
                    dropTitle: dropTitle
                ) {
                    toggle(item)
                }
            }
        }
    }
}

/// 一样东西：记号 + 真应用图标 + 名字/位置 + 行尾「带上 / 不带」。
/// 行首那枚记号沿用软件的点语言（实心蓝点＝会带走 / 空心灰圈＝不带），
/// 不用复选框——一眼看出这些行是可切的。
struct NowItemRow: View {
    let item: SceneItem
    let isOff: Bool
    let place: String
    let takeTitle: String
    let dropTitle: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(isOff ? LightAnchorTheme.primary.opacity(0) : LightAnchorTheme.primary)
                    .overlay {
                        if isOff {
                            Circle().strokeBorder(LightAnchorTheme.iconDisabledStrong, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 8, height: 8)
                SwitchWorkAppIcon(item: item, size: 30)
                    .grayscale(isOff ? 1 : 0)
                    .opacity(isOff ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(LightAnchorTheme.interfaceFont(size: 13.5))
                        .strikethrough(isOff)
                        .foregroundStyle(isOff ? LightAnchorTheme.stageMutedInk : LightAnchorTheme.secondaryInk)
                        .lineLimit(1)
                    if !place.isEmpty {
                        Text(place)
                            .font(item.kind == .terminal
                                ? .system(size: 11, design: .monospaced)
                                : LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(item.kind == .terminal
                                ? LightAnchorTheme.accentInk
                                : LightAnchorTheme.stageMutedInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if hovered || isOff {
                    Text(isOff ? takeTitle : dropTitle)
                        .font(LightAnchorTheme.supportingFont(size: 11, weight: .medium))
                        .foregroundStyle(isOff ? LightAnchorTheme.stageMutedInk : LightAnchorTheme.accentInk)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovered ? LightAnchorTheme.hoverFill : LightAnchorThemeColor.clear,
                in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(item.title)
        .accessibilityValue(isOff ? dropTitle : takeTitle)
    }
}

/// 剪贴板一行：等宽时刻 + 内容 + 来源（悬停换成「拷贝这条」）。
struct NowClipboardRow: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let entry: ClipboardHistoryEntry
    let isLatest: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 14) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .frame(width: 52, alignment: .leading)
            Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: isLatest ? .medium : .regular))
                .foregroundStyle(isLatest ? LightAnchorTheme.ink : LightAnchorTheme.secondaryInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            if hovered {
                Button(tr("clipboard_copy_this")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    workspace.presentNotice(tr("clipboard_this_copied"))
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
            } else if !entry.sourceApplication.isEmpty {
                Text(entry.sourceApplication)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            hovered ? LightAnchorTheme.hoverFill : .clear,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isLatest {
                Capsule()
                    .fill(LightAnchorTheme.primary)
                    .frame(width: 3, height: 18)
                    .padding(.leading, 4)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// 两张纸之间的断口：虚线 + 「放下了 42 分钟」。
struct NowClipboardGap: View {
    let pause: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            dash
            Text(String(
                format: tr("clipboard_strip_set_down_for"),
                UserFacingCopy.focusDuration(max(1, Int(pause / 60)))
            ))
            .font(LightAnchorTheme.supportingFont(size: 11))
            .foregroundStyle(LightAnchorTheme.mutedInk)
            .fixedSize()
            dash
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var dash: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(LightAnchorTheme.subtleBorder)
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

// MARK: - 右缘小轨

/// 三枚切换（读到哪一节就亮哪一条）｜一道细线｜三枚操作。
/// 绝对定位贴在内容右缘，不占版面；只有细图标 + 小字，无卡无影。
struct NowRail: View {
    let current: NowChapter
    let stepsBadge: String
    let summaryBadge: String
    let itemsBadge: String
    let restorableCount: Int
    let onJump: (NowChapter) -> Void
    let onRestore: () -> Void
    let onAskMemory: () -> Void
    let onTop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(NowChapter.allCases) { chapter in
                NowRailItem(
                    icon: chapter.icon,
                    title: chapter.title,
                    badge: badge(for: chapter),
                    isCurrent: chapter == current,
                    isAction: false,
                    action: { onJump(chapter) }
                )
            }
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
                .padding(.top, 9)
                .padding(.bottom, 8)
            NowRailItem(
                icon: "panels-top-left",
                title: tr("lay_back_out"),
                badge: restorableCount > 0 ? "\(restorableCount)" : "",
                isCurrent: false,
                isAction: true,
                action: onRestore
            )
            NowRailItem(
                icon: "sparkles",
                title: tr("rail_ask_memory"),
                badge: "",
                isCurrent: false,
                isAction: false,
                action: onAskMemory
            )
            NowRailItem(
                icon: "arrow-up",
                title: tr("rail_back_to_top"),
                badge: "",
                isCurrent: false,
                isAction: false,
                action: onTop
            )
        }
        .frame(width: 158, alignment: .leading)
    }

    private func badge(for chapter: NowChapter) -> String {
        switch chapter {
        case .task: stepsBadge
        case .summary: summaryBadge
        case .items: itemsBadge
        }
    }
}

private struct NowRailItem: View {
    let icon: String
    let title: String
    let badge: String
    let isCurrent: Bool
    let isAction: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                LightAnchorIcon(icon, size: 15)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(LightAnchorTheme.controlFont(
                        size: 12.5,
                        weight: isCurrent ? .semibold : .regular
                    ))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !badge.isEmpty {
                    Text(badge)
                        .font(LightAnchorTheme.supportingFont(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? LightAnchorTheme.accentInk : LightAnchorTheme.faintInk)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovered ? LightAnchorTheme.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(badge.isEmpty ? title : "\(title) \(badge)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var titleColor: LightAnchorThemeColor {
        if isCurrent { return LightAnchorTheme.ink }
        if isAction { return LightAnchorTheme.accentInk }
        return hovered ? LightAnchorTheme.secondaryInk : LightAnchorTheme.mutedInk
    }

    private var iconColor: LightAnchorThemeColor {
        if isCurrent || isAction { return LightAnchorTheme.accentInk }
        return LightAnchorTheme.iconSoft
    }
}

// MARK: - 底部浮岛动作条

/// 离开这件事的三个去处 + 记录本次，一律无边框安静键；右边唯一一枚实心主键。
struct NowActionDock: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let episode: AttentionEpisode
    let onSwitch: () -> Void
    let onWait: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
            pill
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var pill: some View {
        HStack(spacing: 2) {
            dockItem(
                icon: "arrow-left-right",
                title: tr("switch_to_something_else"),
                help: tr("sets_this_one_aside_with_its"),
                action: onSwitch
            )
            if episode.state == .active || episode.state == .returning {
                dockItem(icon: "circle-pause", title: tr("set_aside")) {
                    _ = workspace.pauseEpisode(episode.id, returnCue: episode.returnCue)
                }
            }
            dockItem(icon: "hourglass", title: UserFacingCopy.waitForResult, action: onWait)
            if workspace.activeRecordingSession == nil {
                dockItem(icon: "sticky-note", title: tr("record_this_one")) {
                    _ = workspace.startRecordingCurrentEpisode()
                }
            }
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 6)
            primary
        }
        .padding(6)
        .background(
            LightAnchorTheme.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }

    @ViewBuilder
    private var primary: some View {
        switch episode.state {
        case .active, .returning:
            Button(action: onFinish) {
                HStack(spacing: 8) {
                    LightAnchorIcon("check", size: 13)
                    Text(UserFacingCopy.finishWork)
                }
            }
            .buttonStyle(LightAnchorSolidButtonStyle())
        case .paused:
            Button {
                _ = workspace.resumeEpisode(episode.id)
            } label: {
                HStack(spacing: 8) {
                    LightAnchorIcon("play", size: 13)
                    Text(tr("continue"))
                }
            }
            .buttonStyle(LightAnchorSolidButtonStyle())
        case .ended:
            EmptyView()
        }
    }

    private func dockItem(
        icon: String,
        title: String,
        help: String = "",
        action: @escaping () -> Void
    ) -> some View {
        NowDockItem(icon: icon, title: title, help: help, action: action)
    }
}

private struct NowDockItem: View {
    let icon: String
    let title: String
    var help: String = ""
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LightAnchorIcon(icon, size: 15)
                    .foregroundStyle(hovered ? LightAnchorTheme.iconSubtle : LightAnchorTheme.iconSoft)
                Text(title)
                    .font(LightAnchorTheme.controlFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.secondaryInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                hovered ? LightAnchorTheme.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
