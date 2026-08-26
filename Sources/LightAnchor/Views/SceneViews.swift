import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - 现场清单卡片
//
// 嵌入「现在」空间，显示当前目标的现场条目、AI 筛选开关和「回来先看」。

struct SceneCardView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let episode: AttentionEpisode
    let target: AttentionTarget
    /// 样机 .chip.go「恢复现场 →」：有现场时的一键恢复。
    var onRestore: (() -> Void)? = nil

    @State private var isCapturing = false
    @State private var editingReturnCue = false
    @State private var returnCueDraft = ""
    @State private var showingTuckedAway = false
    /// 手动「记录当前现场」的结果反馈——失败或空结果时不能点了没反应。
    @State private var captureFeedback: SceneCaptureFeedback?

    private enum SceneCaptureFeedback {
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

    private var sceneSnapshot: SceneSnapshot? {
        workspace.snapshot.latestSceneSnapshot(for: target.id)
    }

    private var filterMode: SceneFilterMode {
        target.sceneFilterMode ?? workspace.intelligencePreferences.sceneFilterDefault
    }

    /// 菜单里的 Picker 走这个绑定：改模式即落偏好并重采一次现场。
    private var filterSelection: Binding<SceneFilterMode> {
        Binding(
            get: { filterMode },
            set: { mode in
                guard mode != filterMode else { return }
                _ = workspace.updateSceneFilterMode(for: target.id, mode: mode)
                Task { await recapture() }
            }
        )
    }

    var body: some View {
        if let snapshot = sceneSnapshot, !snapshot.items.isEmpty {
            sceneCard(snapshot: snapshot)
        } else {
            emptySceneCard
        }
    }

    // MARK: - 有现场条目

    private func sceneCard(snapshot: SceneSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 卡片头部：标题 + 次级筛选入口
            HStack {
                LightAnchorLabel(title: tr("scene"), icon: "layers", spacing: 7)
                    .font(LightAnchorTheme.headingFont())
                    .foregroundStyle(LightAnchorTheme.ink)
                Spacer(minLength: 16)
                if let onRestore, !snapshot.restorableItems.isEmpty {
                    Button(action: onRestore) {
                        Text(tr("restore_scene_2"))
                            .font(LightAnchorTheme.controlFont(size: 12, weight: .medium))
                            .foregroundStyle(LightAnchorTheme.accentInk)
                            .padding(.horizontal, 12)
                            .frame(height: 25)
                            .background(LightAnchorTheme.accentWash, in: Capsule(style: .continuous))
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("restore_scene"))
                }
                recaptureButton
                filterButton
            }

            // 刚放下这件事时，现场卡自己说一句「已保存」——反馈就落在
            // 用户正看着的这份清单上（换到别件事的场合走「已放下」确认卡）。
            if workspace.recentSetAside?.snapshotID == snapshot.id {
                Text(tr("scene_saved_note"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.accentInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 现场条目列表：条目由用户做主，不需要的直接剔掉。
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.restorableItems) { item in
                    SceneItemRow(item: item, onRemove: {
                        _ = workspace.removeSceneItem(snapshot.id, itemID: item.id)
                    })
                }
            }

            // AI 收起提示
            if snapshot.tuckedAwayCount > 0 {
                tuckedAwayRow(count: snapshot.tuckedAwayCount, snapshot: snapshot)
            }

            // 采集瞬间的剪贴板与桌面截图（对应开关开启时才有）
            if !snapshot.clipboardText.isEmpty {
                SceneClipboardRow(text: snapshot.clipboardText)
            }
            SceneScreenshotRow(assetURL: snapshot.screenshotAssetURL)

            // 重新记录后的结果反馈：成功时条目自己会刷新，空/失败必须说清楚。
            if let captureFeedback {
                Text(captureFeedback.message)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(
                        captureFeedback.isPositive
                            ? LightAnchorTheme.accentInk
                            : LightAnchorTheme.warning
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 回来先看
            returnCueRow(snapshot: snapshot)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 空现场

    private var emptySceneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LightAnchorLabel(title: tr("scene"), icon: "layers", spacing: 7)
                    .font(LightAnchorTheme.headingFont())
                    .foregroundStyle(LightAnchorTheme.ink)
                Spacer(minLength: 16)
                filterButton
            }
            Text(tr("no_scene_recorded_yet_when_you"))
                .font(LightAnchorTheme.bodyFont(size: 13))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .lineSpacing(3)
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // 凸起白面按钮：安静按钮的凹陷底在这张米灰卡上会隐形。
            Button {
                Task { await recapture() }
            } label: {
                HStack(spacing: 6) {
                    if isCapturing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isCapturing ? tr("recording") : tr("record_current_scene"))
                }
            }
            .buttonStyle(LightAnchorRaisedButtonStyle())
            .disabled(isCapturing)

            if let captureFeedback {
                Text(captureFeedback.message)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(
                        captureFeedback.isPositive
                            ? LightAnchorTheme.accentInk
                            : LightAnchorTheme.warning
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 子组件

    /// 已有现场时的重新采集入口：覆盖保存当前现场（空现场时走大按钮）。
    private var recaptureButton: some View {
        Button {
            Task { await recapture() }
        } label: {
            HStack(spacing: 6) {
                if isCapturing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isCapturing ? tr("recording") : tr("record_again"))
            }
        }
        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
        .disabled(isCapturing)
        .help(tr("record_current_scene"))
        .accessibilityLabel(tr("record_current_scene"))
    }

    /// 筛选方式直接用勾选菜单：之前的浮窗里再套一个带标题的下拉框，
    /// 标题重复、层级也多余。菜单体用 inline Picker，勾号走系统保留列，
    /// 未选中项不会与选中项错位。
    private var filterButton: some View {
        Menu {
            Picker(tr("scene_filter_2"), selection: filterSelection) {
                ForEach(SceneFilterMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                LightAnchorIcon("sliders-horizontal", size: 13)
                // 各模式标题不等宽：隐藏铺底取最宽，切换时按钮不变宽、
                // 邻位按钮不挪窝。
                ZStack(alignment: .leading) {
                    ForEach(SceneFilterMode.allCases, id: \.self) { mode in
                        Text(mode.title).hidden()
                    }
                    Text(filterMode.title)
                }
                LightAnchorIcon("chevron-down", size: 8)
            }
            .font(LightAnchorTheme.controlFont(size: 12, weight: .medium))
            .foregroundStyle(LightAnchorTheme.mutedInk)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(LightAnchorTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("scene_filter_2"))
        .accessibilityLabel(String(format: tr("scene_filter"), filterMode.title))
    }

    private func tuckedAwayRow(count: Int, snapshot: SceneSnapshot) -> some View {
        Group {
            if showingTuckedAway {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.items.filter { !$0.isRelevant }) { item in
                        SceneItemRow(item: item, isTucked: true) {
                            _ = workspace.toggleSceneItemRelevance(snapshot.id, itemID: item.id)
                        }
                    }
                    Button(tr("tuck_away")) { showingTuckedAway = false }
                        .buttonStyle(LightAnchorInlineButtonStyle())
                        .padding(.top, 2)
                }
            } else {
                Button {
                    showingTuckedAway.toggle()
                } label: {
                    HStack(spacing: 6) {
                        LightAnchorIcon("eye-off", size: 14)
                        Text(String(
                            format: count == 1
                                ? tr("ai_tucked_away_unrelated_windows_one")
                                : tr("ai_tucked_away_unrelated_windows"),
                            count
                        ))
                    }
                    .font(LightAnchorTheme.supportingFont(size: 12, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 「回来先看」只有一个：episode.returnCue。这里的编辑与现场舱同源，
    /// 保存时顺带同步进快照，让「重返现场」面板显示同一句话。
    private func returnCueRow(snapshot: SceneSnapshot?) -> some View {
        Group {
            if editingReturnCue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("look_at_this_first"))
                        .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                    HStack(spacing: 8) {
                        TextField(tr("what_to_look_at_first"), text: $returnCueDraft)
                            .textFieldStyle(LightAnchorTextFieldStyle())
                            .onSubmit { commitReturnCue(snapshot) }
                        Button(tr("save")) { commitReturnCue(snapshot) }
                            .buttonStyle(LightAnchorPrimaryButtonStyle())
                        Button(tr("cancel")) {
                            editingReturnCue = false
                            returnCueDraft = ""
                        }
                            .buttonStyle(LightAnchorInlineButtonStyle())
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("look_at_this_first"))
                            .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                        Text(episode.returnCue.isEmpty ? tr("not_set") : episode.returnCue)
                            .font(LightAnchorTheme.bodyFont(size: 13))
                            .foregroundStyle(episode.returnCue.isEmpty
                                ? LightAnchorTheme.faintInk
                                : LightAnchorTheme.ink)
                            .lineSpacing(3)
                    }
                    Spacer()
                    Button {
                        returnCueDraft = episode.returnCue
                        editingReturnCue = true
                    } label: {
                        LightAnchorIcon("pencil", size: 14)
                    }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                    .help(tr("edit_look_at_this_first"))
                    .accessibilityLabel(tr("edit_look_at_this_first"))
                }
            }
        }
        .padding(12)
        .background(LightAnchorTheme.recessed, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 动作

    private func recapture() async {
        isCapturing = true
        captureFeedback = nil
        let snapshot = await workspace.captureSceneSnapshot(refreshingContext: true)
        isCapturing = false
        // 反馈结果：成功时卡片会自己长出条目，空/失败时必须说清楚，
        // 否则「点了跟没点一样」。
        if let snapshot {
            captureFeedback = snapshot.items.isEmpty
                ? .empty(
                    accessibilityGranted: PrivacyPermissionService()
                        .status(for: .accessibility) == .granted
                )
                : .saved(snapshot.items.count)
        } else {
            captureFeedback = .failed
        }
    }

    private func commitReturnCue(_ snapshot: SceneSnapshot?) {
        _ = workspace.updateContext(
            for: episode.id,
            context: episode.context,
            returnCue: returnCueDraft
        )
        if let snapshot {
            _ = workspace.updateSceneReturnCue(snapshot.id, returnCue: returnCueDraft)
        }
        editingReturnCue = false
        returnCueDraft = ""
    }
}

// MARK: - 剪贴板与截图行（现场卡片和重返面板共用）

/// 采集瞬间的剪贴板内容：与条目行同一副行体——图标瓦片垂直居中、
/// 内容做主行、「当时的剪贴板」做出处小字，混在同一列里不另起一套构图。
/// 全文进 tooltip，一键放回系统剪贴板。
struct SceneClipboardRow: View {
    let text: String
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 10) {
            SceneGlyphTile(name: "clipboard")
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(LightAnchorTheme.bodyFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                    .help(text)
                    .textSelection(.enabled)
                Text(tr("clipboard_at_the_time"))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            Spacer(minLength: 10)
            Button(justCopied ? tr("put_back") : tr("put_back_on_clipboard")) {
                #if os(macOS)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                justCopied = true
                #endif
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            .disabled(justCopied)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LightAnchorTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 采集瞬间的桌面截图缩略图，点击用系统看图打开。文件不在了就整行不显示。
struct SceneScreenshotRow: View {
    let assetURL: URL?

    private var availableURL: URL? {
        guard let assetURL,
              FileManager.default.fileExists(atPath: assetURL.path)
        else { return nil }
        return assetURL
    }

    var body: some View {
        #if os(macOS)
        if let url = availableURL, let image = NSImage(contentsOf: url) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LightAnchorTheme.subtleBorder.opacity(0.72), lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("desktop_when_you_switched_away"))
                            .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                        Text(tr("click_to_view_full_size"))
                            .font(LightAnchorTheme.supportingFont(size: 11))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LightAnchorTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(tr("view_the_desktop_screenshot_from_when"))
        }
        #endif
    }
}

// MARK: - 现场条目行

struct SceneItemRow: View {
    let item: SceneItem
    var isTucked: Bool = false
    var onAddBack: (() -> Void)? = nil
    /// 手动剔除（现场卡 / 「已放下」确认卡）：现场里不需要的条目由用户删。
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            SceneItemIconView(item: item, isTucked: isTucked)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(LightAnchorTheme.bodyFont(size: 13, weight: .medium))
                    .foregroundStyle(isTucked ? LightAnchorTheme.faintInk : LightAnchorTheme.ink)
                    .lineLimit(1)
                    // 被截的是文件名/网址尾部，tooltip 留住完整值。
                    .help(item.title)
                if !item.sourceApplication.isEmpty || !item.detail.isEmpty {
                    HStack(spacing: 4) {
                        if !item.sourceApplication.isEmpty {
                            Text(item.sourceApplication)
                        }
                        if !item.sourceApplication.isEmpty && !item.detail.isEmpty {
                            Text("·")
                        }
                        if !item.detail.isEmpty {
                            Text(item.detail)
                        }
                    }
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
                    .help([item.sourceApplication, item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }

            Spacer()

            if isTucked, let onAddBack {
                Button {
                    onAddBack()
                } label: {
                    LightAnchorIcon("plus", size: 14)
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                .help(tr("add_back_to_scene"))
                .accessibilityLabel(tr("add_back_to_scene"))
            }

            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    LightAnchorIcon("x", size: 13)
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                .help(tr("remove_from_scene"))
                .accessibilityLabel(tr("remove_from_scene"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 白面行也要说圆角语言：直角白条在米灰卡里是全应用唯一的方角，扎眼。
        .background(
            isTucked ? LightAnchorThemeColor.clear : LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

// MARK: - 「已放下」确认弹窗

/// 放下一件事（暂时放下 / 换一件事）后的确认 sheet（用户定：要弹窗形式）。
/// 内容按「放下这一刻要什么」组织：这段专注了多久（收个尾）、趁记忆
/// 还热写下「回来先看」、现场存了什么（条目可逐条剔除）。
struct RecentSetAsideSheet: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let info: AttentionWorkspace.RecentSetAside

    @State private var cueDraft = ""
    /// 打开时现场里已有的「回来先看」（AI 草拟或早先写的）：没改就不写回。
    @State private var loadedCue = ""
    /// 弹窗的正事就是趁记忆热写这句话：打开即聚焦，写完回车就是「知道了」。
    @FocusState private var cueFocused: Bool

    private var sceneSnapshot: SceneSnapshot? {
        workspace.snapshot.sceneSnapshots[info.snapshotID]
    }

    /// 这段的专注时长：快照记着产生它的工作段；旧数据没有段号就不硬凑。
    private var focusLabel: String? {
        guard let episodeID = sceneSnapshot?.episodeID else { return nil }
        let minutes = workspace.snapshot.focusMinutes(of: episodeID)
        guard minutes > 0 else { return nil }
        return UserFacingCopy.focusDuration(minutes)
    }

    private var subtitle: String {
        if let focusLabel {
            return String(format: tr("set_aside_sheet_meta"), focusLabel)
        }
        return tr("set_aside_sheet_meta_no_duration")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("set_aside"),
                title: String(format: tr("set_aside_sheet_title"), info.targetName),
                subtitle: subtitle,
                icon: "circle-check"
            )

            // 回来先看：放下的这一刻记忆最热，是写这句话的唯一好时机——
            // 回来时它就是重返面板的第一行。
            VStack(alignment: .leading, spacing: 6) {
                sheetSectionLabel(tr("look_at_this_first"))
                TextField(tr("what_to_look_at_first_2"), text: $cueDraft)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .focused($cueFocused)
            }

            if let snapshot = sceneSnapshot {
                VStack(alignment: .leading, spacing: 6) {
                    sheetSectionLabel(tr("scene"))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(snapshot.restorableItems) { item in
                                SceneItemRow(item: item, onRemove: {
                                    _ = workspace.removeSceneItem(snapshot.id, itemID: item.id)
                                })
                            }
                            if !snapshot.clipboardText.isEmpty {
                                SceneClipboardRow(text: snapshot.clipboardText)
                            }
                        }
                        .lightAnchorRecessed(radius: 14, padding: 13)
                        .padding(.vertical, 1)
                    }
                    // 300 恰好放下五行（应用/文件/链接若干 + 剪贴板）不裁行；
                    // 更多条目时从整行边界起卷。
                    .frame(maxHeight: 300)
                    .scrollIndicators(.never)
                }
            }

            LightAnchorSheetActionBar {
                Button(tr("got_it")) {
                    commitCue()
                    dismiss()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            let cue = sceneSnapshot?.returnCue ?? ""
            cueDraft = cue
            loadedCue = cue
            cueFocused = true
        }
        // Esc / 点外面关掉也不丢刚写的话。
        .onDisappear(perform: commitCue)
    }

    private func sheetSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
            .foregroundStyle(LightAnchorTheme.mutedInk)
    }

    private func commitCue() {
        let trimmed = cueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loadedCue else { return }
        guard let snapshot = sceneSnapshot else { return }
        _ = workspace.updateSceneReturnCue(snapshot.id, returnCue: trimmed)
        // 段上的「回来先看」与现场快照是同一句话的两个落点，一起更新。
        if let episodeID = snapshot.episodeID,
           let episode = workspace.snapshot.episodes[episodeID] {
            _ = workspace.updateContext(for: episodeID, context: episode.context, returnCue: trimmed)
        }
        loadedCue = trimmed
    }
}

// MARK: - 现场条目图标

/// 线框图标坐进 17pt 圆角瓦片：与真实应用图标同一个剪影和尺寸，
/// 混排在同一列里天然对齐（裸线框和实心应用图标怎么调字号都对不齐）。
struct SceneGlyphTile: View {
    let name: String
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(LightAnchorTheme.recessed)
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            LightAnchorIcon(name, size: 11)
                .foregroundStyle(dimmed ? LightAnchorTheme.faintInk : LightAnchorTheme.mutedInk)
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

/// 现场条目的图标：能认出真实来源就用系统里的真图标——应用条目直接是
/// 应用图标，终端/网页跟来源应用走，文件用文件本身的图标；认不出（应用
/// 已卸载、演示数据等）退回同尺寸的线框瓦片。
private struct SceneItemIconView: View {
    let item: SceneItem
    var isTucked: Bool = false

    var body: some View {
        #if os(macOS)
        if let image = SceneItemIconResolver.icon(for: item) {
            // 17pt：应用图标自带内边距，画到 17 视觉上才和瓦片同一量级。
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .saturation(isTucked ? 0 : 1)
                .opacity(isTucked ? 0.55 : 1)
                .accessibilityHidden(true)
        } else {
            SceneGlyphTile(name: item.kind.iconName, dimmed: isTucked)
        }
        #else
        SceneGlyphTile(name: item.kind.iconName, dimmed: isTucked)
        #endif
    }
}

#if os(macOS)
/// 只在主线程的视图渲染路径里被调用，缓存也就锚在 MainActor 上。
@MainActor
enum SceneItemIconResolver {
    /// 每分钟的 TimelineView 重渲染会反复走到这里，查一次记一次；
    /// NSCache 自己管内存压力下的淘汰。
    private static let cache = NSCache<NSString, NSImage>()
    /// 查过且没查到的键也要记住，否则每帧都去扫 runningApplications。
    private static var misses = Set<String>()

    static func icon(for item: SceneItem) -> NSImage? {
        let key = "\(item.kind.rawValue)|\(item.address)|\(item.sourceApplication)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        guard let image = resolve(item) else {
            misses.insert(key)
            return nil
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func resolve(_ item: SceneItem) -> NSImage? {
        let workspace = NSWorkspace.shared
        switch item.kind {
        case .application:
            if let url = workspace.urlForApplication(withBundleIdentifier: item.address) {
                return workspace.icon(forFile: url.path)
            }
            return appIcon(named: item.sourceApplication)
        case .terminal:
            return appIcon(named: item.sourceApplication)
        case .file:
            if let url = fileURL(from: item.address),
               FileManager.default.fileExists(atPath: url.path) {
                return workspace.icon(forFile: url.path)
            }
            return appIcon(named: item.sourceApplication)
        case .link:
            if let icon = appIcon(named: item.sourceApplication) { return icon }
            // 来源浏览器认不出时退而求其次：这个网址的默认打开方。
            if let url = URL(string: item.address),
               let handler = workspace.urlForApplication(toOpen: url) {
                return workspace.icon(forFile: handler.path)
            }
            return nil
        }
    }

    private static func fileURL(from address: String) -> URL? {
        if address.hasPrefix("file://") { return URL(string: address) }
        if address.hasPrefix("/") { return URL(fileURLWithPath: address) }
        return nil
    }

    /// 按来源应用名找图标：先在正在运行的应用里找（现场条目的来源多半
    /// 还开着，且 localizedName 与采集时记下的名字同源），退出了再去
    /// 常见安装位置按 .app 名兜底。
    private static func appIcon(named name: String) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return app.icon
        }
        for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                          "\(NSHomeDirectory())/Applications"] {
            let path = "\(directory)/\(trimmed).app"
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }
}
#endif

// MARK: - 筛选模式切换

struct SceneFilterPicker: View {
    let mode: SceneFilterMode
    let onChange: (SceneFilterMode) -> Void
    @State private var selection: SceneFilterMode

    init(mode: SceneFilterMode, onChange: @escaping (SceneFilterMode) -> Void) {
        self.mode = mode
        self.onChange = onChange
        _selection = State(initialValue: mode)
    }

    var body: some View {
        // 铺满整行：标题贴左缘、控件贴右缘，与设置页其他 .setrow 对齐
        // （fixedSize 会让整行缩成一团浮在卡片中间）。
        LightAnchorSelectField(
            tr("filter_scene"),
            selection: $selection,
            options: SceneFilterMode.allCases,
            titleForValue: { $0.title }
        )
        .onChange(of: selection) { _, newValue in
            guard newValue != mode else { return }
            onChange(newValue)
        }
        .onChange(of: mode) { _, newValue in
            selection = newValue
        }
    }
}

// MARK: - 回场简报（「现在」页等待态 + 重返面板共用）

/// 简报三行：你在哪 / 发生了什么 / 先做什么。
struct ReturnBriefingRows: View {
    let briefing: ReturnBriefing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(tr("where_you_were"), briefing.whereYouWere)
            row(tr("what_happened"), briefing.whatHappened)
            row(tr("first_step"), briefing.firstStep)
        }
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .frame(width: 64, alignment: .leading)
            Text(text)
                .font(LightAnchorTheme.bodyFont(size: 13))
                .lineSpacing(3)
                .foregroundStyle(LightAnchorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 「现在」页等待态的回场简报卡：与重返面板同一输入组装与塑形，
/// 启发式立即稿先出，模型稿回来后原位替换。
struct ReturnBriefingCard: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let episodeID: UUID

    @State private var briefing: ReturnBriefing?

    var body: some View {
        Group {
            if let briefing {
                ReturnBriefingRows(briefing: briefing)
                    .lightAnchorRecessed(radius: 14, padding: 14)
            }
        }
        .task(id: episodeID) {
            await load()
        }
    }

    private func load() async {
        guard let input = workspace.makeReturnBriefingInput(episodeID: episodeID) else { return }
        let engine = workspace.intelligenceEngine
        briefing = await HeuristicIntelligenceEngine().generateReturnBriefing(input)
        if let refined = await engine.generateReturnBriefing(input) {
            briefing = refined
        }
    }
}

// MARK: - 一键重返确认面板

struct SceneReturnPanel: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let snapshot: SceneSnapshot
    /// 如果这次重返是为了解决一个等待结果，传入其 ID——恢复时会把等待标记为已解决并激活原 episode。
    var waitingID: UUID? = nil
    let onRestore: () -> Void
    let onCancel: () -> Void

    @State private var selectedKinds: Set<SceneItemKind> = []
    @State private var staleness: [UUID: SceneItemStaleness] = [:]
    @State private var isRestoring = false
    @State private var briefing: ReturnBriefing?
    @State private var showingEnvironmentEditor = false

    private var itemsByKind: [(SceneItemKind, [SceneItem])] {
        SceneItemKind.allCases.compactMap { kind in
            let items = snapshot.restorableItems.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("scene_snapshot"),
                title: tr("return_to_the_scene"),
                subtitle: tr("pick_what_to_restore_the_app"),
                icon: "rotate-ccw"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let briefing {
                        returnBriefingBlock(briefing)
                    } else if !snapshot.returnCue.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            // 同一「回来先看」标签在现场卡里是 supportingFont(11)，
                            // 这里曾是 .caption（10pt）——归一到令牌，别让同内容分叉。
                            Text(tr("look_at_this_first"))
                                .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                                .foregroundStyle(LightAnchorTheme.mutedInk)
                            Text(snapshot.returnCue)
                                .font(LightAnchorTheme.bodyFont(size: 13))
                                .lineSpacing(3)
                        }
                        .lightAnchorRecessed(radius: 14, padding: 14)
                    }

                    ForEach(itemsByKind, id: \.0) { kind, items in
                        kindSection(kind: kind, items: items)
                    }

                    if !snapshot.clipboardText.isEmpty {
                        SceneClipboardRow(text: snapshot.clipboardText)
                    }
                    SceneScreenshotRow(assetURL: snapshot.screenshotAssetURL)

                    if staleness.values.contains(where: { $0.isActionable }) {
                        stalenessWarnings
                    }
                }
                .padding(.vertical, 1)
            }

            LightAnchorSheetActionBar {
                Button(tr("cancel"), action: onCancel)
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if !EnvironmentSnapshotBuilder.draft(from: snapshot).actions.isEmpty {
                    Button(tr("save_as_environment")) { showingEnvironmentEditor = true }
                        .buttonStyle(LightAnchorQuietButtonStyle())
                        .help(tr("open_the_environment_editor_and_review"))
                }
                Button {
                    performRestore()
                } label: {
                    HStack(spacing: 6) {
                        if isRestoring {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isRestoring ? tr("restoring") : tr("return"))
                    }
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(isRestoring || selectedKinds.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            selectedKinds = Set(itemsByKind.map(\.0))
            if workspace.intelligencePreferences.checkSceneStaleness {
                staleness = SceneStalenessChecker.checkAll(snapshot.restorableItems)
            }
            loadBriefing()
        }
        .sheet(isPresented: $showingEnvironmentEditor) {
            EnvironmentEditorView(
                profile: nil,
                draft: EnvironmentSnapshotBuilder.draft(from: snapshot)
            )
            .environmentObject(workspace)
        }
    }

    /// 回场简报：启发式立即稿先出，模型稿回来后替换。
    private func loadBriefing() {
        guard let input = workspace.makeReturnBriefingInput(
            sceneSnapshot: snapshot,
            waitingID: waitingID
        ) else { return }
        let engine = workspace.intelligenceEngine
        Task { @MainActor in
            briefing = await HeuristicIntelligenceEngine().generateReturnBriefing(input)
            if let refined = await engine.generateReturnBriefing(input) {
                briefing = refined
            }
        }
    }

    private func returnBriefingBlock(_ briefing: ReturnBriefing) -> some View {
        ReturnBriefingRows(briefing: briefing)
            .lightAnchorRecessed(radius: 14, padding: 14)
    }

    private func kindSection(kind: SceneItemKind, items: [SceneItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if selectedKinds.contains(kind) {
                    selectedKinds.remove(kind)
                } else {
                    selectedKinds.insert(kind)
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedKinds.contains(kind)
                                ? LightAnchorTheme.accentInk
                                : LightAnchorTheme.elevatedSurface)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                selectedKinds.contains(kind)
                                    ? LightAnchorTheme.accentInk.opacity(0.45)
                                    : LightAnchorTheme.ink.opacity(0.13),
                                lineWidth: 1
                            )
                        if selectedKinds.contains(kind) {
                            LightAnchorIcon("check", size: 11)
                                .foregroundStyle(LightAnchorTheme.onAction)
                        }
                    }
                    .frame(width: 20, height: 20)

                    LightAnchorIcon(kind.iconName, size: 15)
                        .foregroundStyle(LightAnchorTheme.mutedInk)

                    // 「文件 (3)」是标签+计数，不是对齐承载信息的值：主题自己的
                    // 规则说这种不走 monoFont（SF Mono 无中文字形，会两套字面混排）。
                    Text("\(kind.title) (\(items.count))")
                        .font(LightAnchorTheme.controlFont(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.ink)

                    Spacer()

                    // 失效标记
                    if items.contains(where: { staleness[$0.id]?.isActionable == true }) {
                        LightAnchorIcon("alert-triangle", size: 14)
                            .foregroundStyle(LightAnchorTheme.warning)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 勾选状态只画不说，旁白听不出勾没勾。
            .accessibilityAddTraits(selectedKinds.contains(kind) ? .isSelected : [])

            if selectedKinds.contains(kind) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(LightAnchorTheme.supportingFont(size: 12))
                                .foregroundStyle(LightAnchorTheme.mutedInk)
                                .lineLimit(1)
                                // 被截的是文件名/网址尾部，而这正是勾选决策的依据，
                                // tooltip 把完整值留在可达位置。
                                .help(item.title)
                            if let stale = staleness[item.id], stale.isActionable {
                                Text(staleWarningText(stale))
                                    .font(LightAnchorTheme.supportingFont(size: 11))
                                    .foregroundStyle(LightAnchorTheme.warning)
                            }
                        }
                        .padding(.leading, 30)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LightAnchorTheme.recessed,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var stalenessWarnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LightAnchorIcon("alert-triangle", size: 14)
                    .foregroundStyle(LightAnchorTheme.warning)
                Text(tr("some_of_it_may_have_changed"))
                    .font(LightAnchorTheme.supportingFont(size: 12, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.warning)
            }
            ForEach(snapshot.restorableItems.filter { staleness[$0.id]?.isActionable == true }) { item in
                if let stale = staleness[item.id] {
                    Text("• \(item.title): \(staleWarningText(stale))")
                        .font(LightAnchorTheme.supportingFont(size: 11))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LightAnchorTheme.warningBackground.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func staleWarningText(_ stale: SceneItemStaleness) -> String {
        switch stale {
        case .fresh: ""
        case .possiblyChanged(let reason), .missing(let reason): reason
        }
    }

    private func performRestore() {
        isRestoring = true
        let report = workspace.restoreScene(
            snapshot.id,
            selectedKinds: selectedKinds,
            resolvingWaitingID: waitingID
        )
        isRestoring = false
        if report.hasIssues {
            workspace.presentNotice(UserFacingCopy.limitation(report.summary))
        } else if !report.summary.isEmpty {
            workspace.presentNotice(report.summary)
        }
        onRestore()
    }
}
