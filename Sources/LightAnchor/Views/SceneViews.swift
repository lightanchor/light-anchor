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

            // 现场条目列表
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.restorableItems) { item in
                    SceneItemRow(item: item)
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

/// 采集瞬间的剪贴板内容：显示前两行，一键放回系统剪贴板。
struct SceneClipboardRow: View {
    let text: String
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LightAnchorIcon("clipboard", size: 15)
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("clipboard_at_the_time"))
                    .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Text(text)
                    .font(LightAnchorTheme.bodyFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
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
        .background(LightAnchorTheme.surface)
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
            .background(LightAnchorTheme.surface)
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

    var body: some View {
        HStack(spacing: 10) {
            LightAnchorIcon(item.kind.iconName, size: 15)
                .foregroundStyle(isTucked ? LightAnchorTheme.faintInk : LightAnchorTheme.mutedInk)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isTucked ? LightAnchorThemeColor.clear : LightAnchorTheme.surface)
    }
}

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
