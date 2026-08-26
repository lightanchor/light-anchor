import SwiftUI

/// 「换一件事」：应用的标准 sheet——和「开始一件事」「等待编辑器」
/// 「重返现场」同一个家族（LightAnchorSheetHeader + 分组 + 动作条）。
///
/// 形态走过四版：命令面板（被否：过滤和新建挤在一个搜索框里）、黑纱浮层卡
/// （被否：和安静语言不合）、舞台接管（被否：中心舞台上悬一张选择卡，
/// 既不像页面也不像对话框）。定稿回到系统 sheet：这本来就是一个「做个选择」
/// 的对话，应用里所有同类对话都是 sheet，用户已经认识它。
///
/// 三条来源平级陈列：接着做、从稍后拿一条是列表，新开一件是常驻命名框。
/// 切换本身不在这里实现：`startEpisode(targetID:)` 早就会把手上那件按下放下、
/// 固定现场，并在遇到同一目标的未完成段时接着做那一段。这里缺的一直只是入口。
struct SwitchWorkSheet: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss

    /// 切换成功：主视图负责翻回「现在」并清掉回顾态。
    let onSwitched: () -> Void
    /// 「填写环境和备注后开始…」：带着已经敲好的名字打开完整的开始表单。
    let onNewWorkDetails: (String) -> Void

    @State private var newWorkName = ""
    @State private var selectionIndex = 0
    /// 列表实际内容高：ScrollView 是贪高的，条目少时会把 sheet 撑出空白。
    @State private var listContentHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// 每段最多列这么多：这张 sheet 是用来快速换一件事的，不是第二个稍后页。
    private static let sectionLimit = 6
    /// 列表区最多长到这么高，再多就滚动。
    private static let listMaxHeight: CGFloat = 264

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LightAnchorSheetHeader(
                eyebrow: tr("switching"),
                title: tr("switch_to_something_else"),
                subtitle: tr("sets_this_one_aside_with_its"),
                icon: "arrow-left-right"
            )

            if let entry = currentEntry {
                currentWorkBanner(entry)
            }

            existingSections

            createGroup

            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("start")) {
                    confirmDefaultAction()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(newName.isEmpty && candidates.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { fieldFocused = true }
    }

    // MARK: - 正在进行的那件

    /// 换走之前先亮出来——被放下的是谁、已经专注多久。
    private func currentWorkBanner(
        _ entry: (episode: AttentionEpisode, target: AttentionTarget)
    ) -> some View {
        HStack(spacing: 9) {
            LightAnchorStatusDot(entry.episode.state, size: 8)
            Text(entry.target.name)
                .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .lineLimit(1)
            Text("· " + String(
                format: tr("focused_for"),
                UserFacingCopy.focusDuration(workspace.snapshot.focusMinutes(of: entry.episode.id))
            ))
            .font(LightAnchorTheme.supportingFont(size: 12))
            .monospacedDigit()
            .foregroundStyle(LightAnchorTheme.faintInk)
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            LightAnchorTheme.recessed,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var currentEntry: (episode: AttentionEpisode, target: AttentionTarget)? {
        guard let episode = workspace.currentEpisode,
              let target = workspace.snapshot.targets[episode.targetID] else { return nil }
        return (episode, target)
    }

    /// 米灰凹陷分组（现场卡语言）：图标组头 + 内容。
    private func sourceGroup<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LightAnchorLabel(title: title, icon: icon, spacing: 6)
                .font(LightAnchorTheme.supportingFont(size: 12, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LightAnchorTheme.recessed,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    // MARK: - 候选来源

    /// 放下的未完成事。排掉手上正在做的那件——它不是「换过去」的目标。
    private var resumeEntries: [(target: AttentionTarget, episode: AttentionEpisode)] {
        let currentTargetID = workspace.currentEpisode?.targetID
        return workspace.snapshot.setAsideEpisodes
            .compactMap { episode -> (target: AttentionTarget, episode: AttentionEpisode)? in
                guard episode.targetID != currentTargetID,
                      let target = workspace.snapshot.targets[episode.targetID]
                else { return nil }
                return (target: target, episode: episode)
            }
            .prefix(Self.sectionLimit)
            .map { $0 }
    }

    private var captureEntries: [CaptureItem] {
        workspace.snapshot.inbox
            .prefix(Self.sectionLimit)
            .map { $0 }
    }

    private var newName: String {
        newWorkName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ↑↓ 走的平铺顺序，和界面从上到下一致（新开一件走命名框，不进这个序列）。
    private var candidates: [SwitchCandidate] {
        resumeEntries.map { SwitchCandidate.resume($0.target.id) }
            + captureEntries.map { SwitchCandidate.capture($0.id) }
    }

    private func captureTitle(_ capture: CaptureItem) -> String {
        capture.body.isEmpty ? (capture.title ?? tr("saved_items")) : capture.body
    }

    private func isSelected(_ candidate: SwitchCandidate) -> Bool {
        let all = candidates
        return all.firstIndex(of: candidate) == min(selectionIndex, max(0, all.count - 1))
    }

    // MARK: - 已有的事（接着做 / 从稍后拿一条）

    @ViewBuilder
    private var existingSections: some View {
        if !candidates.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !resumeEntries.isEmpty {
                        sourceGroup(title: tr("pick_up_where_you_left_off"), icon: "circle-pause") {
                            VStack(spacing: 5) {
                                ForEach(resumeEntries, id: \.episode.id) { entry in
                                    resumeRow(entry, isSelected: isSelected(.resume(entry.target.id)))
                                }
                            }
                        }
                    }
                    if !captureEntries.isEmpty {
                        sourceGroup(title: tr("take_one_from_later"), icon: "inbox") {
                            VStack(spacing: 5) {
                                ForEach(captureEntries) { capture in
                                    captureRow(capture, isSelected: isSelected(.capture(capture.id)))
                                }
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .frame(height: min(max(listContentHeight, 1), Self.listMaxHeight))
            .scrollIndicators(.never)
        }
    }

    // MARK: - 新开一件（与上面两组平级的常驻区块）

    private var createGroup: some View {
        sourceGroup(title: tr("start_a_new_one"), icon: "plus") {
            VStack(alignment: .leading, spacing: 6) {
                TextField(tr("e_g_organise_the_interview_notes"), text: $newWorkName)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .font(LightAnchorTheme.interfaceFont(size: 13))
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onSubmit { confirmDefaultAction() }

                // 环境和备注不进这张 sheet——换一件事是高频动作，中间不能有
                // 表单。需要它们时从这里进完整的开始表单，名字带过去。
                Button {
                    onNewWorkDetails(newName)
                } label: {
                    Text(tr("start_with_details"))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .lightAnchorHoverFill(cornerRadius: 7)
                .padding(.leading, -6)
            }
        }
    }

    // MARK: - 行

    private func resumeRow(
        _ entry: (target: AttentionTarget, episode: AttentionEpisode),
        isSelected: Bool
    ) -> some View {
        Button {
            activate(.resume(entry.target.id))
        } label: {
            HStack(spacing: 10) {
                LightAnchorStatusDot(entry.episode.state, size: 7)
                Text(entry.target.name)
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(resumeMeta(entry.episode))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SwitchWorkRowButtonStyle(isSelected: isSelected))
    }

    private func resumeMeta(_ episode: AttentionEpisode) -> String {
        let aside = UserFacingCopy.setAsideAge(of: episode.updatedAt)
        let focus = workspace.snapshot.focusMinutes(of: episode.id)
        guard focus > 0 else { return aside }
        return aside + " · " + String(format: tr("total_focus"), UserFacingCopy.focusDuration(focus))
    }

    private func captureRow(_ capture: CaptureItem, isSelected: Bool) -> some View {
        Button {
            activate(.capture(capture.id))
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(LightAnchorTheme.faintInk)
                    .frame(width: 7, height: 7)
                Text(captureTitle(capture))
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(UserFacingCopy.relativeAge(of: capture.capturedAt))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SwitchWorkRowButtonStyle(isSelected: isSelected))
    }

    // MARK: - 选择与执行

    /// 回车 / 动作条「开始」的语义跟着字走：框里有名字就开始它，
    /// 空着就开始 ↑↓ 选中的那条。
    private func confirmDefaultAction() {
        if !newName.isEmpty {
            activate(.create(newName))
        } else if !candidates.isEmpty {
            activate(candidates[min(selectionIndex, candidates.count - 1)])
        }
    }

    private func moveSelection(by offset: Int) {
        let count = candidates.count
        guard count > 0 else { return }
        selectionIndex = (selectionIndex + offset + count) % count
        // 焦点一直在输入框里，↑↓ 只改视觉高亮——旁白用户要听得到当前选中的是
        // 哪一条，否则回车等于盲开（和搜索浮层同一处理）。
        AccessibilityNotification.Announcement(label(for: candidates[selectionIndex])).post()
    }

    private func label(for candidate: SwitchCandidate) -> String {
        switch candidate {
        case .resume(let targetID):
            workspace.snapshot.targets[targetID]?.name ?? ""
        case .capture(let captureID):
            workspace.snapshot.captures[captureID].map(captureTitle) ?? ""
        case .create(let name):
            String(format: tr("start_x_now"), name)
        }
    }

    private func activate(_ candidate: SwitchCandidate) {
        let switchedTargetID: UUID?
        switch candidate {
        case .resume(let targetID):
            switchedTargetID = workspace.startEpisode(targetID: targetID)?.targetID
        case .capture(let captureID):
            switchedTargetID = workspace.createTargetFromCapture(captureID)?.id
        case .create(let name):
            guard !name.isEmpty else { return }
            switchedTargetID = workspace.createTarget(name: name)
                .flatMap { workspace.startEpisode(targetID: $0.id)?.targetID }
        }
        guard switchedTargetID != nil else { return }
        // 「已放下 + 现场存了什么」由随后的确认弹窗承接（RecentSetAsideSheet）。
        onSwitched()
    }
}

/// sheet 里一行代表的东西。几种来源共用一个 ↑↓ 序列，所以要能互相比较。
private enum SwitchCandidate: Equatable {
    case resume(UUID)
    case capture(UUID)
    case create(String)
}

/// 凹陷分组里的白面行（现场卡语言）：白底圆角 + 发丝描边，
/// 键盘选中转宜蓝水洗 + 蓝描边，悬停提亮。
private struct SwitchWorkRowButtonStyle: ButtonStyle {
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isSelected
                    ? LightAnchorTheme.accentWash
                    : (isHovered ? LightAnchorTheme.elevatedSurface : LightAnchorTheme.surface),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? LightAnchorTheme.accentInk.opacity(0.35)
                            : LightAnchorTheme.hairlineBorder.opacity(0.7),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
