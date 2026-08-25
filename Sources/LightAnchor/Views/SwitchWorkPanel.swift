import SwiftUI

/// 「换一件事」浮层：把「开始/切换到某件事」的三条来源收进一个框。
///
/// 在这之前，这三条散在三个页面里——放下的事要去稍后页点「继续」，捕获要去
/// 稍后页点「立为一件事」，新开一件只在「现在」页没有当前工作时才露出入口。
/// 最常做的那个动作（我现在要换一件事）在有当前工作时根本没有按钮，用户得先
/// 点一次「暂停」把现在页清空，才能看见「开始一件事」。
///
/// 顶上的输入框同时是过滤器和新建框：打字过滤已有的，回车开始选中的那条；
/// 没有命中时回车就是用这个名字新开一件。所以「从稍后中选取」和「手动新增」
/// 不是两个按钮两条路，而是同一个框里的连续动作。
///
/// 切换本身不在这里实现：`startEpisode(targetID:)` 早就会把手上那件按下放下、
/// 固定现场，并在遇到同一目标的未完成段时接着做那一段。这里缺的一直只是入口。
struct SwitchWorkPanel: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onClose: () -> Void
    /// 切换成功：主视图负责回到「现在」页并清掉回顾态。
    let onSwitched: () -> Void
    /// 「更多设置…」：带着已经敲好的名字打开完整的开始表单（环境、备注）。
    let onNewWorkDetails: (String) -> Void

    @State private var query = ""
    @State private var selectionIndex = 0
    @FocusState private var fieldFocused: Bool

    /// 每段最多列这么多：面板是用来快速换一件事的，不是第二个稍后页。
    private static let sectionLimit = 6

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LightAnchorTheme.ink.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                queryField
                Rectangle()
                    .fill(LightAnchorTheme.hairlineBorder)
                    .frame(height: 1)
                results
                footer
            }
            .frame(width: 560)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.22), radius: 34, y: 18)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 72)
            .onExitCommand { onClose() }
            .onAppear { fieldFocused = true }
            .onDisappear { fieldFocused = false }
        }
    }

    // MARK: - 输入框

    private var queryField: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LightAnchorTheme.faintInk)

            TextField(tr("filter_what_s_here_or_type"), text: $query)
                .textFieldStyle(.plain)
                .font(LightAnchorTheme.interfaceFont(size: 15))
                .focused($fieldFocused)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onSubmit {
                    let all = candidates
                    guard !all.isEmpty else { return }
                    activate(all[min(selectionIndex, all.count - 1)])
                }
                .onChange(of: query) { selectionIndex = 0 }

            Text(verbatim: "esc")
                .font(LightAnchorTheme.monoFont(size: 10, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    LightAnchorTheme.recessed,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 三段候选

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
            .filter { matches($0.target.name) }
            .prefix(Self.sectionLimit)
            .map { $0 }
    }

    private var captureEntries: [CaptureItem] {
        workspace.snapshot.inbox
            .filter { matches(captureTitle($0)) }
            .prefix(Self.sectionLimit)
            .map { $0 }
    }

    private var newName: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ↑↓ 走的平铺顺序，和界面从上到下一致。
    private var candidates: [SwitchCandidate] {
        var all = resumeEntries.map { SwitchCandidate.resume($0.target.id) }
        all += captureEntries.map { SwitchCandidate.capture($0.id) }
        if !newName.isEmpty { all.append(.create(newName)) }
        return all
    }

    private func matches(_ text: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(trimmed)
    }

    private func captureTitle(_ capture: CaptureItem) -> String {
        capture.body.isEmpty ? (capture.title ?? tr("saved_items")) : capture.body
    }

    // MARK: - 结果区

    @ViewBuilder
    private var results: some View {
        let all = candidates
        if all.isEmpty {
            Text(tr("nothing_to_switch_to_yet_type"))
                .font(LightAnchorTheme.supportingFont(size: 12))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !resumeEntries.isEmpty {
                        sectionHead(tr("pick_up_where_you_left_off"))
                        ForEach(resumeEntries, id: \.episode.id) { entry in
                            resumeRow(entry, isSelected: isSelected(.resume(entry.target.id), in: all))
                        }
                    }
                    if !captureEntries.isEmpty {
                        sectionHead(tr("take_one_from_later"))
                        ForEach(captureEntries) { capture in
                            captureRow(capture, isSelected: isSelected(.capture(capture.id), in: all))
                        }
                    }
                    if !newName.isEmpty {
                        sectionHead(tr("start_a_new_one"))
                        createRow(isSelected: isSelected(.create(newName), in: all))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 320)
        }
    }

    private func sectionHead(_ title: String) -> some View {
        Text(title)
            .font(LightAnchorTheme.labelFont(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(LightAnchorTheme.faintInk)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func isSelected(_ candidate: SwitchCandidate, in all: [SwitchCandidate]) -> Bool {
        all.firstIndex(of: candidate) == min(selectionIndex, max(0, all.count - 1))
    }

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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(WorkspaceSearchRowButtonStyle(isSelected: isSelected))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(WorkspaceSearchRowButtonStyle(isSelected: isSelected))
    }

    private func createRow(isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                activate(.create(newName))
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(LightAnchorTheme.primary)
                        .frame(width: 7, height: 7)
                    Text(String(format: tr("start_x_now"), newName))
                        .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(WorkspaceSearchRowButtonStyle(isSelected: isSelected))

            // 环境和备注不进这个框——换一件事是高频动作，中间不能有表单。
            // 需要它们的时候从这里进完整的开始表单，名字带过去。
            Button(tr("more_settings")) {
                onNewWorkDetails(newName)
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            .padding(.trailing, 6)
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 14) {
            footHint(key: "↑↓", label: tr("choose"))
            footHint(key: "↩", label: tr("start"))
            footHint(key: "esc", label: tr("close"))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(LightAnchorTheme.windowBackground)
    }

    private func footHint(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key)
                .font(LightAnchorTheme.monoFont(size: 10, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
            Text(label)
                .font(LightAnchorTheme.supportingFont(size: 11))
                .foregroundStyle(LightAnchorTheme.faintInk)
        }
    }

    // MARK: - 选择与执行

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
        // 先记下手上那件是谁：切换成功之后它已经变成 paused，问不出「刚才是谁」。
        let previous = workspace.currentEpisode
        let previousName = previous
            .flatMap { workspace.snapshot.targets[$0.targetID]?.name }
        let previousTargetID = previous?.targetID
        let wasHeld = previous.map { $0.state != .paused && $0.state != .ended } ?? false

        let switchedTargetID: UUID?
        switch candidate {
        case .resume(let targetID):
            switchedTargetID = workspace.startEpisode(targetID: targetID)?.targetID
        case .capture(let captureID):
            switchedTargetID = workspace.createTargetFromCapture(captureID)?.id
        case .create(let name):
            switchedTargetID = workspace.createTarget(name: name)
                .flatMap { workspace.startEpisode(targetID: $0.id)?.targetID }
        }
        guard let switchedTargetID else { return }

        // 只有真的换走了才报「已放下」：接着做手上那件时什么也没被放下。
        if wasHeld, let previousName, previousTargetID != switchedTargetID {
            workspace.presentNotice(
                String(format: tr("set_aside_x_and_recorded_the"), previousName)
            )
        }
        onSwitched()
    }
}

/// 面板里一行代表的东西。三种来源共用一个 ↑↓ 序列，所以要能互相比较。
private enum SwitchCandidate: Equatable {
    case resume(UUID)
    case capture(UUID)
    case create(String)
}
