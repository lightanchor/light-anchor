import AppKit
import SwiftUI

/// 「换一件事」（定稿：`docs/switch-work-redesign-r24-2026-09-09.html`——r23 的结构与
/// 布局之上取消邮票，并把配色与现场样式对齐「现在」页 `now-page-scrollrail`）。
///
/// 一块 1020×560 的面板，左右分工：
/// - 左栏（304）是**常驻清单**：搜索 + 分组列表（结果到了 / 放下的 / 等待中 / 稍后 / 新开）。
///   在左边选完，右边整句文字跟着更新——选择不再藏在句子里的弹出层。
/// - 右区是确认区：上面「现在 · 放下 → 切换到」是**两块同构的方块**——左边一张中性白卡，
///   右边一块浅蓝方块（时刻在右上角，留话和「回去开 N 样 ›」直接排进块里），
///   **两块永远等高**、中间一条静态细线箭头落在正中；下面三句话（怎么放 / 回来先看 /
///   接下来去哪）；页脚是主操作与键位。
///
/// 现场不另开容器：点「现场 N 样 ›」或块里那句「回去开 N 样 ›」，**右区原地换成现场页**
/// （左栏不动）。现场与「现在」页同源：两张白卡（东西在哪 / 当时的剪贴板），行首一枚记号
/// （实心蓝点＝会带走 / 空心灰圈＝不带），名字在上、位置在下，点一行就是改它带不带；
/// 剪贴板是一列复写行、中间放下过就断开；真有截图才出现一张缩略图。esc / ‹ 返回 回确认页。
///
/// 被否过的形态不要回头：邮票（齿孔 / 面值 / 蓝内框 / 撕边复写条）、命令面板、黑纱浮层、
/// 舞台接管、弹出层现场、侧翼现场、卡背面、翻页动画、圆形邮戳与杀戳线、点线邮路与
/// 跑动蓝点、按 应用/网页/文件/终端 分组的现场清单、占位空框（空态一律纯文字）、任何渐变。
struct SwitchWorkStage: View {
    let onSwitched: () -> Void
    let onDismiss: () -> Void
    /// 「新开…」：交给「开始一件事」那张便笺，名字带过去。凭空立一件事不在
    /// 这个面板的职责里——这里是从已有的里面挑一件。
    let onCreateNew: (String) -> Void
    /// 打开时预选的目标（步骤卡「切到这步」）：仪式照走，只是这一条已经挑好。
    var initialPick: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LightAnchorStageDim(colorScheme: colorScheme)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                // 设计尺寸 1020×560 是固定的；窗口被拖得比它小时按窗口收，不许溢出。
                SwitchWorkSheet(
                    onSwitched: onSwitched,
                    onDismiss: onDismiss,
                    onCreateNew: onCreateNew,
                    initialPick: initialPick,
                    available: CGSize(
                        width: max(520, proxy.size.width - 32),
                        height: max(360, proxy.size.height - 32)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SwitchWorkSheet: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 切换成功：主视图负责翻回「现在」并清掉回顾态。
    let onSwitched: () -> Void
    /// esc / 算了：收起舞台。
    let onDismiss: () -> Void
    /// 「新开…」：把名字交给「开始一件事」。
    let onCreateNew: (String) -> Void
    /// 打开时预选的目标：仪式照走，这一条已经挑好。
    var initialPick: UUID?
    /// 舞台给的可用尺寸（窗口比设计尺寸小时用来收面板）。
    var available: CGSize = CGSize(width: 10_000, height: 10_000)

    // 右区显示哪一页（左栏始终在）
    @State private var page = SwitchWorkPage.front

    // 三句话
    @State private var how = HowKind.pause
    @State private var waitingFor = ""
    @State private var returnCue = ""
    @State private var destination: SwitchDestination?
    @State private var showingHowPicker = false
    @State private var howHovered = false
    @State private var query = ""
    @State private var highlightedRow: Int?
    /// 两块（现在 / 要去的地方）各自内容的自然高度：取大的钉给两块，
    /// 它们就永远等高——右边多一行留话时左边跟着长，不会一高一低。
    @State private var nowBlockContentHeight: CGFloat = 0
    @State private var destinationBlockContentHeight: CGFloat = 0
    // ScrollView 是贪高的：量出内容高度，按内容收紧（否则面板永远撑满窗口）。
    @State private var sceneListHeight: CGFloat = 0
    @State private var sceneHeadHeight: CGFloat = 0
    @State private var sceneFootHeight: CGFloat = 0

    // 现场
    @State private var preview: AttentionWorkspace.ScenePreview?
    @State private var struckCurrentItemIDs: Set<UUID> = []
    @State private var struckDestinationItemIDs: Set<UUID> = []

    @FocusState private var focusedField: Field?
    @FocusState private var cardFocused: Bool

    fileprivate enum Field: Hashable { case waiting, cue, search }

    /// 设计尺寸（.panel / .panel.sp-open / .sb）。
    static let panelWidth: CGFloat = 1020
    static let panelHeight: CGFloat = 560
    static let scenePanelHeight: CGFloat = 620
    static let sidebarWidth: CGFloat = 304

    /// 现场页里列表之外的固定用量：上下内边距 30 / 20、列表与页脚之间 14。
    private static let sceneChromePadding: CGFloat = 64

    private var designMinHeight: CGFloat {
        page == .front ? Self.panelHeight : Self.scenePanelHeight
    }

    /// 现场页除列表以外都是量出来的，加上列表内容高就是这一页的自然高度。
    private var sceneChromeHeight: CGFloat {
        sceneHeadHeight + sceneFootHeight + Self.sceneChromePadding
    }

    /// 两块共用的高度：谁的内容高就用谁，再不低于设计里那 150。
    private var blockHeight: CGFloat {
        max(150, max(nowBlockContentHeight, destinationBlockContentHeight) + SwitchWorkBlock<EmptyView>.verticalPadding)
    }

    private var naturalHeight: CGFloat {
        page == .front ? Self.panelHeight : sceneChromeHeight + sceneListHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(
                    width: min(Self.sidebarWidth, max(220, available.width * 0.32)),
                    alignment: .top
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .background(LightAnchorTheme.stageSidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(LightAnchorTheme.stageLine).frame(width: 1)
                }
            mainColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: min(Self.panelWidth, available.width))
        // 设计里 560 / 620 是 min-height：内容多了面板就长高（现场页实测 772），
        // 窗口才是上限。固定高会把现场页的复写条裁掉；反过来，让它吃满窗口高
        // 又会在列表和页脚之间留一大片空白——所以这里算的是内容的自然高。
        .frame(height: min(max(designMinHeight, naturalHeight), available.height))
        // 先剪内容再垫底：clipShape 只管左栏那块方形底色，投影画在剪切之外，
        // 否则那圈 22px 的柔影会被圆角一起剪掉，面板边缘变成硬切。
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LightAnchorTheme.stagePanel)
                .lightAnchorStagePanelShadow()
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LightAnchorTheme.stageLine, lineWidth: 1)
        }
        // 打开时不聚焦任何输入框（设计：空里的游标在等你）；键盘事件要有人接，卡本身可聚焦。
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        // 「怎么放」的浮层要能溢出面板，画在面板之上。
        .overlayPreferenceValue(SwitchWorkAnchorKey.self) { anchors in
            howPopoverLayer(anchors)
        }
        .onChange(of: query) { _, value in liveSelect(for: value) }
        .onAppear {
            preview = workspace.previewCurrentScene()
            cardFocused = true
            if let initialPick,
               let row = selectableRows.first(where: { $0.destination == .target(initialPick) }) {
                choose(row)
            }
            #if DEBUG
            // 调试后门：LIGHTANCHOR_DEBUG_SWITCH_STATE 直接摆出某一页（截图/验收用）。
            switch ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_SWITCH_STATE"] {
            case "how": showingHowPicker = true
            // 打字态：默认打个命中的字；要验「新开」那支就用 LIGHTANCHOR_DEBUG_SWITCH_QUERY
            // 传一个查不到的名字。
            case "typed": query = ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_SWITCH_QUERY"] ?? "Lena"
            case "picked": selectableRows.first.map(choose)
            // 验收比对用：按名字子串选一条（和设计稿摆同一条数据才能逐项对齐）。
            case "pick-named":
                if let needle = ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_SWITCH_PICK"],
                   let row = selectableRows.first(where: { $0.title.contains(needle) }) {
                    choose(row)
                }
            case "current-scene": page = .currentScene
            case "destination-scene":
                // 挑现场条目最多的那件——验收时要看到最丰富的一页（分组、图标、复写条撕边）。
                let withScene = selectableRows.compactMap { row -> (SwitchWorkPickerRow, Int)? in
                    guard case .target(let id)? = row.destination,
                          let snapshot = workspace.snapshot.latestSceneSnapshot(for: id) else { return nil }
                    return (row, snapshot.restorableItems.count)
                }
                if let best = withScene.max(by: { $0.1 < $1.1 })?.0 {
                    choose(best)
                    page = .destinationScene
                }
            default: break
            }
            // 三种「怎么放」各自的句子与页脚：LIGHTANCHOR_DEBUG_SWITCH_HOW=wait|done。
            switch ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_SWITCH_HOW"] {
            case "wait": how = .wait
            case "done": how = .done
            default: break
            }
            #endif
        }
        .onKeyPress(.escape) { handleEscape() }
        .onKeyPress(keys: [.return]) { press in
            press.modifiers.contains(.command) ? handleCommandReturn() : handleReturn()
        }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
    }

    // MARK: - 左栏：搜索 + 常驻清单

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 设计 .search：白底、发丝边、11 圆角、8/12 内边距，左右外边距 4，下边距 10。
            HStack(spacing: 9) {
                LightAnchorIcon("magnifyingglass", size: 14)
                    .foregroundStyle(LightAnchorTheme.stageFaintInk)
                TextField(tr("switch_search_placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(LightAnchorTheme.interfaceFont(size: 14))
                    .focused($focusedField, equals: .search)
                    .onSubmit { _ = handleReturn() }
                Text(String(
                    format: trimmedQuery.isEmpty ? tr("switch_count_items") : tr("switch_count_hits"),
                    selectableRows.filter { !$0.isNew }.count
                ))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.stageFaintInk)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(-1)
            }
            // 设计里 input 的行高是 23（14 × 1.65），加上下各 8 的内边距总高 41——
            // 只按 14 号字排一行是 33，搜索框会比稿子矮一圈。
            .frame(minHeight: 25)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LightAnchorTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .background {
                // 聚焦圈（设计 .search:focus-within：border 转 --accent-soft + 3px --wash 外圈）。
                if focusedField == .search {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LightAnchorTheme.stageWash)
                        .padding(-3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        focusedField == .search ? LightAnchorTheme.stageAccentSoft : LightAnchorTheme.stageLine,
                        lineWidth: 1
                    )
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(indexedSidebarRows, id: \.row.id) { entry in
                        if entry.row.isHeader {
                            Text(entry.row.title)
                                .font(LightAnchorTheme.supportingFont(size: 10.5, weight: .semibold))
                                .kerning(1.5)
                                .foregroundStyle(LightAnchorTheme.stageFaintInk)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                        } else {
                            SwitchWorkSidebarRow(
                                row: entry.row,
                                highlight: trimmedQuery,
                                selected: entry.row.destination == destination
                                    || (entry.index != nil && entry.index == highlightedRow),
                                action: { choose(entry.row) }
                            )
                        }
                    }
                    if hiddenSidebarCount > 0 {
                        Text(String(format: tr("switch_more_rows"), hiddenSidebarCount))
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.stageFaintInk)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 设计 .rows 是 flex:1 + overflow:hidden：清单占满搜索框和键位行之间，
            // 装不下就在栏底裁掉。先前按窗口高封顶（available.height - 150）会把
            // 560 高的面板撑爆，整列被居中裁切——搜索框顶被削掉、键位行整行消失。
            .frame(maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.never)

            // 设计 .sb-foot：上发丝线，一行键位小字。
            VStack(spacing: 0) {
                Rectangle().fill(LightAnchorTheme.stageLine).frame(height: 1)
                HStack(spacing: 0) {
                    Text(tr("switch_sidebar_keys"))
                        .font(LightAnchorTheme.supportingFont(size: 11))
                        .foregroundStyle(LightAnchorTheme.stageFaintInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 右区

    @ViewBuilder
    private var mainColumn: some View {
        switch page {
        case .front: frontPage
        case .currentScene: currentScenePage
        case .destinationScene: destinationScenePage
        }
    }

    // MARK: - 确认页

    private var frontPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 设计 r24 .head：1fr / 44 / 1.06fr，min-height 150。
            // 两块**永远等高**：网格拉伸，箭头落在两者正中——右边多一行留话时
            // 也不会错位（padding 硬凑那版就是这么歪的）。
            HStack(alignment: .top, spacing: 10) {
                currentSide
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                SwitchWorkArrow()
                    .frame(width: 44, height: blockHeight)
                destinationSide
                    .frame(width: 252, alignment: .topLeading)
            }

            prose
            Spacer(minLength: 12)
            frontFoot
        }
        .padding(.horizontal, 34)
        .padding(.top, 30)
        .padding(.bottom, 20)
    }

    /// 左半：手上这件 —— 一张中性白卡。
    @ViewBuilder
    private var currentSide: some View {
        SwitchWorkBlock(
            tone: .now,
            height: blockHeight,
            onContentHeight: { nowBlockContentHeight = $0 }
        ) {
            if let entry = currentEntry {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow(howEyebrow)
                    HStack(spacing: 8) {
                        SwitchWorkDot(how.dotForm, size: 7)
                        Text(entry.target.name)
                            .font(LightAnchorTheme.interfaceFont(size: 16, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.ink)
                            .lineLimit(1)
                    }
                    .padding(.top, 5)
                    Text(currentMeta(entry))
                        .font(LightAnchorTheme.supportingFont(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.stageMutedInk)
                        .lineLimit(2)
                        .padding(.top, 5)
                    if preview.map({ !$0.items.isEmpty }) ?? false {
                        SwitchWorkSceneLink(title: currentEntryTitle) { page = .currentScene }
                            .padding(.top, 10)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow(tr("switch_now_eyebrow"))
                    Text(tr("switch_nothing_in_hand"))
                        .font(LightAnchorTheme.interfaceFont(size: 16, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.stageFaintInk)
                        .padding(.top, 5)
                }
            }
        }
    }

    /// 右半：要去的那件 —— 一块浅蓝方块（邮票整套已取消：齿孔、面值、内框都没了）。
    /// 时刻在右上角，留话和「回去开 N 样 ›」直接排进块里。
    @ViewBuilder
    private var destinationSide: some View {
        if destination == nil {
            SwitchWorkBlock(
                tone: .blank,
                height: blockHeight,
                onContentHeight: { _ in destinationBlockContentHeight = 0 }
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("switch_to"))
                        .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                        .kerning(0.45)
                        .foregroundStyle(LightAnchorTheme.stageFaintInk)
                    Text(tr("switch_not_chosen"))
                        .font(LightAnchorTheme.interfaceFont(size: 15, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.stageFaintInk)
                    Text(tr("switch_choose_hint_left"))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.stageFaintInk.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        } else {
            SwitchWorkBlock(
                tone: .destination,
                height: blockHeight,
                onContentHeight: { destinationBlockContentHeight = $0 }
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    // 眉标固定「切换到」（设计稿 .s-k）；动词只出现在句子里。
                    Text(destinationEyebrow)
                        .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                        .kerning(0.45)
                        .foregroundStyle(LightAnchorTheme.accentInk)
                        .lineLimit(1)
                        // 右上角那行时刻的位子：眉标不许伸过去。
                        .padding(.trailing, 62)
                    HStack(spacing: 8) {
                        SwitchWorkDot(destinationDotForm, size: 7)
                        Text(destinationName)
                            .font(LightAnchorTheme.interfaceFont(size: 15.5, weight: destinationNameIsPlaceholder ? .medium : .semibold))
                            .foregroundStyle(destinationNameIsPlaceholder ? LightAnchorTheme.stageFaintInk : LightAnchorTheme.ink)
                            .lineLimit(1)
                    }
                    .padding(.top, 6)
                    if !destinationMeta.isEmpty {
                        destinationMetaText
                            .font(LightAnchorTheme.supportingFont(size: 12.5))
                            .monospacedDigit()
                            .lineLimit(2)
                            .padding(.top, 5)
                    }
                    if let cue = destinationCue, !cue.isEmpty {
                        Text(cue)
                            .font(LightAnchorTheme.supportingFont(size: 12.5))
                            .foregroundStyle(LightAnchorTheme.secondaryInk)
                            .lineSpacing(4)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 9)
                    }
                    if destinationSnapshot != nil {
                        SwitchWorkSceneLink(title: reopenEntryTitle) { page = .destinationScene }
                            .padding(.top, 10)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !destinationStampTime.isEmpty {
                    Text(destinationStampTime)
                        .font(LightAnchorTheme.supportingFont(
                            size: 11.5,
                            weight: readyWaiting != nil ? .semibold : .regular
                        ))
                        .monospacedDigit()
                        .foregroundStyle(readyWaiting != nil
                            ? LightAnchorTheme.success
                            : LightAnchorTheme.stageMutedInk)
                        .lineLimit(1)
                        .padding(.trailing, 16)
                        .padding(.top, 15)
                }
            }
        }
    }

    /// 目的地那行状态：「恢复 4 样」+ 绿色的「Keynote 已开着」。
    private var destinationMetaText: Text {
        guard let highlight = destinationMetaHighlight, !highlight.isEmpty else {
            return Text(destinationMeta).foregroundStyle(LightAnchorTheme.stageMutedInk)
        }
        return Text(destinationMeta).foregroundStyle(LightAnchorTheme.stageMutedInk)
            + Text(verbatim: " · ").foregroundStyle(LightAnchorTheme.stageMutedInk)
            + Text(highlight).foregroundStyle(LightAnchorTheme.success)
    }

    private var destinationDotForm: SwitchWorkDotForm {
        switch destination {
        case nil, .create: return .new
        case .capture: return .idle
        case .target(let targetID):
            if readyWaiting != nil { return .ready }
            return workspace.unfinishedEpisode(for: targetID).map { SwitchWorkDotForm($0.state) } ?? .pause
        }
    }

    /// 票面右上角那行小字（圆邮戳被否后，时刻回到票面上）。
    private var destinationStampTime: String {
        guard let destination else { return "" }
        switch destination {
        // 新贴的票上没有时刻——右上角那行小字说的是「这件事上次是什么时候放下的」，
        // 一件还没开始的事没有这个。设计里新开的票只有三行。
        case .create: return ""
        case .capture(let id):
            guard let capture = workspace.snapshot.captures[id] else { return "" }
            return UserFacingCopy.relativeAge(of: capture.capturedAt)
        case .target:
            if let waiting = readyWaiting {
                return UserFacingCopy.relativeAge(of: waiting.completedAt ?? waiting.startedAt)
            }
            guard let episode = destinationEpisode else { return "" }
            // 还在等结果的，报的是「结果多久没来」；纯放下的报「你多久没管它」。
            if let waiting = outstandingWaiting {
                return UserFacingCopy.waitedAge(of: waiting.startedAt)
            }
            return UserFacingCopy.relativeAge(of: episode.updatedAt)
        }
    }

    // MARK: - 三句话

    private var prose: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LightAnchorTheme.stageLineSoft)
                .frame(height: 1)
                .padding(.bottom, 22)

            if let entry = currentEntry {
                sentence {
                    Text(String(format: tr("switch_sentence_set_down"), entry.target.name))
                    howPicker
                    Text(tr("switch_period"))
                }
                if how == .wait {
                    sentence {
                        Text(tr("switch_waiting_for_line"))
                        blank(text: $waitingFor, placeholder: tr("switch_waiting_placeholder"), field: .waiting)
                        Text(tr("switch_waiting_for_tail"))
                    }
                }
                sentence {
                    Text(tr("switch_return_cue_lead"))
                    blank(text: $returnCue, placeholder: tr("switch_return_cue_placeholder"), field: .cue)
                    Text(tr("switch_period"))
                }
            }
            sentence {
                Text(tr("switch_next_lead"))
                if let verb = destinationVerb { Text(verb) }
                whoText
                Text(destinationTail)
            }
        }
        .padding(.top, 24)
        .font(LightAnchorTheme.interfaceFont(size: 16))
        .foregroundStyle(LightAnchorTheme.ink)
    }

    private func sentence<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) { content() }
            .frame(height: 35, alignment: .leading)
    }

    private func blank(text: Binding<String>, placeholder: String, field: Field) -> some View {
        TextField(text: text, prompt: Text(placeholder).foregroundStyle(LightAnchorTheme.stageFaintInk)) {
            EmptyView()
        }
        .textFieldStyle(.plain)
        .font(LightAnchorTheme.interfaceFont(size: 16))
        .focused($focusedField, equals: field)
        .onSubmit { _ = handleReturn() }
        .frame(minWidth: 250)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .bottom) {
            SwitchWorkDottedRule(
                solid: focusedField == field,
                color: focusedField == field ? LightAnchorTheme.primary : LightAnchorTheme.stageFaintInk
            )
            .frame(height: 1)
            .offset(y: 3)
        }
        .padding(.horizontal, 2)
    }

    /// 「暂时放下 ˅」——点开三选一。
    private var howPicker: some View {
        Button {
            showingHowPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(how.title)
                    .font(LightAnchorTheme.interfaceFont(size: 16, weight: .medium))
                    .foregroundStyle(howHovered ? LightAnchorTheme.primary : LightAnchorTheme.stageMutedInk)
                SwitchWorkCaret(color: LightAnchorTheme.stageFaintInk)
            }
            .overlay(alignment: .bottom) {
                SwitchWorkDottedRule(solid: false, color: LightAnchorTheme.stageFaintInk)
                    .frame(height: 1).offset(y: 3)
            }
            .padding(.horizontal, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { howHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: howHovered)
        .anchorPreference(key: SwitchWorkAnchorKey.self, value: .bounds) { [.how: $0] }
    }

    /// 句子里的「去哪」：只是展示——选择在左栏做（设计定稿：选单显示在左边）。
    @ViewBuilder
    private var whoText: some View {
        if destination == nil {
            HStack(spacing: 0) {
                SwitchWorkCaretCursor(animated: !reduceMotion)
                Text(tr("switch_pick_placeholder_left"))
                    .font(LightAnchorTheme.interfaceFont(size: 15, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.stageFaintInk)
                    .padding(.leading, 7)
            }
            .overlay(alignment: .bottom) {
                SwitchWorkDottedRule(solid: false, color: LightAnchorTheme.stageFaintInk)
                    .frame(height: 1).offset(y: 3)
            }
            .padding(.horizontal, 2)
        } else {
            Text("「" + destinationName + "」")
                .font(LightAnchorTheme.interfaceFont(size: 16, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.primary)
                .lineLimit(1)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LightAnchorTheme.stageAccentSoft).frame(height: 1.5).offset(y: 3)
                }
                .padding(.horizontal, 2)
        }
    }

    /// 「怎么放」的三选一浮层（设计 .pop.small：230 宽、行 36）。
    @ViewBuilder
    private func howPopoverLayer(_ anchors: [SwitchWorkAnchorKey.Kind: Anchor<CGRect>]) -> some View {
        if page == .front, showingHowPicker, let anchor = anchors[.how] {
            GeometryReader { proxy in
                let rect = proxy[anchor]
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showingHowPicker = false }
                    SwitchWorkPopoverChrome(width: 230) {
                        VStack(spacing: 0) {
                            ForEach(HowKind.allCases, id: \.self) { kind in
                                SwitchWorkPopoverRow(
                                    dot: kind.dotForm,
                                    title: kind.title,
                                    subtitle: kind.subtitle,
                                    trailing: "",
                                    trailingEmphasis: false,
                                    isNew: false,
                                    highlighted: how == kind
                                ) {
                                    how = kind
                                    showingHowPicker = false
                                    if kind == .wait { focusedField = .waiting } else { focusedField = nil; cardFocused = true }
                                }
                            }
                        }
                    }
                    .offset(x: min(max(rect.minX - 10, 8), proxy.size.width - 238), y: rect.maxY + 9)
                }
            }
        }
    }

    private var frontFoot: some View {
        VStack(spacing: 0) {
            Rectangle().fill(LightAnchorTheme.stageLineSoft).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(spacing: 5) {
                    // 还没选的时候按回车也没地方去，就不摆那个 ↵（设计里空态只有一句话）。
                    if destination != nil { Text(verbatim: "↵") }
                    Text(primaryTitle)
                }
                .font(LightAnchorTheme.supportingFont(size: 12.5, weight: destination == nil ? .medium : .bold))
                .foregroundStyle(destination == nil ? LightAnchorTheme.stageFaintInk : LightAnchorTheme.primary)
                .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Text(tr("switch_key_tab"))
                    Text(tr("switch_key_esc"))
                }
                .font(LightAnchorTheme.supportingFont(size: 12.5))
                .foregroundStyle(LightAnchorTheme.stageFaintInk)
                .lineLimit(1)
            }
            .padding(.top, 14)
        }
    }

    // MARK: - 现场页：右区原地换页，左栏不动

    /// 手上那件的现场页：不论接下来是换旧事还是新开一件，这一页都只管
    /// 「哪些收进这份现场、哪些不带」（设计里它只有这一种样子）。
    private var currentScenePage: some View {
        let items = preview?.items ?? []
        let kept = items.count - struckCurrentItemIDs.count
        let capturedAt = preview?.context.capturedAt ?? Date()
        return scenePage(
            eyebrow: tr("switch_scene_page_now"),
            title: currentEntry?.target.name ?? "",
            meta: String(
                format: tr("switch_scene_meta_now"),
                Self.clock.string(from: capturedAt), items.count, kept, items.count - kept
            ),
            capturedAt: capturedAt,
            screenshotURL: nil,
            items: items,
            strips: currentStrips,
            listTitle: tr("where_things_are"),
            keptLabel: tr("switch_kept_take"),
            hint: tr("switch_hint_leave_it"),
            takeTitle: tr("scene_take_it"),
            dropTitle: tr("scene_drop_it"),
            place: { item, struck in
                if !item.detail.isEmpty { return item.detail }
                if struck, !item.isRelevant { return tr("switch_st_irrelevant") }
                return item.sourceApplication
            },
            isStruck: { struckCurrentItemIDs.contains($0.id) },
            toggle: { struckCurrentItemIDs.formSymmetricDifference([$0.id]) },
            allTitle: tr("switch_take_all"),
            noneTitle: tr("switch_take_none"),
            all: { struckCurrentItemIDs = [] },
            none: { struckCurrentItemIDs = Set(items.map(\.id)) }
        )
    }

    @ViewBuilder
    private var destinationScenePage: some View {
        if let snapshot = destinationSnapshot {
            let items = snapshot.restorableItems
            let reopening = items.count - struckDestinationItemIDs.count
            scenePage(
                eyebrow: String(format: tr("switch_scene_page_last"), destinationVerb ?? ""),
                title: destinationName,
                meta: String(
                    format: tr("switch_scene_meta_last"),
                    Self.clock.string(from: snapshot.capturedAt), items.count, reopening, items.count - reopening
                ),
                capturedAt: snapshot.capturedAt,
                screenshotURL: snapshot.screenshotAssetURL,
                items: items,
                strips: workspace.clipboardStrips(for: snapshot),
                listTitle: tr("switch_things_to_reopen"),
                keptLabel: tr("switch_kept_reopen"),
                hint: tr("switch_hint_dont_open_it"),
                takeTitle: tr("switch_st_take_open"),
                dropTitle: tr("switch_st_skip"),
                // 每一条都说清回去会怎样：划掉的「这次不开」、已经开着的「已开着」、
                // 其余报它的来源。
                place: { item, struck in
                    if !item.detail.isEmpty { return item.detail }
                    if struck { return tr("switch_st_skip_this_time") }
                    if item.kind == .application, Self.isRunning(bundleID: item.address) {
                        return tr("switch_st_open")
                    }
                    return item.sourceApplication
                },
                isStruck: { struckDestinationItemIDs.contains($0.id) },
                toggle: { struckDestinationItemIDs.formSymmetricDifference([$0.id]) },
                allTitle: tr("switch_restore_all"),
                noneTitle: tr("switch_restore_none"),
                all: { struckDestinationItemIDs = [] },
                none: { struckDestinationItemIDs = Set(items.map(\.id)) }
            )
        } else {
            frontPage
        }
    }

    private func scenePage(
        eyebrow: String,
        title: String,
        meta: String,
        capturedAt: Date,
        screenshotURL: URL?,
        items: [SceneItem],
        strips: [ClipboardStrip],
        listTitle: String,
        keptLabel: String,
        hint: String,
        takeTitle: String,
        dropTitle: String,
        place: @escaping (SceneItem, Bool) -> String,
        isStruck: @escaping (SceneItem) -> Bool,
        toggle: @escaping (SceneItem) -> Void,
        allTitle: String,
        noneTitle: String,
        all: @escaping () -> Void,
        none: @escaping () -> Void
    ) -> some View {
        let hasPhoto = screenshotURL != nil
        let kept = items.filter { !isStruck($0) }.count
        let tally = NowSceneSection.displayOrder
            .compactMap { kind -> String? in
                let count = items.filter { $0.kind == kind }.count
                return count > 0 ? "\(kind.title) \(count)" : nil
            }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            // 设计 .sp-head（haspic 时 min-height 126、正文右让 186）
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(LightAnchorTheme.supportingFont(size: 10.5, weight: .semibold))
                    .kerning(1.7)
                    .foregroundStyle(LightAnchorTheme.primary)
                Text(title)
                    .font(LightAnchorTheme.interfaceFont(size: 18.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                    .padding(.top, 6)
                Text(meta)
                    .font(LightAnchorTheme.supportingFont(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.stageMutedInk)
                    .padding(.top, 4)
            }
            .padding(.trailing, hasPhoto ? 186 : 0)
            .frame(maxWidth: .infinity, minHeight: hasPhoto ? 126 : 0, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if let screenshotURL {
                    SwitchWorkPhoto(url: screenshotURL, caption: photoCaption(at: capturedAt))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sceneHeadHeight = $0 }

            ScrollView {
                // 现场与「现在」页同源：两张白卡（东西在哪 / 当时的剪贴板），
                // 不再按 应用·网页·文件·终端 分组——卡头一行就把类别数报清了。
                VStack(alignment: .leading, spacing: 12) {
                    NowCard {
                        Text(listTitle)
                            .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.ink)
                            .fixedSize()
                        Text(tally.isEmpty
                            ? String(format: tr("scene_tally_plain"), items.count, kept)
                            : String(format: tr("switch_scene_tally"), items.count, tally, keptLabel, kept))
                            .font(LightAnchorTheme.supportingFont(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.stageMutedInk)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(hint)
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.stageFaintInk)
                            .lineLimit(1)
                            // 提示让位给右边两枚动作：挤不下先截提示，别把按钮挤成两行。
                            .layoutPriority(-1)
                        Button(noneTitle, action: none)
                            .buttonStyle(LightAnchorInlineButtonStyle())
                        Button(allTitle, action: all)
                            .buttonStyle(LightAnchorInlineButtonStyle())
                    } content: {
                        SceneThingsGrid(
                            items: items,
                            isOff: isStruck,
                            placeText: { place($0, isStruck($0)) },
                            takeTitle: takeTitle,
                            dropTitle: dropTitle,
                            toggle: toggle
                        )
                        .padding(4)
                    }

                    if !strips.isEmpty {
                        NowCard {
                            Text(tr("clipboard_then"))
                                .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                                .foregroundStyle(LightAnchorTheme.ink)
                                .fixedSize()
                            Text(String(
                                format: tr("clipboard_count"),
                                strips.reduce(0) { $0 + $1.entries.count }
                            ))
                            .font(LightAnchorTheme.supportingFont(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.stageMutedInk)
                            Spacer(minLength: 8)
                            Button(tr("clipboard_copy_all")) {
                                let text = strips.flatMap(\.entries).map(\.text).joined(separator: "\n")
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
                                        NowClipboardRow(entry: entry, isLatest: index == 0 && row == 0)
                                            .environmentObject(workspace)
                                    }
                                }
                            }
                            .padding(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sceneListHeight = $0 }
            }
            // 列表按内容高收紧（否则 ScrollView 贪高），放不下才让它滚。
            .frame(height: min(max(sceneListHeight, 1), max(available.height - sceneChromeHeight, 160)))
            .scrollIndicators(.never)

            Spacer(minLength: 14)
            VStack(spacing: 0) {
                Rectangle().fill(LightAnchorTheme.stageLineSoft).frame(height: 1)
                HStack(alignment: .firstTextBaseline) {
                    Button(tr("switch_scene_back")) { page = .front }
                        .buttonStyle(.plain)
                        .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.primary)
                    Spacer()
                    // 「全不带 / 全带上」已经进了卡头，页脚不再重复摆一遍。
                    Text(tr("switch_tap_to_strike"))
                        .font(LightAnchorTheme.supportingFont(size: 12.5))
                        .foregroundStyle(LightAnchorTheme.stageFaintInk)
                }
                .padding(.top, 14)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sceneFootHeight = $0 }
        }
        .padding(.horizontal, 34)
        .padding(.top, 30)
        .padding(.bottom, 20)
    }

    // MARK: - 小部件

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(LightAnchorTheme.supportingFont(size: 10.5, weight: .semibold))
            .kerning(1.7)
            .foregroundStyle(LightAnchorTheme.stageFaintInk)
    }

    // MARK: - 数据

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var currentEntry: (episode: AttentionEpisode, target: AttentionTarget)? {
        guard let episode = workspace.currentEpisode, episode.state != .ended,
              let target = workspace.snapshot.targets[episode.targetID] else { return nil }
        return (episode, target)
    }

    /// 手上这份现场的复写条：这段事复制过的文字，按专注区间分纸。
    private var currentStrips: [ClipboardStrip] {
        guard let episode = workspace.currentEpisode else { return [] }
        let entries = workspace.clipboardHistory(for: episode.id)
        guard !entries.isEmpty else { return [] }
        return ClipboardStrip.build(
            entries: entries,
            focusIntervals: workspace.focusIntervals(for: episode.id)
        )
    }

    private var trimmedCue: String { returnCue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isCreating: Bool {
        if let destination, case .create = destination { return true }
        return false
    }

    private var howEyebrow: String {
        switch how {
        case .pause: tr("switch_now_pause")
        case .wait: tr("switch_now_wait")
        case .done: tr("switch_now_done")
        }
    }

    private func currentMeta(_ entry: (episode: AttentionEpisode, target: AttentionTarget)) -> String {
        let focus = UserFacingCopy.focusDuration(workspace.snapshot.focusMinutes(of: entry.episode.id))
        let total = preview?.items.count ?? 0
        var parts = [focus]
        // 左半说的是「手上这件怎么收」，新开一件也不改它——新开就是空手开始，
        // 手上那份现场照常收好（设计里这一行与选了旧事时一字不差）。
        if total > 0 {
            parts.append(String(format: tr("switch_scene_kept"), total - struckCurrentItemIDs.count, struckCurrentItemIDs.count))
        }
        switch how {
        case .wait:
            let who = waitingFor.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(String(format: tr("switch_meta_waiting_on"), who.isEmpty ? "……" : who))
        case .done: parts.append(tr("switch_meta_stretch_ends"))
        case .pause: break
        }
        return parts.joined(separator: " · ")
    }

    private var currentEntryTitle: String {
        let total = preview?.items.count ?? 0
        return String(format: tr("switch_scene_count"), total - struckCurrentItemIDs.count)
    }

    private var reopenEntryTitle: String {
        String(format: tr("switch_reopen_count"), reopeningCount)
    }

    private var destinationTarget: AttentionTarget? {
        guard let destination, case .target(let id) = destination else { return nil }
        return workspace.snapshot.targets[id]
    }

    private var destinationEpisode: AttentionEpisode? {
        destinationTarget.flatMap { workspace.unfinishedEpisode(for: $0.id) }
    }

    private var destinationSnapshot: SceneSnapshot? {
        destinationTarget.flatMap { workspace.snapshot.latestSceneSnapshot(for: $0.id) }
    }

    private var reopeningCount: Int {
        guard let snapshot = destinationSnapshot else { return 0 }
        return snapshot.restorableItems.count - struckDestinationItemIDs.count
    }

    /// 结果到了的那条等待（若目的地正是它）。
    private var readyWaiting: WaitingItem? {
        guard let episode = destinationEpisode else { return nil }
        return workspace.snapshot.readyWaitingItems.first { $0.episodeID == episode.id }
    }

    /// 还没等到的那条：目的地这件事是不是仍卡在别人手里。看的是等待本身，
    /// 不是那段工作此刻的状态——「等待中」已经不是一种状态了。
    private var outstandingWaiting: WaitingItem? {
        guard let episode = destinationEpisode else { return nil }
        return workspace.snapshot.waitingItems.values
            .filter { $0.episodeID == episode.id && $0.status == .waiting }
            .min { $0.startedAt < $1.startedAt }
    }

    private var destinationVerb: String? {
        guard let destination else { return nil }
        switch destination {
        case .create: return tr("switch_verb_new")
        case .capture: return tr("switch_verb_from_later")
        case .target:
            if destinationEpisode?.state == .returning || readyWaiting != nil {
                return tr("switch_verb_return")
            }
            return outstandingWaiting != nil ? tr("switch_verb_return") : tr("switch_verb_resume")
        }
    }

    private var destinationEyebrow: String {
        guard let verb = destinationVerb else { return tr("switch_to") }
        return String(format: tr("switch_to_verb"), verb)
    }

    private var destinationName: String {
        guard let destination else { return tr("switch_not_chosen") }
        switch destination {
        case .target: return destinationTarget?.name ?? ""
        case .capture(let id): return workspace.snapshot.captures[id].map(Self.captureTitle) ?? ""
        case .create(let name): return name.isEmpty ? tr("switch_name_it") : name
        }
    }

    private var destinationNameIsPlaceholder: Bool {
        if let destination, case .create(let name) = destination { return name.isEmpty }
        return false
    }

    /// 票面第三行：恢复几样 / 新的一件从零开始。
    private var destinationMeta: String {
        guard let destination else { return "" }
        switch destination {
        case .create:
            return tr("switch_new_from_empty")
        case .capture:
            return tr("switch_no_scene_yet")
        case .target:
            var parts: [String] = []
            if destinationSnapshot != nil {
                parts.append(String(format: tr("switch_restore_count"), reopeningCount))
            } else {
                parts.append(tr("switch_no_scene_yet"))
            }
            if let waiting = readyWaiting {
                parts.append(String(format: tr("switch_ready_meta"), waiting.description))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// 票面第三行里要标绿的那截（「已开着」）。
    private var destinationMetaHighlight: String? {
        guard let snapshot = destinationSnapshot else { return nil }
        let running = snapshot.restorableItems.first {
            $0.kind == .application && Self.isRunning(bundleID: $0.address)
        }
        guard let running else { return nil }
        return String(format: tr("switch_meta_already_open"), running.title)
    }

    private var destinationCue: String? {
        guard !isCreating, let cue = destinationEpisode?.returnCue, !cue.isEmpty else { return nil }
        return "「" + cue + "」"
    }

    /// 第三句的尾巴：新开一件时设计里写的是「，现场从零开始。」——和票面第三行同一句话。
    private var destinationTail: String {
        isCreating ? tr("switch_tail_from_zero") : tr("switch_period")
    }

    private var primaryTitle: String {
        guard let destination else { return tr("switch_primary_pick_left") }
        switch destination {
        case .create: return tr("switch_primary_start_new")
        case .capture: return tr("switch_primary_start_capture")
        case .target:
            return destinationSnapshot == nil
                ? tr("switch_primary_go_plain")
                : String(format: tr("switch_primary_go"), reopeningCount)
        }
    }

    private static func captureTitle(_ capture: CaptureItem) -> String {
        capture.body.isEmpty ? (capture.title ?? tr("saved_items")) : capture.body
    }

    private static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// 图注写的是**采集这份现场的时刻**（和上面「几点记录」同一个时间），
    /// 不是截图文件的修改时间——备份还原过一次文件时间就不准了。
    private func photoCaption(at date: Date) -> String {
        String(format: tr("switch_photo_caption"), Self.clock.string(from: date))
    }

    // MARK: - 候选清单（左栏）

    private var candidateRows: [SwitchWorkPickerRow] {
        let snapshot = workspace.snapshot
        let currentTargetID = workspace.currentEpisode?.targetID
        let needle = trimmedQuery
        func matches(_ text: String) -> Bool {
            needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
        }
        var rows: [SwitchWorkPickerRow] = []

        // 结果到了
        var readyTargetIDs = Set<UUID>()
        var section: [SwitchWorkPickerRow] = []
        for waiting in snapshot.readyWaitingItems {
            guard let episode = snapshot.episodes[waiting.episodeID], episode.state != .ended,
                  episode.targetID != currentTargetID,
                  let target = snapshot.targets[episode.targetID],
                  readyTargetIDs.insert(target.id).inserted,
                  matches(target.name) else { continue }
            section.append(SwitchWorkPickerRow(
                destination: .target(target.id), dot: .ready, title: target.name,
                subtitle: waiting.description,
                trailing: UserFacingCopy.relativeAge(of: waiting.completedAt ?? waiting.startedAt),
                trailingEmphasis: true
            ))
        }
        if !section.isEmpty { rows.append(.header(tr("switch_group_ready"))); rows += section }

        // 等待中：看的是「有没有一条还没等到的 waiting」，不是那段工作此刻的状态——
        // 被别的事挤下去之后 episode 会变成「放下」，可 CI 还在跑，这件事仍然在等。
        // 先算出来，好让「放下的」把它们让开。
        var waitingRows: [SwitchWorkPickerRow] = []
        var waitingTargetIDs = Set<UUID>()
        for waiting in snapshot.waitingItems.values.sorted(by: { $0.startedAt > $1.startedAt })
        where waiting.status == .waiting {
            guard let episode = snapshot.episodes[waiting.episodeID], episode.state != .ended,
                  episode.targetID != currentTargetID,
                  !readyTargetIDs.contains(episode.targetID),
                  let target = snapshot.targets[episode.targetID],
                  waitingTargetIDs.insert(target.id).inserted,
                  matches(target.name) else { continue }
            waitingRows.append(SwitchWorkPickerRow(
                destination: .target(target.id), dot: .wait, title: target.name,
                subtitle: waiting.description,
                trailing: UserFacingCopy.waitedAge(of: waiting.startedAt)
            ))
        }

        // 放下的
        section = []
        for episode in snapshot.setAsideEpisodes
        where episode.targetID != currentTargetID && !readyTargetIDs.contains(episode.targetID)
            && !waitingTargetIDs.contains(episode.targetID) {
            guard let target = snapshot.targets[episode.targetID], matches(target.name) else { continue }
            section.append(SwitchWorkPickerRow(
                destination: .target(target.id), dot: .pause, title: target.name,
                subtitle: episode.returnCue, trailing: UserFacingCopy.relativeAge(of: episode.updatedAt)
            ))
        }
        if !section.isEmpty { rows.append(.header(tr("switch_group_set_aside"))); rows += section }

        if !waitingRows.isEmpty { rows.append(.header(tr("switch_group_waiting"))); rows += waitingRows }

        // 步骤：大任务拆出来、一段还没开始的小步骤（动过的自然住在
        // 结果到了/放下的/等待中）。副题写它属于哪件大事。
        section = []
        for step in snapshot.plannedSteps
        where step.id != currentTargetID && matches(step.name) {
            guard let parent = step.parentTargetID.flatMap({ snapshot.targets[$0] }) else { continue }
            section.append(SwitchWorkPickerRow(
                destination: .target(step.id), dot: .idle, title: step.name,
                subtitle: String(format: tr("step_of_parent"), parent.name),
                trailing: UserFacingCopy.relativeAge(of: step.createdAt)
            ))
        }
        if !section.isEmpty { rows.append(.header(tr("switch_group_steps"))); rows += section }

        // 稍后
        section = []
        for capture in snapshot.inbox where matches(Self.captureTitle(capture)) {
            section.append(SwitchWorkPickerRow(
                destination: .capture(capture.id), dot: .idle, title: Self.captureTitle(capture),
                subtitle: capture.tags.map { "#" + $0 }.joined(separator: " "),
                trailing: UserFacingCopy.relativeAge(of: capture.capturedAt)
            ))
        }
        if !section.isEmpty { rows.append(.header(tr("switch_group_later"))); rows += section }

        // 新开「…」：打了字就出现（没有同名时）。设计里它是清单末尾**光秃秃的一行**，
        // 不带分组头——打字时其余组都空了，再加个组头只是多一行字。
        if !needle.isEmpty,
           !snapshot.targets.values.contains(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) {
            rows.append(SwitchWorkPickerRow(
                destination: .create(needle), dot: .new,
                title: String(format: tr("switch_new_row"), needle),
                subtitle: tr("switch_new_row_sub"), trailing: "⌘↵", isNew: true, newName: needle
            ))
        }
        return rows
    }

    private var selectableRows: [SwitchWorkPickerRow] { candidateRows.filter { !$0.isHeader } }

    /// 没打字时左栏最多列这么多条，其余折成一行「还有 N 件 · 打字找」。
    private static let sidebarRestingLimit = 9

    private var indexedSidebarRows: [(row: SwitchWorkPickerRow, index: Int?)] {
        var next = 0
        var result: [(row: SwitchWorkPickerRow, index: Int?)] = []
        for row in candidateRows {
            if row.isHeader { result.append((row, nil)); continue }
            if trimmedQuery.isEmpty, next >= Self.sidebarRestingLimit { continue }
            result.append((row, next)); next += 1
        }
        // 折掉的组会剩一个空表头：去掉它。
        return result.enumerated().filter { offset, entry in
            !entry.row.isHeader || (offset + 1 < result.count && !result[offset + 1].row.isHeader)
        }.map(\.element)
    }

    private var hiddenSidebarCount: Int {
        guard trimmedQuery.isEmpty else { return 0 }
        return max(0, selectableRows.count - Self.sidebarRestingLimit)
    }

    /// 打字即选：有命中就选第一条命中，没有就实时变成「新开「…」」，清空回到未选。
    private func liveSelect(for text: String) {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = selectableRows
        if needle.isEmpty {
            destination = nil
            struckDestinationItemIDs = []
            highlightedRow = nil
            return
        }
        if let index = rows.firstIndex(where: { if case .create = $0.destination { false } else { true } }) {
            destination = rows[index].destination
            struckDestinationItemIDs = defaultStruckDestinationItems()
            highlightedRow = index
        } else if let index = rows.firstIndex(where: { $0.isNew }) {
            destination = .create(needle)
            highlightedRow = index
        }
    }

    /// 换目的地时，那份现场里 AI 判过无关的条目默认就是划掉的——设计里那一行是
    /// 删除线加「不开」，不是等用户自己再点一遍。（AI 筛选开着时这些条目本就不在
    /// `restorableItems` 里，这份默认只在「全部保存」下起作用。）
    private func defaultStruckDestinationItems() -> Set<UUID> {
        guard let snapshot = destinationSnapshot else { return [] }
        return Set(snapshot.restorableItems.filter { !$0.isRelevant }.map(\.id))
    }

    private func choose(_ row: SwitchWorkPickerRow) {
        guard let picked = row.destination else { return }
        // 再点同一条 = 取消（设计：点同一条取消，回到未选）。
        if destination == picked {
            destination = nil
            highlightedRow = nil
            page = .front
            return
        }
        destination = picked
        struckDestinationItemIDs = defaultStruckDestinationItems()
        showingHowPicker = false
        highlightedRow = selectableRows.firstIndex { $0.destination == picked }
        page = .front
        focusedField = nil
        cardFocused = true
    }

    // MARK: - 键盘

    private func handleEscape() -> KeyPress.Result {
        if page != .front { page = .front; return .handled }
        if showingHowPicker { showingHowPicker = false; return .handled }
        if !trimmedQuery.isEmpty { query = ""; return .handled }
        onDismiss()
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        if page != .front { page = .front; return .handled }
        guard destination != nil else {
            focusedField = .search
            return .handled
        }
        confirm()
        return .handled
    }

    /// ⌘↵ = 新开「打的那串字」（设计里新开行右侧的 ⌘↵）。
    private func handleCommandReturn() -> KeyPress.Result {
        guard page == .front else { return .ignored }
        let needle = trimmedQuery
        guard !needle.isEmpty,
              let row = selectableRows.first(where: \.isNew) else { return handleReturn() }
        choose(row)
        return .handled
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        guard page == .front else { return .ignored }
        let rows = selectableRows
        guard !rows.isEmpty else { return .handled }
        let current = highlightedRow
            ?? rows.firstIndex(where: { $0.destination == destination })
            ?? (offset > 0 ? -1 : rows.count)
        let next = (current + offset + rows.count) % rows.count
        highlightedRow = next
        // 设计：↑↓ 即改选，句子和邮票立刻跟着变。
        if let picked = rows[next].destination {
            destination = picked
            struckDestinationItemIDs = defaultStruckDestinationItems()
            }
        AccessibilityNotification.Announcement(rows[next].title).post()
        return .handled
    }

    // MARK: - 换过去

    private func confirm() {
        guard let destination else { return }
        let cue = trimmedCue
        let items = preview?.items ?? []
        var switched = false

        workspace.performQuietSwitch {
            if currentEntry != nil {
                let kept: ContextCapsule? = preview.map { preview in
                    let struck = items.filter { struckCurrentItemIDs.contains($0.id) }
                    return preview.context.removing(struck)
                }
                let mode: AttentionWorkspace.SetAsideMode = switch how {
                case .pause: .pause
                case .wait: .wait(waitingFor)
                case .done: .done
                }
                _ = workspace.setAsideCurrent(mode, keeping: kept, returnCue: cue)
            }

            switch destination {
            case .target(let targetID):
                if let waiting = readyWaiting {
                    _ = workspace.resumeWaitingEpisode(waiting.id)
                }
                guard workspace.startEpisode(targetID: targetID) != nil else { return }
                switched = true
                if let snapshot = destinationSnapshot {
                    let kept = Set(snapshot.restorableItems.map(\.id)).subtracting(struckDestinationItemIDs)
                    if !kept.isEmpty {
                        _ = workspace.restoreScene(snapshot.id, selectedItemIDs: kept)
                    }
                }
            case .capture(let captureID):
                switched = workspace.createTargetFromCapture(captureID) != nil
            case .create(let name):
                // 不在这儿建了：凭空立一件事要交代的东西（期限、开工要开什么）
                // 这个面板问不了——它的右区是给「交接」用的，新事没有现场可交接。
                // 名字带走，交给「开始一件事」那张便笺。
                guard !name.isEmpty else { return }
                onCreateNew(name)
                return
            }
        }

        guard switched else { return }
        onSwitched()
    }
}

// MARK: - 模型

enum SwitchWorkPage: Equatable {
    case front, currentScene, destinationScene
}

enum SwitchDestination: Equatable {
    case target(UUID)
    case capture(UUID)
    case create(String)
}

private enum HowKind: Equatable, CaseIterable {
    case pause, wait, done

    var title: String {
        switch self {
        case .pause: tr("switch_how_pause")
        case .wait: tr("switch_how_wait")
        case .done: tr("switch_how_done")
        }
    }

    var subtitle: String {
        switch self {
        case .pause: ""
        case .wait: tr("switch_how_wait_sub")
        case .done: tr("switch_how_done_sub")
        }
    }

    var dotForm: SwitchWorkDotForm {
        switch self {
        case .pause: .pause
        case .wait: .wait
        case .done: .done
        }
    }
}

/// 浮层锚点：哪个空被点开了，浮层就贴在它下面。
struct SwitchWorkAnchorKey: PreferenceKey {
    enum Kind: Hashable { case how }
    static let defaultValue: [Kind: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Kind: Anchor<CGRect>], nextValue: () -> [Kind: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 设计里那几种点（.d）：7px 圆；放下空心 1.5、等待半填、做完绿、结果到了带光环、
/// 稍后 5px 淡点、新开淡空心。
enum SwitchWorkDotForm: Equatable {
    case active, pause, wait, done, ready, idle, new

    init(_ state: AttentionEpisodeState) {
        switch state {
        case .active: self = .active
        case .paused: self = .pause
        case .returning: self = .ready
        case .ended: self = .done
        }
    }
}

struct SwitchWorkDot: View {
    let form: SwitchWorkDotForm
    var size: CGFloat = 7

    init(_ form: SwitchWorkDotForm, size: CGFloat = 7) {
        self.form = form
        self.size = size
    }

    var body: some View {
        ZStack {
            switch form {
            case .active:
                Circle().fill(LightAnchorTheme.primary)
            case .pause:
                Circle().strokeBorder(LightAnchorTheme.primary, lineWidth: 1.5)
            case .wait:
                Circle().strokeBorder(LightAnchorTheme.primary, lineWidth: 1.5)
                Circle().fill(LightAnchorTheme.primary)
                    .mask(alignment: .leading) { Rectangle().frame(width: size / 2) }
            case .done:
                Circle().fill(LightAnchorTheme.success)
            case .ready:
                // 光环是 ZStack 里唯一定死尺寸的孩子（13pt）：蓝芯不锁 7pt 的话，
                // ZStack 会把它撑到和光环一样大——渲染成一颗 13pt 的实心大蓝点。
                Circle().fill(LightAnchorTheme.stageWash).frame(width: size + 6, height: size + 6)
                Circle().fill(LightAnchorTheme.primary).frame(width: size, height: size)
            case .idle:
                Circle().fill(LightAnchorTheme.stageFaintInk).frame(width: size * 0.72, height: size * 0.72)
            case .new:
                Circle().strokeBorder(LightAnchorTheme.stageFaintInk, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 两块：一块中性白（现在），一块浅蓝（要去的地方）

/// 左边「现在」和右边目的地是**同一种块**，只是温度不同：一块中性白、一块浅蓝。
/// 邮票整套已取消——齿孔、面值、蓝内框、复写条撕边全部去掉。
///
/// 两块的内边距、圆角、最小高度都相同，外面用等高的网格拉伸，所以不管右边
/// 有没有留话，白卡和蓝块永远顶底对齐。
struct SwitchWorkBlock<Content: View>: View {
    enum Tone {
        /// 手上这件：中性白卡。
        case now
        /// 要去的地方：浅蓝方块。
        case destination
        /// 还没选：透明 + 虚线边（空位的通用语言）。
        case blank
    }

    let tone: Tone
    /// 外面钉进来的高度：两块永远等高，谁的内容高就都用那个高。
    var height: CGFloat?
    /// 把内容的自然高度报出去（不含内边距），供外面算等高。
    var onContentHeight: ((CGFloat) -> Void)?
    @ViewBuilder let content: () -> Content

    /// 内边距（上 14 / 下 13）：算等高时要把它加回去。
    static var verticalPadding: CGFloat { 27 }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                onContentHeight?(measured)
            }
            .padding(EdgeInsets(top: 14, leading: 17, bottom: 13, trailing: 17))
            .frame(height: height, alignment: .topLeading)
            .frame(minHeight: 122, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(stroke, style: strokeStyle)
            }
            .shadow(
                color: .black.opacity(tone == .now ? 0.04 : 0),
                radius: 1,
                y: 1
            )
    }

    private var fill: LightAnchorThemeColor {
        switch tone {
        case .now: LightAnchorTheme.surface
        case .destination: LightAnchorTheme.stageWash
        case .blank: LightAnchorThemeColor.clear
        }
    }

    private var stroke: LightAnchorThemeColor {
        switch tone {
        case .now: LightAnchorTheme.stageLine
        // 浅蓝块的边就是那层水洗蓝加深一档（深色下它自己会变浅，不写死颜色）。
        case .destination: LightAnchorTheme.stageAccentSoft.opacity(0.5)
        case .blank: LightAnchorTheme.stageLine
        }
    }

    private var strokeStyle: StrokeStyle {
        tone == .blank
            ? StrokeStyle(lineWidth: 1, dash: [5, 4])
            : StrokeStyle(lineWidth: 1)
    }
}

// MARK: - 方向：一根安静的细线箭头

/// 定稿：静态 20px 细线箭头。点线 + 跑动蓝点两版都被否——这里不做任何动画。
struct SwitchWorkArrow: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 10))
            path.addLine(to: CGPoint(x: 15, y: 10))
            path.move(to: CGPoint(x: 10, y: 5))
            path.addLine(to: CGPoint(x: 15, y: 10))
            path.addLine(to: CGPoint(x: 10, y: 15))
        }
        .stroke(
            LightAnchorTheme.stageFaintInk,
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: - 左栏的一行

/// 设计 .sb .o：40 高、11 圆角、点 + 名 14/600 + 小字 11.5 + 右侧时间；
/// 悬停 row-hover，选中 wash + 1px 内描边。
private struct SwitchWorkSidebarRow: View {
    let row: SwitchWorkPickerRow
    let highlight: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    private var titleText: Text {
        if row.isNew, let range = row.title.range(of: row.newName) {
            return Text(String(row.title[..<range.lowerBound]))
                + Text(row.newName)
                    .font(LightAnchorTheme.interfaceFont(size: 14, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                + Text(String(row.title[range.upperBound...]))
        }
        if !highlight.isEmpty, let range = row.title.range(of: highlight, options: .caseInsensitive) {
            return Text(String(row.title[..<range.lowerBound]))
                + Text(String(row.title[range])).foregroundStyle(LightAnchorTheme.primary)
                + Text(String(row.title[range.upperBound...]))
        }
        return Text(row.title)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let dot = row.dot { SwitchWorkDot(dot, size: 7) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                        .font(LightAnchorTheme.interfaceFont(size: 14, weight: row.isNew ? .medium : .semibold))
                        .foregroundStyle(row.isNew ? LightAnchorTheme.stageMutedInk : LightAnchorTheme.ink)
                        .layoutPriority(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.stageMutedInk)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if !row.trailing.isEmpty {
                    Text(row.trailing)
                        .font(LightAnchorTheme.supportingFont(size: 11.5, weight: row.trailingEmphasis ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(row.trailingEmphasis ? LightAnchorTheme.success : LightAnchorTheme.stageFaintInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LightAnchorTheme.stageWash)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LightAnchorTheme.stageRowHover)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(LightAnchorTheme.primary.opacity(0.32), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 浮层外壳（设计 .pop）：白底、发丝边、14px 圆角、纸投影、内边距 6。
private struct SwitchWorkPopoverChrome<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(6)
            .frame(width: width)
            .background(LightAnchorTheme.stagePanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LightAnchorTheme.stageLine, lineWidth: 1)
            }
            .lightAnchorStagePanelShadow()
    }
}

struct SwitchWorkPickerRow: Identifiable, Equatable {
    let id = UUID()
    var destination: SwitchDestination?
    var dot: SwitchWorkDotForm?
    var title: String
    var subtitle = ""
    var trailing = ""
    var trailingEmphasis = false
    var isNew = false
    var newName = ""
    var isHeader: Bool { destination == nil }

    static func header(_ title: String) -> SwitchWorkPickerRow {
        SwitchWorkPickerRow(destination: nil, dot: nil, title: title)
    }
}

/// 浮层里的一行（设计 .pop .o）。
private struct SwitchWorkPopoverRow: View {
    let dot: SwitchWorkDotForm?
    let title: String
    let subtitle: String
    let trailing: String
    let trailingEmphasis: Bool
    let isNew: Bool
    let highlighted: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let dot { SwitchWorkDot(dot, size: 7) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(LightAnchorTheme.interfaceFont(size: 14, weight: isNew ? .medium : .semibold))
                        .foregroundStyle(isNew ? LightAnchorTheme.stageMutedInk : LightAnchorTheme.ink)
                        .layoutPriority(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(LightAnchorTheme.supportingFont(size: 12))
                            .foregroundStyle(LightAnchorTheme.stageMutedInk)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(LightAnchorTheme.supportingFont(size: 12, weight: trailingEmphasis ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(trailingEmphasis ? LightAnchorTheme.success : LightAnchorTheme.stageFaintInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LightAnchorTheme.stageWash)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LightAnchorTheme.stageRowHover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 现场行的应用图标：取**真**应用图标（比自画的色块有辨识度）。
/// - 应用条目用 bundleID 找 app
/// - 文件条目直接取文件图标（本身就带应用色彩）
/// - 其余按来源应用名在运行中的应用里找，再退到 /Applications 同名
/// - 都找不到才退到按类别的 SF Symbol
struct SwitchWorkAppIcon: View {
    let item: SceneItem
    var size: CGFloat = 21

    var body: some View {
        Group {
            if let image = Self.icon(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(LightAnchorTheme.stageRowHover)
                    .overlay {
                        LightAnchorIcon(Self.symbol(for: item.kind), size: size * 0.58)
                            .foregroundStyle(LightAnchorTheme.stageMutedInk)
                    }
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private static func symbol(for kind: SceneItemKind) -> String {
        switch kind {
        case .file: "doc"
        case .link: "globe"
        case .terminal: "terminal"
        case .application: "app"
        }
    }

    /// 图标解析结果缓存：现场页会反复重绘，NSWorkspace 查询不该每帧走一遍。
    private static let cache = IconCache()

    private final class IconCache: @unchecked Sendable {
        private var storage: [String: NSImage?] = [:]
        private let lock = NSLock()

        func value(for key: String, make: () -> NSImage?) -> NSImage? {
            lock.lock()
            if let hit = storage[key] { lock.unlock(); return hit }
            lock.unlock()
            let made = make()
            lock.lock()
            storage[key] = made
            lock.unlock()
            return made
        }
    }

    static func icon(for item: SceneItem) -> NSImage? {
        let key = "\(item.kind.rawValue)|\(item.address)|\(item.sourceApplication)"
        return cache.value(for: key) { resolve(item) }
    }

    private static func resolve(_ item: SceneItem) -> NSImage? {
        switch item.kind {
        case .application:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.address) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        case .file:
            if let url = URL(string: item.address), url.isFileURL,
               FileManager.default.fileExists(atPath: url.path) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        case .terminal:
            break
        case .link:
            break
        }
        return iconForApplicationNamed(item.sourceApplication)
    }

    /// 按应用名找图标：先在运行中的应用里找（现场里的来源大多还开着），再试 /Applications。
    static func iconForApplicationNamed(_ name: String) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }), let url = running.bundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let path = directory + "/" + trimmed + ".app"
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }
}

/// 「现场 5 样 ›」入口（设计 .link）：悬停转蓝、chevron 右移 2px。
private struct SwitchWorkSceneLink: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(hovered ? LightAnchorTheme.primary : LightAnchorTheme.stageMutedInk)
                Text(verbatim: "›")
                    .font(LightAnchorTheme.interfaceFont(size: 13))
                    .foregroundStyle(hovered ? LightAnchorTheme.primary : LightAnchorTheme.stageFaintInk)
                    .offset(x: hovered ? 2 : 0, y: -1)
            }
            .font(LightAnchorTheme.supportingFont(size: 13, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// MARK: - 排版小件

/// 点线 / 实线（空的下划线、目录引导点）。
struct SwitchWorkDottedRule: View {
    var solid: Bool
    var color: LightAnchorThemeColor

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(color, style: solid
                ? StrokeStyle(lineWidth: 1)
                : StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
        }
    }
}

/// 细 chevron（代替「▼」）。
private struct SwitchWorkCaret: View {
    var color: LightAnchorThemeColor

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 4.5, y: 4.5))
            path.addLine(to: CGPoint(x: 9, y: 0))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .frame(width: 9, height: 5)
        .padding(.bottom, 2)
    }
}

/// 空处的指引：一个等你落笔的插入点（设计：1.1s 一个周期的阶跃闪烁）。
private struct SwitchWorkCaretCursor: View {
    let animated: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2
            Rectangle()
                .fill(LightAnchorTheme.primary)
                .frame(width: 1.5, height: 16)
                .opacity(!animated || phase == 0 ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// 现场页页首右角的截图缩略图：真有截图才出现（正放、不斜、不加任何戳）。
private struct SwitchWorkPhoto: View {
    let url: URL
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(LightAnchorTheme.stageSidebar)
                        .overlay {
                            Text(tr("switch_photo_label"))
                                .font(LightAnchorTheme.supportingFont(size: 10.5))
                                .foregroundStyle(LightAnchorTheme.stageFaintInk)
                        }
                }
            }
            .frame(width: 168, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LightAnchorTheme.stageLine, lineWidth: 1)
            }
            .lightAnchorPaperEdgeShadow(radius: 3, y: 1)
            Text(caption)
                .font(LightAnchorTheme.supportingFont(size: 10))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.stageFaintInk)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .frame(width: 168)
        .accessibilityLabel(tr("switch_photo_label"))
    }
}
