import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct MainWorkspaceView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeController: LightAnchorThemeController
    @SceneStorage("workspace.destination") private var destinationRawValue = WorkspaceDestination.now.rawValue
    @SceneStorage("workspace.laterScope") private var laterScopeRawValue = LaterScope.inbox.rawValue
    @SceneStorage("workspace.showInspector") private var inspectorSceneValue = false
    @State private var selectedDestination: WorkspaceDestination? = .now
    @State private var showingStartWork = false
    /// 「更多设置…」带过去的名字：浮层里敲了一半就不该让用户再打一遍。
    @State private var startWorkInitialName = ""
    /// 「换一件事」浮层：开始/切换到某件事的唯一入口（⌘K）。
    @State private var showingSwitchWork = false
    /// 等待编辑器按打开瞬间的 episode 钉住（.sheet(item:)）：
    /// isPresented + if-let 在条件落空时会呈现一张空 sheet，把主窗压暗。
    @State private var waitingEditorContext: WaitingEditorContext?
    @State private var showingInspector = false
    @State private var workspaceSearchText = ""
    @State private var showingWorkspaceSearch = false
    @State private var selectedSearchResult: WorkspaceSearchResult?
    @State private var searchSelectionIndex = 0
    /// 重返现场面板（.sheet(item:)）：快照本体就是开关，不再另设布尔。
    @State private var sceneReturnSnapshot: SceneSnapshot?
    @State private var sceneReturnWaitingID: UUID?
    @State private var showingAllRecents = false
    /// 「现在」页中心区域正在回顾的目标（点最近的事/搜索结果进入）。
    @State private var reviewingTargetID: UUID?
    @FocusState private var workspaceSearchFieldFocused: Bool
    @Namespace private var sidebarDotNamespace
    /// 「收进蓝点」：侧栏沉入呼吸蓝点，当前任务显示在窗顶红绿灯旁（重启保持）。
    @AppStorage("workspace.sidebarAnchored") private var sidebarAnchored = false
    @State private var hoveringAnchorPlate = false

    private var activeDestination: WorkspaceDestination {
        selectedDestination ?? WorkspaceDestination(rawValue: destinationRawValue) ?? .now
    }

    /// 「已放下」确认弹窗的开关：暂时放下、换一件事都会弹（放下的事
    /// 不再占「现在」页）；等待结果不弹——那件事还在现在页，现场卡
    /// 原地说「已保存」。关掉即视为用户已确认。
    private var recentSetAsideSheetItem: Binding<AttentionWorkspace.RecentSetAside?> {
        Binding(
            get: {
                guard let aside = workspace.recentSetAside,
                      aside.targetID != workspace.currentEpisode?.targetID
                else { return nil }
                return aside
            },
            set: { value in
                if value == nil { workspace.dismissRecentSetAside() }
            }
        )
    }

    /// 弹簧蓝点滑动（样机 .side-dot：transform .5s cubic-bezier(.3,1.7,.4,1)）。
    private var sideDotAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.3, 1.7, 0.4, 1, duration: 0.5)
    }

    /// 现场舱推拉（样机 .dock：margin .45s cubic-bezier(.3,1.3,.4,1)）。
    /// reduceMotion = 全静态（nil，瞬时），不是快进——位移动画正是前庭敏感用户要关的。
    private var dockAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.3, 1.3, 0.4, 1, duration: 0.45)
    }

    /// 侧栏收展与舞台镶边的推拉曲线：干净的 ease-out、不回弹——
    /// 宽度收拢式的动画回弹会变成负宽度/挤压岛，观感是抖。
    private var anchorAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.3, 1, 0.4, 1, duration: 0.38)
    }

    /// 收进蓝点 / 放出侧栏的唯一入口——三个触发点（⌃⌘S、岛工具行的钮、
    /// 窗顶铭牌）都走这里。侧栏走经典 macOS 分栏收拢（宽度归零、内容随
    /// 右缘滑出被裁掉），与现场舱的推拉是两种性格，各自干净。
    private func setSidebarAnchored(_ anchored: Bool) {
        guard anchored != sidebarAnchored else { return }
        withAnimation(anchorAnimation) { sidebarAnchored = anchored }
    }

    private func toggleSidebarAnchored() {
        setSidebarAnchored(!sidebarAnchored)
    }

    /// 当前可展示在蓝点铭牌/侧栏底部的进行中工作。
    private var currentAnchorEntry: (episode: AttentionEpisode, target: AttentionTarget)? {
        guard let episode = workspace.currentEpisode,
              let target = workspace.snapshot.targets[episode.targetID] else { return nil }
        return (episode, target)
    }

    /// 样机 .win：固定 226pt 宽侧栏 + 内容舞台的双栏。不用
    /// NavigationSplitView——它自带的分栏线和拖拽柄样机里都没有。
    /// 「收进蓝点」= 经典 macOS 分栏收拢：侧栏宽度收到 0，内容钉在
    /// 右缘随收拢滑出、被裁掉。侧栏是常驻成员而不是条件成员——
    /// 成员进出的 transition 在现场舱开着时会被布局吞掉（收展直接瞬变），
    /// 常驻 + 宽度动画在任何组合下都稳定。alignment .top：默认的垂直
    /// 居中会因内容岛的负上边距把侧栏往下挤出一截空白。
    private var workspaceShell: some View {
        HStack(alignment: .top, spacing: 0) {
            workspaceSidebar
                .frame(width: LightAnchorDesign.sidebarWidth, alignment: .leading)
                .frame(
                    width: sidebarAnchored ? 0 : LightAnchorDesign.sidebarWidth,
                    alignment: .trailing
                )
                .clipped()
                // 动画必须钉在值上，不能只靠 setSidebarAnchored 的 withAnimation：
                // 现场舱开着时那个环境事务到不了这棵子树（帧拍实证：关舱收展有
                // 中间帧，开舱 237→11 瞬变）。按值驱动在任何组合下都稳定。
                .animation(anchorAnimation, value: sidebarAnchored)
                .allowsHitTesting(!sidebarAnchored)
                .accessibilityHidden(sidebarAnchored)
            workspaceDetail
        }
        .overlay(alignment: .topLeading) { anchorStripControls }
        // 悬浮动作组（新建定时 / 录制过程）：工具类动作不占侧栏，
        // 右下角收着，点开展开；录制中带红点指示，任何页面都可见。
        .overlay(alignment: .bottomTrailing) {
            WorkspaceToolCluster()
                .environmentObject(workspace)
                .padding(.trailing, 18)
                .padding(.bottom, 18)
        }
        // 要求 2「无灰条」：标题栏区域的工具栏/材质底一律隐掉，
        // 暖米白直通窗顶；标题文字也不要（样机窗顶没有任何文字）。
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .windowToolbar)
        // topLeading 而不是 top：万一哪页内容超宽，溢出只向右越界，
        // 不会把整窗内容（连侧栏一起）水平居中挤偏。
        .frame(
            minWidth: 980,
            maxWidth: .infinity,
            minHeight: 640,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(LightAnchorTheme.sidebarBackground)
        .background(LightAnchorWindowConfigurator(chrome: .workspace))
        .foregroundStyle(LightAnchorTheme.ink)
        .tint(LightAnchorThemePalette(theme: themeController.resolvedTheme).color(for: .primary))
    }

    var body: some View {
        // 每分钟一跳的重渲染：让「已持续 X 分钟」「X 分钟前」这类文字
        // 自己走起来——否则只有数据变动才会刷新，盯着看数字是冻住的。
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            workspaceShell
        }
        .onAppear {
            #if DEBUG
            // 调试后门：LIGHTANCHOR_DEBUG_START_PAGE 覆盖启动页（截图/验收用）。
            if let debugPage = ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_START_PAGE"],
               let destination = WorkspaceDestination(rawValue: debugPage) {
                destinationRawValue = destination.rawValue
            }
            // 调试后门：LIGHTANCHOR_DEBUG_ANCHORED=1/0 覆盖「收进蓝点」状态。
            if let anchored = ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_ANCHORED"] {
                sidebarAnchored = anchored == "1"
            }
            #endif
            #if DEBUG
            switch ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_OPEN"] {
            case "capture": openCaptureWindow()
            case "search": showingWorkspaceSearch = true
            case "settings": openWindow(id: "settings")
            case "inspector": inspectorSceneValue = true
            case "menubar": openMenuBarPreviewPanel()
            case "waiting-editor": showWaitingEditor()
            case "switch": showingSwitchWork = true
            // 「已放下」确认弹窗：放下当前这件、用它已有的现场快照亮出弹窗。
            case "set-aside":
                if let episode = workspace.currentEpisode {
                    workspace.debugAnnounceSetAside(of: episode.id)
                }
            default: break
            }
            #endif
            selectedDestination = WorkspaceDestination(rawValue: destinationRawValue) ?? .now
            showingInspector = inspectorSceneValue
            // 开窗能力交给常驻接线员：全局快捷键和 Dock 点击可能在窗口全关之后
            // 才到达，那时这个视图已经不在了。
            AppEventCoordinator.shared.adopt(openWindow: openWindow)
            workspace.runBackgroundMaintenance()
        }
        // ⌘1–⌘6 直达六个目的地（V7 键盘优先）。
        .background {
            ForEach(Array(WorkspaceDestination.allCases.enumerated()), id: \.element) { index, destination in
                Button(destination.title) {
                    withAnimation(sideDotAnimation) {
                        selectedDestination = destination
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                .hidden()
            }
            Button(tr("switch_to_something_else"), action: toggleSwitchWork)
                .keyboardShortcut("k", modifiers: [.command])
                .hidden()
        }
        .onChange(of: selectedDestination) { _, newValue in
            guard let newValue else { return }
            destinationRawValue = newValue.rawValue
            if selectedSearchResult?.destination != newValue {
                selectedSearchResult = nil
            }
            if selectedSearchResult == nil && newValue != .now {
                showingInspector = false
            }
            if newValue == .later {
                laterScopeRawValue = LaterScope(rawValue: laterScopeRawValue)?.rawValue ?? LaterScope.inbox.rawValue
            }
        }
        .onChange(of: showingInspector) { _, value in
            inspectorSceneValue = value
        }
        .sheet(isPresented: $showingStartWork) {
            StartWorkView(initialName: startWorkInitialName)
                .environmentObject(workspace)
        }
        .sheet(isPresented: $showingSwitchWork) {
            SwitchWorkSheet(
                onSwitched: {
                    showingSwitchWork = false
                    // 换过去之后要看到的是那件事本身，不是刚才的回顾页。
                    reviewingTargetID = nil
                    selectedSearchResult = nil
                    withAnimation(sideDotAnimation) {
                        selectedDestination = .now
                    }
                },
                onNewWorkDetails: { name in
                    showingSwitchWork = false
                    startWorkInitialName = name
                    showingStartWork = true
                }
            )
            .environmentObject(workspace)
        }
        // 「已放下」确认弹窗：暂时放下 / 换一件事、现场存好后弹出——这段
        // 专注了多久、保存了什么摆在眼前，趁记忆还热写下「回来先看」，
        // 条目可逐条剔除。等待结果不弹（那件事还在现在页，现场卡原地说已保存）。
        .sheet(item: recentSetAsideSheetItem) { info in
            RecentSetAsideSheet(info: info)
                .environmentObject(workspace)
        }
        .sheet(item: $waitingEditorContext) { context in
            WaitingEditorView(episodeID: context.id)
                .environmentObject(workspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lightAnchorToggleSidebar)) { _ in
            toggleSidebarAnchored()
        }
        .sheet(item: $sceneReturnSnapshot) { snapshot in
            SceneReturnPanel(
                snapshot: snapshot,
                waitingID: sceneReturnWaitingID,
                onRestore: { closeSceneReturn() },
                onCancel: { closeSceneReturn() }
            )
            .environmentObject(workspace)
        }
        .alert(
            tr("save_failed"),
            isPresented: Binding(
                get: { workspace.lastError != nil },
                set: { if !$0 { workspace.clearError() } }
            )
        ) {
            Button(UserFacingCopy.done) { workspace.clearError() }
        } message: {
            Text(workspace.lastError ?? "")
        }
        .alert(
            tr("needs_attention"),
            isPresented: Binding(
                get: { workspace.lastNotice != nil },
                set: { if !$0 { workspace.clearNotice() } }
            )
        ) {
            Button(UserFacingCopy.done) { workspace.clearNotice() }
        } message: {
            Text(workspace.lastNotice ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            workspace.runBackgroundMaintenance()
        }
    }

    private var workspaceSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 样机 .snav：六行连排（gap 2），组间不画分隔线。
            sidebarGroup(title: tr("attention"), destinations: attentionDestinations)
                .padding(.bottom, 2)
            sidebarGroup(title: tr("workbench"), destinations: toolDestinations)

            sidebarRecentSection

            Spacer(minLength: 12)

            sidebarStatusFooter
        }
        // 样机 .side：padding 16 14 14。
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(LightAnchorThemePalette(theme: themeController.resolvedTheme).color(for: .primary))
        .accentColor(LightAnchorThemePalette(theme: themeController.resolvedTheme).color(for: .primary))
        .background(LightAnchorTheme.sidebarBackground)
    }

    @ViewBuilder
    private func sidebarGroup(
        title: String,
        destinations: [WorkspaceDestination]
    ) -> some View {
        // 组名只服务旁白：视觉上按 V7 只用一条发丝线分隔两组。
        VStack(alignment: .leading, spacing: 2) {
            ForEach(destinations, id: \.self) { destination in
                workspaceNavigationRow(destination)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func workspaceNavigationRow(_ destination: WorkspaceDestination) -> some View {
        let isSelected = selectedDestination == destination
        return Button {
            // 直接点导航行 = 离开回顾，回到该页的常规内容。
            reviewingTargetID = nil
            withAnimation(sideDotAnimation) {
                selectedDestination = destination
            }
        } label: {
            HStack(spacing: 10) {
                // 样机 .srow svg：17pt 自绘几何图标，选中转正文墨色。
                LightAnchorDestinationIcon(destination: destination, size: 17)
                    .foregroundStyle(isSelected ? LightAnchorTheme.ink : LightAnchorTheme.mutedInk)
                    .frame(width: 20)

                Text(destination.title)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 8)

                sidebarTrailingAccessory(for: destination)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // 样机 .srow:hover：悬停软填充，选中药丸压在其上。
        .lightAnchorHoverFill(cornerRadius: LightAnchorDesign.radiusRow, isActive: !isSelected)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                    .fill(LightAnchorTheme.sidebarSelection)
            }
        }
        // 弹簧蓝点：选中行左缘的识别点，随选择在行间滑动。
        .overlay(alignment: .leading) {
            if isSelected {
                Circle()
                    .fill(LightAnchorTheme.primary)
                    .frame(width: 5, height: 5)
                    .offset(x: -8)
                    .matchedGeometryEffect(id: "sidebar-dot", in: sidebarDotNamespace)
            }
        }
    }

    @ViewBuilder
    private func sidebarTrailingAccessory(for destination: WorkspaceDestination) -> some View {
        if let count = count(for: destination), count > 0 {
            if destination == .waiting {
                // 等待计数用暖黄徽章（黄历「待」的语感）。
                Text(String(format: count == 1 ? tr("items_one") : tr("items"), count))
                    .font(LightAnchorTheme.labelFont(size: 10, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.warning)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        LightAnchorTheme.warningBackground.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            } else {
                Text("\(count)")
                    .font(LightAnchorTheme.interfaceFont(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.accentInk)
            }
        }
    }

    /// 「最近的事」（样机 .ssec + .srecent）：发丝线上标签，行式列表——
    /// 左标题右灰色时间，点击切到该件事（现场舱同步展示）；
    /// 「展开更多」就地展开完整列表，再点收起。
    @ViewBuilder
    private var sidebarRecentSection: some View {
        let allRecents = recentSidebarEntries
        let recents = showingAllRecents ? allRecents : Array(allRecents.prefix(4))
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("recent_work"))
                    .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(LightAnchorTheme.sidebarHairline)
                            .frame(height: 1)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    ForEach(recents, id: \.target.id) { entry in
                        sidebarRecentRow(entry)
                    }
                    if allRecents.count > 4 {
                        Button(showingAllRecents ? tr("tuck_away") : tr("show_more")) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                showingAllRecents.toggle()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(LightAnchorTheme.interfaceFont(size: 12.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .lightAnchorHoverFill(cornerRadius: 9)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func sidebarRecentRow(
        _ entry: (target: AttentionTarget, episode: AttentionEpisode)
    ) -> some View {
        Button {
            if entry.episode.id == workspace.currentEpisode?.id {
                // 当前这件事：直接回到「现在」的工作卡。
                selectedSearchResult = nil
                reviewingTargetID = nil
            } else {
                // 过去的事：中心区域打开这件事的回顾。
                selectedSearchResult = WorkspaceSearchResult(
                    stableID: "recent-\(entry.target.id.uuidString)",
                    kind: .target,
                    title: entry.target.name,
                    subtitle: UserFacingCopy.waitingState(entry.episode.state),
                    destination: .now,
                    dot: entry.episode.state == .active ? .active : .ended,
                    targetID: entry.target.id
                )
                reviewingTargetID = entry.target.id
            }
            withAnimation(sideDotAnimation) {
                selectedDestination = .now
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.target.name)
                    .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(recentMeta(for: entry.episode))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(WorkspaceSearchRowButtonStyle())
        .accessibilityLabel("\(entry.target.name)，\(recentMeta(for: entry.episode))")
    }

    /// 最近的事：按最后活动时间排序，同一目标只留最新一段。
    /// 默认露出 4 件，「展开更多」后最多 12 件。
    private var recentSidebarEntries: [(target: AttentionTarget, episode: AttentionEpisode)] {
        // 自动等待的中枢目标（Agent 会话/终端命令）不是「你最近做的事」，
        // 它们的动静已经在等待页和菜单栏里了。
        let hubTargetIDs: Set<UUID> = [AutoWaitHub.agentTargetID, AutoWaitHub.terminalTargetID]
        var newestByTarget: [UUID: AttentionEpisode] = [:]
        for episode in workspace.snapshot.episodes.values
        where !hubTargetIDs.contains(episode.targetID) {
            let stamp = episode.endedAt ?? episode.startedAt
            if let existing = newestByTarget[episode.targetID],
               (existing.endedAt ?? existing.startedAt) >= stamp {
                continue
            }
            newestByTarget[episode.targetID] = episode
        }
        return newestByTarget.values
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            .prefix(12)
            .compactMap { episode in
                guard let target = workspace.snapshot.targets[episode.targetID] else { return nil }
                return (target: target, episode: episode)
            }
    }

    /// 样机右列时间：进行中 / 放下多久 / 正在等待 / X 分钟 / 昨天 / X 天。
    /// 没结束的事必须一眼看出是「放下的」——只报相对时间的话，放下的事
    /// 和做完的事在列表里长得一模一样，也就没法当切换器用。
    private func recentMeta(for episode: AttentionEpisode) -> String {
        if episode.id == workspace.currentEpisode?.id,
           episode.state == .active || episode.state == .returning {
            return tr("in_progress")
        }
        if episode.state == .waiting {
            return tr("waiting_2")
        }
        if episode.state == .paused {
            return UserFacingCopy.setAsideAge(of: episode.updatedAt)
        }
        let reference = episode.endedAt ?? episode.startedAt
        let minutes = max(0, Int(Date().timeIntervalSince(reference) / 60))
        if minutes < 1 { return tr("just_now") }
        if minutes < 60 { return String(format: tr("min"), minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: tr("h"), hours) }
        let days = hours / 24
        return days == 1 ? tr("yesterday_plain") : String(format: tr("d_2"), days)
    }

    /// 侧栏底部常驻当前状态：呼吸点 + 任务名 + 已持续时长。
    /// 呼吸点铭牌与侧栏底各画各的——原「飞行交接」被否：用户不要蓝点
    /// 横穿窗口，且座位交接的无动画事务曾把整个展开动画一并吞掉。
    @ViewBuilder
    private var sidebarStatusFooter: some View {
        if let entry = currentAnchorEntry {
            let episode = entry.episode
            let target = entry.target
            Button {
                withAnimation(sideDotAnimation) {
                    selectedDestination = .now
                }
            } label: {
                HStack(spacing: 9) {
                    anchorStatusDot
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.name)
                            .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.ink)
                            .lineLimit(1)
                        Text(episodeDurationLabel(for: episode))
                            .font(LightAnchorTheme.supportingFont(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.faintInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: tr("current_work"), target.name))
        }
    }

    private func episodeDurationLabel(for episode: AttentionEpisode) -> String {
        // 专注时长：暂停、等待期间时钟停下，不再报墙钟时间。
        String(format: tr("focused_for"), UserFacingCopy.focusDuration(workspace.snapshot.focusMinutes(of: episode.id)))
    }

    // MARK: - 收进蓝点（窗顶呼吸带）

    /// 呼吸带控件：只有收起态的蓝点铭牌（展开态的收起钮住在岛工具行最左，
    /// 常驻显示——窗顶保持样机的「空无一物」）。
    @ViewBuilder
    private var anchorStripControls: some View {
        if sidebarAnchored {
            anchorPlate
                // 限宽让超长任务名在铭牌里截断，而不是横贯呼吸带。
                .frame(maxWidth: 460, maxHeight: 30, alignment: .leading)
                .padding(.leading, LightAnchorDesign.anchorPlateLeading)
                // 抵掉 28pt 标题栏安全区，再对齐红绿灯的垂直中心（窗顶下 22pt）。
                .offset(y: LightAnchorDesign.anchorStripControlOffsetY)
        }
    }

    /// 蓝点铭牌：收起后窗顶仅存的东西——呼吸点 + 当前任务名 + 已专注时长。
    /// 点击即退潮展开；随侧栏收起小幅延迟淡入，不与推拉动画抢戏。
    private var anchorPlate: some View {
        Button {
            setSidebarAnchored(false)
        } label: {
            // 点位 20 宽自带 6pt 空气，间距给 0，文字正好落在样机的 x=98。
            HStack(spacing: 0) {
                anchorStatusDot
                if let entry = currentAnchorEntry {
                    Text(entry.target.name)
                        .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .semibold))
                        .foregroundStyle(LightAnchorTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("· \(episodeDurationLabel(for: entry.episode))")
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 7)
                } else {
                    Text(tr("nothing_in_progress"))
                        .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .lineLimit(1)
                        .fixedSize()
                }

                // 样机 .anchor svg：悬停铭牌时浮现的「‹」，暗示点它就退潮展开。
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .opacity(hoveringAnchorPlate ? 0.9 : 0)
                    .padding(.leading, 5)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 3)
            .padding(.trailing, 11)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveringAnchorPlate = $0 }
        .animation(.easeOut(duration: 0.15), value: hoveringAnchorPlate)
        .lightAnchorHoverFill(cornerRadius: 8)
        .help(tr("expand_sidebar_s"))
        .accessibilityLabel(tr("expand_sidebar"))
        .accessibilityValue(
            currentAnchorEntry.map {
                "\($0.target.name)，\(episodeDurationLabel(for: $0.episode))"
            } ?? tr("nothing_in_progress")
        )
        .transition(.asymmetric(
            insertion: .opacity.animation(
                reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.22).delay(0.15)
            ),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        ))
    }

    /// 呼吸蓝点：铭牌与侧栏底各画各的，20×20 点位与图标列对齐。
    private var anchorStatusDot: some View {
        Group {
            if let entry = currentAnchorEntry {
                LightAnchorStatusDot(entry.episode.state, size: 8)
            } else {
                // 无进行中的事：静息灰点压阵。
                LightAnchorStatusDot(LightAnchorStatusDotForm.ended, size: 8)
            }
        }
        .frame(width: 20, height: 20)
        .allowsHitTesting(false)
    }

    /// 两边都收起（侧栏收进蓝点、现场舱关闭）时岛铺满整窗：舞台底转岛色、
    /// 发丝描边和四周留缝一并退场——只剩一块内容面，不再有「岛浮在底上」的边缘区分。
    private var stageChromeHidden: Bool {
        sidebarAnchored && !showingInspector
    }

    private var workspaceDetail: some View {
        ZStack(alignment: .top) {
            // 舞台底与侧栏同色，内容住在浅一档的奶油白圆角岛上（V7 内容岛）。
            Rectangle()
                .fill(
                    stageChromeHidden
                        ? LightAnchorTheme.windowBackground
                        : LightAnchorTheme.sidebarBackground
                )
                .animation(anchorAnimation, value: stageChromeHidden)
            HStack(spacing: 10) {
                VStack(spacing: 0) {
                    // 工具行住在内容岛里（样机 .toolbar：48 高、靠右三键），
                    // 不用原生标题栏工具栏。
                    // 对话页自带贴顶的标题行（含侧栏开关），不再叠一条全局工具行。
                    if activeDestination != .chat {
                        islandToolbar
                    }
                    stageContent
                        .id(activeDestination)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(
                    LightAnchorTheme.windowBackground,
                    in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                        .strokeBorder(
                            LightAnchorTheme.sidebarHairline.opacity(stageChromeHidden ? 0 : 1),
                            lineWidth: 1
                        )
                }

                // 现场舱（样机 .dock）：内容岛旁的第二座圆角岛，推拉进出。
                if showingInspector {
                    WorkspaceContextRail(
                        selectedDestination: activeDestination,
                        searchResult: selectedSearchResult,
                        onClose: {
                            withAnimation(dockAnimation) { showingInspector = false }
                        }
                    )
                    .environmentObject(workspace)
                    .frame(width: 258)
                    .frame(maxHeight: .infinity)
                    .background(
                        LightAnchorTheme.windowBackground,
                        in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                            .strokeBorder(LightAnchorTheme.sidebarHairline, lineWidth: 1)
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                }
            }
            // 样机：内容岛四周留 10 的缝，直通窗顶（不给隐藏标题栏留安全区）。
            // 收进蓝点时岛漫到左缘，顶部让出米白呼吸带给红绿灯和蓝点铭牌；
            // 两边都收起时缝也归零，岛直接铺满整窗。
            .padding([.horizontal, .bottom], stageChromeHidden ? 0 : 10)
            .padding(.top, sidebarAnchored ? LightAnchorDesign.anchorStripHeight : 10)
            .animation(anchorAnimation, value: stageChromeHidden)
            // 顶边距跟的是 sidebarAnchored 本身：现场舱开着时 stageChromeHidden
            // 不变，只钉上一个键会让呼吸带高度瞬跳（与侧栏帧同一个教训）。
            .animation(anchorAnimation, value: sidebarAnchored)
        }
        // 样机：内容岛顶缝 10pt。不能用 ignoresSafeArea——它和
        // NavigationSplitView 的安全区管理互相触发，布局每帧重跑
        // 直到主线程被吃满；负上边距把内容拉进标题栏区即可
        // （抵掉 28pt 的标题栏安全区，顶缝由上面的 padding(.top, 10) 给出）。
        .padding(.top, -28)
        // 覆盖式滚动条在这块画布上只会刷存在感：岛每次改宽（收展侧栏、
        // 开合现场舱、拉伸窗口）AppKit 都要闪它几下；「藏一阵再交还」也不行
        // ——重新挂载的那一刻又主动闪一次。无边框的安静画布干脆不要指示器，
        // 滚动本身不受影响。
        .scrollIndicators(.never)
        .overlay {
            if showingWorkspaceSearch {
                workspaceSearchOverlay
            }
        }
    }

    /// 打开「换一件事」：应用的标准 sheet（和开始一件事/等待编辑器同族）。
    private func openSwitchWork() {
        showingSwitchWork = true
    }

    private func closeSwitchWork() {
        showingSwitchWork = false
    }

    private func toggleSwitchWork() {
        showingSwitchWork.toggle()
    }

    /// 内容岛工具行（样机 .toolbar）：48 高——最左是常驻的侧栏收起/展开钮
    /// （macOS 原生位置，不搞悬停才显示），靠右三键：捕获 + / 搜索 / 现场舱。
    /// 不用原生标题栏工具栏。
    private var islandToolbar: some View {
        HStack(spacing: 2) {
            Button {
                toggleSidebarAnchored()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(LightAnchorToolbarIconButtonStyle())
            .help(sidebarAnchored ? tr("expand_sidebar_s") : tr("tuck_into_the_dot_s"))
            .accessibilityLabel(sidebarAnchored ? tr("expand_sidebar") : tr("collapse_sidebar"))

            Spacer(minLength: 0)

            // 对话页整条工具行都不出现（用户定），这里无需再按页隐藏。
            // + 直接开捕获窗（沿用上次去向，去向在捕获窗里改）——
            // 原来的「记到稍后 / 存进暂存箱」下拉被否：多一步选择才见到输入框。
            Button(action: openCaptureWindow) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(LightAnchorToolbarIconButtonStyle())
            .help(tr("capture_a_thought_n"))
            .accessibilityLabel(UserFacingCopy.capture)
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    showingWorkspaceSearch.toggle()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(LightAnchorToolbarIconButtonStyle(isSelected: showingWorkspaceSearch))
            .help(showingWorkspaceSearch ? tr("close_search_f") : tr("search_f"))
            .accessibilityLabel(tr("search_workspace"))
            .accessibilityValue(showingWorkspaceSearch ? tr("search_state_open") : tr("search_state_closed"))
            .keyboardShortcut("f", modifiers: [.command])

            Button {
                withAnimation(dockAnimation) {
                    showingInspector.toggle()
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(LightAnchorToolbarIconButtonStyle(isSelected: showingInspector))
            .help(tr("scene_capsule"))
            .accessibilityLabel(tr("scene_capsule"))
            .accessibilityValue(showingInspector ? tr("state_shown") : tr("state_hidden"))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch activeDestination {
        case .now:
            if let reviewingTargetID,
               workspace.snapshot.targets[reviewingTargetID] != nil,
               reviewingTargetID != workspace.currentEpisode?.targetID {
                TargetReviewView(
                    targetID: reviewingTargetID,
                    onResume: {
                        _ = workspace.startEpisode(targetID: reviewingTargetID)
                        self.reviewingTargetID = nil
                        selectedSearchResult = nil
                    },
                    onClose: {
                        self.reviewingTargetID = nil
                        selectedSearchResult = nil
                    }
                )
                .environmentObject(workspace)
            } else {
                nowSpace
            }
        case .later:
            LaterSpaceView(
                scope: laterScopeBinding,
                selectedResult: selectedSearchResult,
                onCapture: openCaptureWindow,
                onSwitch: { targetID in
                    _ = workspace.startEpisode(targetID: targetID)
                    withAnimation(sideDotAnimation) {
                        selectedDestination = .now
                    }
                }
            )
                .environmentObject(workspace)
        case .waiting:
            WaitingSpaceView(
                onRestore: restoreWaitingContext,
                onCreateWaiting: showWaitingEditor,
                selectedResult: selectedSearchResult
            )
                .environmentObject(workspace)
        case .environments:
            EnvironmentProfilesView().environmentObject(workspace)
        case .review:
            ReviewView { targetID in
                reviewingTargetID = targetID
                selectedSearchResult = nil
                selectedDestination = .now
                destinationRawValue = WorkspaceDestination.now.rawValue
            }
            .environmentObject(workspace)
        case .chat:
            MemoryChatView()
                .environmentObject(workspace)
        }
    }

    private var nowSpace: some View {
        NowSpaceView(
            // 有没有当前工作走的是同一个面板：空状态时它是「开始一件事」，
            // 有当前工作时它是「换一件事」。
            onStart: openSwitchWork,
            onSwitch: openSwitchWork,
            onCapture: openCaptureWindow,
            onWait: showWaitingEditor,
            onRestore: restoreCurrentContext,
            onOpenDestination: { destination in
                withAnimation(sideDotAnimation) {
                    selectedDestination = destination
                }
            }
        )
        .environmentObject(workspace)
    }

    private func count(for destination: WorkspaceDestination) -> Int? {
        switch destination {
        case .now:
            return workspace.currentEpisode == nil ? nil : 1
        case .later:
            return workspace.snapshot.inbox.count + workspace.snapshot.setAsideEpisodes.count
        case .waiting:
            return workspace.snapshot.activeWaitingItems.count
        case .environments, .review, .chat:
            return nil
        }
    }

    private var workspaceDestinations: [WorkspaceDestination] {
        WorkspaceDestination.allCases
    }

    private var attentionDestinations: [WorkspaceDestination] {
        workspaceDestinations.filter(\.isAttention)
    }

    private var toolDestinations: [WorkspaceDestination] {
        workspaceDestinations.filter { !$0.isAttention }
    }

    private var laterScopeBinding: Binding<LaterScope> {
        Binding(
            get: { LaterScope(rawValue: laterScopeRawValue) ?? .inbox },
            set: { laterScopeRawValue = $0.rawValue }
        )
    }

    private var workspaceSearchResultsModel: [WorkspaceSearchResult] {
        let query = workspaceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        typealias Field = WorkspaceSearchScoring.Field
        let now = Date()
        var scored: [(result: WorkspaceSearchResult, score: Double)] = []

        let currentEpisode = workspace.currentEpisode
        if let intent = WorkspaceHistoryQueryIntent.infer(from: query) {
            let interval = DateInterval(
                start: now.addingTimeInterval(-30 * 24 * 3600),
                end: now.addingTimeInterval(1)
            )
            for (index, trace) in workspace.recentWorkTraces(in: interval, now: now)
                .prefix(8).enumerated() {
                let scene = trace.sceneSnapshot
                let matchingItem: SceneItem? = switch intent {
                case .recent: nil
                case .document: scene?.restorableItems.first(where: { $0.kind == .file })
                case .webpage: scene?.restorableItems.first(where: { $0.kind == .link })
                case .terminal: scene?.restorableItems.first(where: { $0.kind == .terminal })
                }
                if intent != .recent, matchingItem == nil { continue }
                let title = matchingItem?.title ?? trace.targetTitle
                let kind = scene == nil ? WorkspaceSearchResult.Kind.target : .scene
                scored.append((WorkspaceSearchResult(
                    stableID: scene.map { "scene-\($0.id.uuidString)" }
                        ?? "target-\(trace.targetID.uuidString)",
                    kind: kind,
                    title: title,
                    subtitle: String(
                        format: tr("search_subtitle_recent_trace"),
                        trace.summary,
                        UserFacingCopy.relativeAge(of: trace.lastActivityAt)
                    ),
                    destination: .now,
                    dot: trace.state == .active || trace.state == .returning ? .active : .ended,
                    targetID: trace.targetID,
                    sceneSnapshotID: scene?.id
                ), 40 - Double(index)))
            }
        }

        for target in workspace.snapshot.targets.values {
            guard let score = WorkspaceSearchScoring.score(
                query: query,
                fields: [
                    Field(target.name, weight: WorkspaceSearchScoring.titleWeight),
                    Field(target.note, weight: WorkspaceSearchScoring.bodyWeight)
                ],
                recency: target.updatedAt,
                now: now
            ) else { continue }
            let isCurrent = currentEpisode?.targetID == target.id
            scored.append((WorkspaceSearchResult(
                stableID: "target-\(target.id.uuidString)",
                kind: .target,
                title: target.name,
                subtitle: String(
                    format: tr("search_subtitle_target"),
                    UserFacingCopy.relativeAge(of: target.updatedAt)
                ),
                destination: .now,
                dot: isCurrent ? .active : .ended,
                targetID: target.id
            ), score))
        }

        // 捕获：收件箱、资料和归档都可检索——标题、正文、标签，以及截图 OCR 出的文字。
        for capture in workspace.snapshot.captures.values
        where capture.status == .inbox || capture.status == .reference || capture.status == .archived {
            guard let score = WorkspaceSearchScoring.score(
                query: query,
                fields: [
                    Field(capture.title ?? "", weight: WorkspaceSearchScoring.titleWeight),
                    Field(capture.body, weight: WorkspaceSearchScoring.bodyWeight),
                    Field(capture.tags.joined(separator: " "), weight: WorkspaceSearchScoring.tagWeight),
                    Field(capture.extractedText, weight: WorkspaceSearchScoring.extractedWeight),
                    Field(capture.sourceURL?.absoluteString ?? "", weight: WorkspaceSearchScoring.extractedWeight)
                ],
                recency: capture.capturedAt,
                now: now
            ) else { continue }
            let scopeLabel: String? = switch capture.status {
            case .reference: tr("reference")
            case .archived: tr("archive")
            default: nil
            }
            let title = capture.body.isEmpty ? (capture.title ?? tr("saved_items")) : capture.body
            var subtitleParts = [
                scopeLabel ?? UserFacingCopy.captureKind(capture.kind),
                UserFacingCopy.relativeAge(of: capture.capturedAt)
            ]
            // 命中的是截图里的文字时给一眼线索。
            if !capture.extractedText.isEmpty,
               capture.extractedText.lowercased().contains(query.lowercased()),
               !title.lowercased().contains(query.lowercased()) {
                subtitleParts.append(tr("screenshot_text_match"))
            }
            let resultScope: LaterScope = switch capture.status {
            case .reference: .references
            case .archived: .archived
            default: .inbox
            }
            scored.append((WorkspaceSearchResult(
                stableID: "capture-\(capture.id.uuidString)",
                kind: .capture,
                title: title,
                subtitle: subtitleParts.joined(separator: " · "),
                destination: .later,
                laterScope: resultScope
            ), score))
        }

        for item in workspace.snapshot.activeWaitingItems {
            guard let score = WorkspaceSearchScoring.score(
                query: query,
                fields: [
                    Field(item.description, weight: WorkspaceSearchScoring.titleWeight),
                    Field(item.evidence, weight: WorkspaceSearchScoring.bodyWeight)
                ],
                recency: item.completedAt ?? item.startedAt,
                now: now
            ) else { continue }
            let isReady = item.status == .ready
            scored.append((WorkspaceSearchResult(
                stableID: "waiting-\(item.id.uuidString)",
                kind: .waiting,
                title: item.description,
                subtitle: "\(isReady ? tr("ready_to_return") : tr("set_aside")) · \(UserFacingCopy.relativeAge(of: item.startedAt))",
                destination: .waiting,
                dot: isReady ? .ready : .waiting
            ), score))
        }

        // 历史现场：文件名、网页标题/地址、终端命令、应用和「回来先做」。
        for scene in workspace.snapshot.sceneSnapshots.values {
            guard let match = WorkspaceSceneSearch.match(query: query, scene: scene, now: now)
            else { continue }
            let target = scene.targetID.flatMap { workspace.snapshot.targets[$0] }
            let isCurrent = scene.targetID == currentEpisode?.targetID
            let targetPart = target?.name ?? tr("no_linked_target")
            scored.append((WorkspaceSearchResult(
                stableID: "scene-\(scene.id.uuidString)",
                kind: .scene,
                title: match.title,
                subtitle: String(
                    format: tr("search_subtitle_scene"),
                    match.matchKind,
                    targetPart,
                    UserFacingCopy.relativeAge(of: scene.capturedAt)
                ),
                destination: .now,
                dot: isCurrent ? .active : .ended,
                targetID: scene.targetID,
                sceneSnapshotID: scene.id
            ), match.score))
        }

        var seenResultIDs = Set<String>()
        return scored
            .sorted { $0.score > $1.score }
            .filter { seenResultIDs.insert($0.result.id).inserted }
            .prefix(18)
            .map(\.result)
    }

    /// 搜索居中浮层（V7）：压暗背景 + 白色浮板，结果按目的地分组，
    /// 点击沿用 routeSearchResult（跳转目的地并高亮 + 打开现场舱）。
    private var workspaceSearchOverlay: some View {
        ZStack {
            Rectangle()
                .fill(LightAnchorTheme.ink.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeWorkspaceSearch() }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.faintInk)

                    TextField(tr("search_or_ask_what_was_i"), text: $workspaceSearchText)
                        .textFieldStyle(.plain)
                        .font(LightAnchorTheme.interfaceFont(size: 15))
                        .focused($workspaceSearchFieldFocused)
                        .onKeyPress(.downArrow) {
                            moveSearchSelection(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSearchSelection(by: -1)
                            return .handled
                        }
                        .onSubmit {
                            let results = flatSearchResults
                            guard !results.isEmpty else { return }
                            routeSearchResult(results[min(searchSelectionIndex, results.count - 1)])
                        }
                        .onChange(of: workspaceSearchText) {
                            searchSelectionIndex = 0
                        }

                    if !workspaceSearchText.isEmpty {
                        Button {
                            workspaceSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .accessibilityLabel(tr("clear_search"))
                    }

                    Text("esc")
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

                Rectangle()
                    .fill(LightAnchorTheme.hairlineBorder)
                    .frame(height: 1)

                workspaceSearchResults

                HStack(spacing: 14) {
                    searchFootHint(key: "↑↓", label: tr("choose"))
                    searchFootHint(key: "↩", label: tr("go_and_highlight"))
                    searchFootHint(key: "esc", label: tr("close"))
                    Spacer()
                    if !workspaceSearchText.isEmpty {
                        Text(String(
                            format: workspaceSearchResultsModel.count == 1
                                ? tr("results_one") : tr("results"),
                            workspaceSearchResultsModel.count
                        ))
                            .font(LightAnchorTheme.supportingFont(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(LightAnchorTheme.windowBackground)
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
            .onExitCommand { closeWorkspaceSearch() }
            .onAppear { workspaceSearchFieldFocused = true }
            .onDisappear { workspaceSearchFieldFocused = false }
        }
    }

    private func searchFootHint(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(LightAnchorTheme.monoFont(size: 10, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
            Text(label)
                .font(LightAnchorTheme.supportingFont(size: 11))
                .foregroundStyle(LightAnchorTheme.faintInk)
        }
    }

    private func closeWorkspaceSearch() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            showingWorkspaceSearch = false
        }
        workspaceSearchText = ""
        searchSelectionIndex = 0
    }

    /// 结果按目的地分组：现在 → 稍后 → 等待。
    private var groupedSearchResults: [(destination: WorkspaceDestination, results: [WorkspaceSearchResult])] {
        let grouped = Dictionary(grouping: workspaceSearchResultsModel, by: \.destination)
        return [WorkspaceDestination.now, .later, .waiting].compactMap { destination in
            guard let results = grouped[destination], !results.isEmpty else { return nil }
            return (destination, results)
        }
    }

    /// 分组展开后的平铺顺序，↑↓ 键盘选择沿这个顺序移动。
    private var flatSearchResults: [WorkspaceSearchResult] {
        groupedSearchResults.flatMap(\.results)
    }

    private func moveSearchSelection(by offset: Int) {
        let count = flatSearchResults.count
        guard count > 0 else { return }
        searchSelectionIndex = (searchSelectionIndex + offset + count) % count
        // 焦点始终在输入框里，↑↓ 只改视觉高亮——旁白用户需要听到
        // 当前选中的是哪条，否则回车等于盲开。
        let current = flatSearchResults[searchSelectionIndex]
        AccessibilityNotification.Announcement("\(current.title)，\(current.subtitle)").post()
    }

    private var workspaceSearchResults: some View {
        Group {
            if workspaceSearchText.isEmpty {
                Text(tr("type_keywords_for_targets_past_scenes"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            } else if workspaceSearchResultsModel.isEmpty {
                Text(tr("no_matches"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let flat = flatSearchResults
                        ForEach(groupedSearchResults, id: \.destination) { group in
                            Text(group.destination.title)
                                .font(LightAnchorTheme.labelFont(size: 10.5, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(LightAnchorTheme.faintInk)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(group.results) { result in
                                searchResultRow(
                                    result,
                                    isSelected: flat.firstIndex(of: result) == searchSelectionIndex
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private func searchResultRow(_ result: WorkspaceSearchResult, isSelected: Bool) -> some View {
        Button {
            routeSearchResult(result)
        } label: {
            HStack(spacing: 10) {
                searchResultDot(result.dot)

                highlightedSearchTitle(result.title)
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(result.subtitle)
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    // 副标题带「N 分钟前」相对时间，浮层开着时每分钟真的会跳。
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
        .accessibilityValue(searchResultDotDescription(result.dot))
    }

    /// 行首状态点（样机 .srrow .sdot，7pt）：不用具象图标，只用蓝点几何形态。
    @ViewBuilder
    private func searchResultDot(_ dot: WorkspaceSearchResult.Dot) -> some View {
        Group {
            switch dot {
            case .active:
                // 进行中 = 实心 + 光环（呼吸光环的静止形）：不能只靠蓝/灰色相
                // 区分进行中与已结束，色弱用户分不出来；光环溢出绘制不占布局。
                Circle()
                    .fill(LightAnchorTheme.primary)
                    .background(
                        Circle()
                            .fill(LightAnchorTheme.primary.opacity(0.18))
                            .padding(-3)
                    )
            case .waiting:
                Circle()
                    .stroke(
                        LightAnchorTheme.warning,
                        style: StrokeStyle(lineWidth: 2, dash: [2.4, 2.4])
                    )
                    .padding(1)
            case .ready:
                Circle().fill(LightAnchorTheme.successBadge)
            case .ended:
                Circle().fill(LightAnchorTheme.faintInk)
            }
        }
        .frame(width: 7, height: 7)
    }

    /// 行首点形态的可及描述：旁白用户听得到状态，而不是只有一颗彩点。
    private func searchResultDotDescription(_ dot: WorkspaceSearchResult.Dot) -> String {
        switch dot {
        case .active: tr("in_progress")
        case .waiting: tr("waiting")
        case .ready: tr("ready_to_return")
        case .ended: tr("ended")
        }
    }

    /// 命中的关键词用文字蓝加粗（样机 .st mark）。
    private func highlightedSearchTitle(_ title: String) -> Text {
        let query = workspaceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(title) }
        var text = Text(verbatim: "")
        var remaining = title[...]
        while let range = remaining.range(of: query, options: .caseInsensitive) {
            text = text + Text(remaining[..<range.lowerBound])
            text = text
                + Text(remaining[range])
                .foregroundStyle(LightAnchorTheme.accentInk)
                .fontWeight(.semibold)
            remaining = remaining[range.upperBound...]
        }
        return text + Text(remaining)
    }

    private func routeSearchResult(_ result: WorkspaceSearchResult) {
        selectedSearchResult = result
        selectedDestination = result.destination
        destinationRawValue = result.destination.rawValue
        switch result.kind {
        case .capture:
            laterScopeRawValue = (result.laterScope ?? .inbox).rawValue
        case .target:
            // 过去的目标：中心区域打开回顾；当前目标回工作卡。
            if let targetID = result.targetID,
               targetID != workspace.currentEpisode?.targetID {
                reviewingTargetID = targetID
            } else {
                reviewingTargetID = nil
            }
        case .scene:
            if let targetID = result.targetID,
               targetID != workspace.currentEpisode?.targetID {
                reviewingTargetID = targetID
            }
            if let sceneID = result.sceneSnapshotID,
               let scene = workspace.snapshot.sceneSnapshots[sceneID] {
                sceneReturnWaitingID = nil
                sceneReturnSnapshot = scene
            }
        case .waiting:
            break
        }
        closeWorkspaceSearch()
        withAnimation(dockAnimation) {
            showingInspector = true
        }
    }

    private func restoreCurrentContext() {
        guard let episode = workspace.currentEpisode else { return }
        if let snapshot = workspace.snapshot.latestSceneSnapshot(for: episode.targetID),
           !snapshot.restorableItems.isEmpty
        {
            sceneReturnWaitingID = nil
            sceneReturnSnapshot = snapshot
        } else {
            restore(episode.context)
        }
    }

    private func restoreWaitingContext(_ waiting: WaitingItem) {
        guard let episode = workspace.snapshot.episodes[waiting.episodeID] else { return }
        if let snapshot = workspace.snapshot.latestSceneSnapshot(for: episode.targetID),
           !snapshot.restorableItems.isEmpty
        {
            sceneReturnWaitingID = waiting.id
            sceneReturnSnapshot = snapshot
        } else {
            guard workspace.resumeWaitingEpisode(waiting.id) else { return }
            restore(waiting.originalContext)
        }
    }

    private func closeSceneReturn() {
        sceneReturnSnapshot = nil
        sceneReturnWaitingID = nil
    }

    private func restore(_ context: ContextCapsule) {
        #if os(macOS)
        // AX 查询会阻塞（等窗口出现要轮询），所以恢复放后台跑；结果回主线程再报。
        // 原先是 DispatchQueue.main.async 里直接摸 @MainActor 的 workspace——
        // 那次递手编译器管不到，写成结构化并发才由它检查。
        Task { @MainActor in
            let report = await Task.detached(priority: .userInitiated) {
                MacContextRestorer().restore(context)
            }.value
            workspace.presentNotice(
                report.hasIssues ? UserFacingCopy.limitation(report.summary) : report.summary
            )
        }
        #endif
    }

    private func openCaptureWindow() {
        #if os(macOS)
        CaptureContextStore.shared.prepare()
        #endif
        openWindow(id: "capture")
    }

    #if os(macOS)
    /// 调试后门（截图/验收用）：菜单栏浮窗内容装进浮动面板——
    /// 真状态项可能被菜单栏溢出折叠，自动化点不到。
    private func openMenuBarPreviewPanel() {
        let hosting = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(workspace)
                .environmentObject(themeController)
                .lightAnchorTheme(themeController.resolvedTheme)
        )
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.title = tr("menu_bar_preview")
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.isOpaque = true
        panel.hasShadow = true
        panel.sharingType = .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.setFrameOrigin(NSPoint(x: 240, y: 420))
        panel.orderFrontRegardless()
    }
    #endif

    private func showWaitingEditor() {
        guard let episode = workspace.currentEpisode else {
            workspace.presentNotice(tr("start_something_first_then_you_can"))
            return
        }
        waitingEditorContext = WaitingEditorContext(id: episode.id)
    }
}

/// 等待编辑器 sheet 的 item 载体：UUID 自身不是 Identifiable。
private struct WaitingEditorContext: Identifiable {
    let id: UUID
}

/// 浮层里的一行，搜索浮层与「换一件事」浮层共用：键盘选中 = 主色水洗 +
/// 左缘定位边条（样机 .srrow.sel），悬停 = 米灰软填充（样机 .srrow:hover）。
struct WorkspaceSearchRowButtonStyle: ButtonStyle {
    var isSelected = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isSelected || configuration.isPressed
        configuration.label
            .background(
                highlighted
                    ? LightAnchorTheme.accentWash
                    : (isHovered ? LightAnchorTheme.recessed : LightAnchorThemeColor.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if highlighted {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(LightAnchorTheme.primary)
                        .frame(width: 2)
                        .padding(.vertical, 8)
                }
            }
            .onHover { isHovered = $0 }
    }
}

/// 现场舱（样机 .dock）：「现场」头 + 任务名 + 键值行 + 「回来先看」卡 +
/// 稍后/等待计数。宿主负责岛式外观（圆角 + 发丝描边）。
private struct WorkspaceContextRail: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let selectedDestination: WorkspaceDestination
    let searchResult: WorkspaceSearchResult?
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            if let searchResult {
                searchResultInspector(searchResult)
            } else if let episode = workspace.currentEpisode,
               let target = workspace.snapshot.targets[episode.targetID] {
                WorkDetailsView(target: target, episode: episode, onClose: onClose)
                    .environmentObject(workspace)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                contextSummary
            }
        }
        // 岛底由调用处的圆角背景负责；这里再铺一层方角背景会
        // 沿默认的安全区扩展涂进标题栏区，在岛顶多出一条色带。
    }

    private func searchResultInspector(_ result: WorkspaceSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            LightAnchorDockHead(tr("scene"))

            Text(result.title)
                .font(LightAnchorTheme.interfaceFont(size: 14.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                LightAnchorDockKeyValue(key: tr("location"), value: result.destination.title, accent: true)
                LightAnchorDockKeyValue(key: tr("details"), value: result.subtitle)
            }

            LightAnchorDockSeparator()

            countsSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var contextSummary: some View {
        VStack(alignment: .leading, spacing: 13) {
            LightAnchorDockHead(tr("scene"))

            Text(tr("not_started_yet"))
                .font(LightAnchorTheme.interfaceFont(size: 14.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
            Text(tr("when_you_re_ready_start_with"))
                .font(LightAnchorTheme.supportingFont(size: 12.5))
                .foregroundStyle(LightAnchorTheme.mutedInk)

            LightAnchorDockSeparator()

            countsSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var countsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LightAnchorDockKeyValue(key: tr("later"), value: "\(workspace.snapshot.inbox.count)")
            LightAnchorDockKeyValue(key: tr("waiting"), value: "\(workspace.snapshot.activeWaitingItems.count)")
        }
    }
}

/// 舱头（样机 .dk-head）。
struct LightAnchorDockHead: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(LightAnchorTheme.interfaceFont(size: 12, weight: .medium))
            .foregroundStyle(LightAnchorTheme.faintInk)
    }
}

/// 键值行（样机 .dock .kv div）：左灰键，右墨值（表格数字）。
struct LightAnchorDockKeyValue: View {
    let key: String
    let value: String
    var accent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(LightAnchorTheme.supportingFont(size: 12.5))
                .foregroundStyle(LightAnchorTheme.mutedInk)
            Spacer(minLength: 10)
            Text(value)
                .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accent ? LightAnchorTheme.accentInk : LightAnchorTheme.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 舱内发丝分隔（样机 .dock .sep）。
struct LightAnchorDockSeparator: View {
    var body: some View {
        Rectangle()
            .fill(LightAnchorTheme.hairlineBorder)
            .frame(height: 1)
    }
}

/// 「回来先看」提示卡（样机 .dock .cue）。
struct LightAnchorDockCueCard: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(LightAnchorTheme.interfaceFont(size: 11.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
            Text(text)
                .font(LightAnchorTheme.supportingFont(size: 12))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LightAnchorTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        )
    }
}

private struct NowSpaceView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let onStart: () -> Void
    let onSwitch: () -> Void
    let onCapture: () -> Void
    let onWait: () -> Void
    let onRestore: () -> Void
    let onOpenDestination: (WorkspaceDestination) -> Void

    var body: some View {
        // 居中舞台构图（样机 .herowrap/.empty：垂直水平双居中，
        // 底部留 24 让重心略高于几何中心）。
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let episode = workspace.currentEpisode,
                       let target = workspace.snapshot.targets[episode.targetID] {
                        currentWork(episode: episode, target: target)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 24))
                .padding(.bottom, 24)
            }
        }
    }


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

            workspaceStatChips
                .padding(.top, 24)
        }
        .frame(maxWidth: 620)
    }

    /// 稍后 / 等待 两枚统计胶囊（样机 .statchip：只有名称 + 蓝色计数）。
    private var workspaceStatChips: some View {
        HStack(spacing: 10) {
            workspaceStatChip(
                title: UserFacingCopy.later,
                value: workspace.snapshot.inbox.count,
                destination: .later
            )
            workspaceStatChip(
                title: UserFacingCopy.waiting,
                value: workspace.snapshot.activeWaitingItems.count,
                destination: .waiting
            )
        }
    }

    private func workspaceStatChip(
        title: String,
        value: Int,
        destination: WorkspaceDestination
    ) -> some View {
        Button {
            onOpenDestination(destination)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Text("\(value)")
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.accentInk)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(LightAnchorTheme.recessed, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(LightAnchorTheme.sidebarHairline, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // 样机 .statchip:hover。
        .lightAnchorHoverFill(cornerRadius: 999)
        .accessibilityLabel(String(format: value == 1 ? tr("items_2_one") : tr("items_2"), title, value))
    }

    private func currentWork(episode: AttentionEpisode, target: AttentionTarget) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                currentWorkHeader(episode: episode, target: target)

                SceneCardView(episode: episode, target: target, onRestore: onRestore)
                    .lightAnchorRecessed(radius: 12, padding: 13)

                if episode.state == .waiting {
                    // 回场简报（README「现在」页承诺的那份）：等待中回到这页，
                    // 先看到你在哪/发生了什么/先做什么，不必先点「恢复现场」。
                    ReturnBriefingCard(episodeID: episode.id)
                    LightAnchorLabel(
                        title: tr("this_one_is_waiting_on_a"),
                        icon: "hourglass",
                        spacing: 7
                    )
                        .font(LightAnchorTheme.bodyFont(size: 12.5))
                        .foregroundStyle(LightAnchorDesign.waiting)
                }

                cardSeparator

                currentWorkActions(episode: episode)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 20)
            // 宽度跟随窗口（用户要求：不写死），铺满除页边距外的舞台宽。
            .frame(maxWidth: .infinity, alignment: .leading)
            .lightAnchorPanel(radius: LightAnchorDesign.radiusHero)

            workspaceStatChips
                .padding(.top, 18)
        }
    }

    /// 卡内发丝分隔线（样机 .cardsep）。
    private var cardSeparator: some View {
        Rectangle()
            .fill(LightAnchorTheme.hairlineBorder)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func currentWorkHeader(episode: AttentionEpisode, target: AttentionTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                HStack(spacing: 8) {
                    LightAnchorStatusDot(episode.state, size: 9)
                    Text(UserFacingCopy.waitingState(episode.state))
                        .font(LightAnchorTheme.bodyFont(size: 12.5, weight: .semibold))
                        .foregroundStyle(stateColor(episode.state))
                    Text(String(format: tr("started_3"), episode.startedAt.formatted(date: .omitted, time: .shortened)))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }
                .padding(.top, 12)

                Spacer(minLength: 12)

                // 大号细体计时：页面的视觉锚（V7）；超过一小时拆报时分。
                LightAnchorFocusReadout(minutes: elapsedMinutes(for: episode))
                    .accessibilityLabel(String(format: tr("focused_for"), UserFacingCopy.focusDuration(elapsedMinutes(for: episode))))
            }

            Text(target.name)
                .font(LightAnchorTheme.titleFont(size: 26, weight: .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !target.note.isEmpty {
                Text(target.note)
                    .font(LightAnchorTheme.bodyFont(size: 13))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 这件事的全程纵深一行小字：做过多段才显示（工作记忆·F4）。
            if let historyLine = workspace.currentTargetHistoryLine() {
                Text(historyLine)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elapsedMinutes(for episode: AttentionEpisode) -> Int {
        // 大号计时显示专注分钟：暂停/等待时数字停住，而不是继续走墙钟。
        workspace.snapshot.focusMinutes(of: episode.id)
    }

    @ViewBuilder
    private func currentWorkActions(episode: AttentionEpisode) -> some View {
        HStack(alignment: .center, spacing: 8) {
            switch episode.state {
            case .active, .returning:
                // 按钮叫「暂时放下」而不是「暂停」：它落地的地方（稍后页那一组）
                // 就叫这个名字。一个动作在按下处和落地处叫两个名字，用户没法
                // 把两页连起来。
                Button(tr("set_aside"), action: { _ = workspace.pauseEpisode(episode.id, returnCue: episode.returnCue) })
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
            case .paused:
                Button(tr("continue"), action: { _ = workspace.resumeEpisode(episode.id) })
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
            case .waiting:
                // 取消等待全程一个名字：「不再等待」（原「不用等了」是同一操作的第三个名字）。
                Button(tr("stop_waiting"), action: { cancelCurrentWaiting(episode) })
                    .buttonStyle(LightAnchorQuietButtonStyle())
            case .ended:
                EmptyView()
            }
            // 换一件事就在这条动作条上：在这之前，想换一件事得先点「暂停」把
            // 现在页清空，才看得见「开始一件事」——一个听起来像休息的动作，
            // 用来完成一件其实叫切换的事。
            if episode.state != .ended {
                Button(tr("switch_to_something_else"), action: onSwitch)
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .help(tr("sets_this_one_aside_with_its"))
            }
            if episode.state != .waiting && episode.state != .ended {
                Button(UserFacingCopy.waitForResult, action: onWait)
                    .buttonStyle(LightAnchorQuietButtonStyle())
            }
            // 单次开启「记录本次」：给这件事录一份过程，生命周期随它走
            // （放下暂停、恢复继续、结束收尾）。已在录时入口在悬浮动作组。
            if episode.state != .ended,
               workspace.activeRecordingSession == nil {
                Button(tr("record_this_one")) {
                    _ = workspace.startRecordingCurrentEpisode()
                }
                .buttonStyle(LightAnchorQuietButtonStyle())
                .help(tr("auto_record_episodes_detail"))
            }
            if episode.state != .ended {
                Spacer(minLength: 8)
                Button {
                    _ = workspace.endEpisode(episode.id)
                } label: {
                    // 勾形给「完成」一个身份记号——三颗灰字按钮里它是收束的那颗。
                    HStack(spacing: 6) {
                        LightAnchorIcon("check", size: 12)
                        Text(UserFacingCopy.finishWork)
                    }
                }
                .buttonStyle(LightAnchorSuccessButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cancelCurrentWaiting(_ episode: AttentionEpisode) {
        workspace.snapshot.activeWaitingItems
            .filter { $0.episodeID == episode.id && $0.status == .waiting }
            .forEach { _ = workspace.cancelWaiting($0.id, evidence: "用户停止等待。") }
    }

    private func stateColor(_ state: AttentionEpisodeState) -> LightAnchorThemeColor {
        switch state {
        case .active, .returning: LightAnchorTheme.accentInk
        case .paused, .ended: LightAnchorTheme.mutedInk
        case .waiting: LightAnchorDesign.waiting
        }
    }
}

/// 目标回顾（点「最近的事」或搜索结果进入）：中心舞台的一张回顾卡——
/// 这件事是什么、一共投入了多少专注、每一段的经过，以及回去的入口。
private struct TargetReviewView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let targetID: UUID
    let onResume: () -> Void
    let onClose: () -> Void

    private var target: AttentionTarget? {
        workspace.snapshot.targets[targetID]
    }

    private var episodes: [AttentionEpisode] {
        workspace.snapshot.episodes.values
            .filter { $0.targetID == targetID && !$0.isBackground }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var totalFocusMinutes: Int {
        episodes.reduce(0) { $0 + workspace.snapshot.focusMinutes(of: $1.id) }
    }

    private var latestScene: SceneSnapshot? {
        workspace.snapshot.latestSceneSnapshot(for: targetID)
    }

    var body: some View {
        // 与「现在」页同一构图：居中舞台 + 工作卡语言。
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let target {
                        reviewCard(target)
                    }
                }
                .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 24))
                .padding(.bottom, 24)
            }
        }
    }

    private func reviewCard(_ target: AttentionTarget) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                HStack(spacing: 8) {
                    if let latest = episodes.first {
                        LightAnchorStatusDot(latest.state, size: 9)
                        Text(String(format: tr("review"), UserFacingCopy.waitingState(latest.state)))
                            .font(LightAnchorTheme.bodyFont(size: 12.5, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                        Text(String(format: tr("last_active"), UserFacingCopy.relativeAge(of: latest.endedAt ?? latest.startedAt)))
                            .font(LightAnchorTheme.supportingFont(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }
                }
                .padding(.top, 12)

                Spacer(minLength: 12)

                LightAnchorFocusReadout(minutes: totalFocusMinutes, caption: tr("caption_total"))
                    .accessibilityLabel(String(format: tr("total_focus"), UserFacingCopy.focusDuration(totalFocusMinutes)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(target.name)
                    .font(LightAnchorTheme.titleFont(size: 26, weight: .semibold))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !target.note.isEmpty {
                    Text(target.note)
                        .font(LightAnchorTheme.bodyFont(size: 13))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 现场概览 chips（样机 .chip：应用 N · 文件 N · 页面 N）。
            if let scene = latestScene, !scene.restorableItems.isEmpty {
                HStack(spacing: 7) {
                    ForEach(SceneItemKind.allCases, id: \.self) { kind in
                        let count = scene.restorableItems.filter { $0.kind == kind }.count
                        if count > 0 {
                            reviewChip("\(kind.title) \(count)")
                        }
                    }
                }
            }

            cardSeparator

            // 每一段的经过：最近 6 段，右列专注分钟。
            VStack(alignment: .leading, spacing: 8) {
                Text(String(
                    format: episodes.count == 1 ? tr("history_sessions_one") : tr("history_sessions"),
                    episodes.count
                ))
                    .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                ForEach(episodes.prefix(6)) { episode in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(episode.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(LightAnchorTheme.supportingFont(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                        Text(UserFacingCopy.waitingState(episode.state))
                            .font(LightAnchorTheme.supportingFont(size: 12.5))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                        Spacer(minLength: 10)
                        Text(String(format: tr("focused"), UserFacingCopy.focusDuration(workspace.snapshot.focusMinutes(of: episode.id))))
                            .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(LightAnchorTheme.ink)
                    }
                }
                if episodes.count > 6 {
                    Text(String(
                        format: episodes.count - 6 == 1
                            ? tr("earlier_sessions_one") : tr("earlier_sessions"),
                        episodes.count - 6
                    ))
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }
            }

            cardSeparator

            HStack(spacing: 8) {
                Button(tr("back_to_this"), action: onResume)
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                    .help(
                        workspace.currentEpisode == nil
                            ? tr("start_a_new_session")
                            : tr("pauses_the_current_work_then_starts")
                    )
                Button(UserFacingCopy.close, action: onClose)
                    .buttonStyle(LightAnchorQuietButtonStyle())
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lightAnchorPanel(radius: LightAnchorDesign.radiusHero)
        .onExitCommand(perform: onClose)
    }

    private func reviewChip(_ text: String) -> some View {
        Text(text)
            .font(LightAnchorTheme.controlFont(size: 12))
            .monospacedDigit()
            .foregroundStyle(LightAnchorTheme.mutedInk)
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(LightAnchorTheme.recessed, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(LightAnchorTheme.sidebarHairline, lineWidth: 1)
            }
    }

    private var cardSeparator: some View {
        Rectangle()
            .fill(LightAnchorTheme.hairlineBorder)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct LaterSpaceView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Binding var scope: LaterScope
    let selectedResult: WorkspaceSearchResult?
    let onCapture: () -> Void
    /// 「继续」某件放下的事：切换由用户在这张完整列表上自己决定。
    let onSwitch: (UUID) -> Void
    @State private var showingTriage = false

    var body: some View {
        Group {
            if visibleCount == 0 {
                ScrollView {
                    pageContent
                }
            } else {
                pageContent
            }
        }
        .sheet(isPresented: $showingTriage) {
            InboxTriageSheet()
                .environmentObject(workspace)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 样机 .readout + .segsoft：眉题行 + 凹陷小药盒分段。
            LightAnchorReadout(tr("later"), status: tr("what_you_tuck_away_comes_back")) {
                LightAnchorReadoutCount(visibleCount)
                if scope == .inbox, workspace.snapshot.inbox.count > 1 {
                    Button(tr("ai_tidy_up")) {
                        showingTriage = true
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    .help(tr("the_engine_proposes_a_destination_for"))
                }
            }

            LightAnchorSegSoft(
                selection: $scope,
                options: LaterScope.allCases,
                title: { $0.title }
            )
            // SegSoft 不再自带外边距（会破坏组头行的居中对齐），这里自己给：
            // 左 2 与眉题文字光学对齐，下 14 是分段到列表的组距。
            .padding(.leading, 2)
            .padding(.bottom, 14)

            if visibleCount == 0 {
                LightAnchorEmptyState(
                    title: scope.emptyTitle,
                    detail: scope.emptyDetail,
                    actionTitle: emptyActionTitle,
                    action: performEmptyAction
                )
                .padding(.top, 12)
            } else {
                // 放下的未完成事住在稍后第一档最上面：它们就是「之后要处理的事」，
                // 完整列出，谁先谁后由用户自己挑。
                if scope == .inbox, !workspace.snapshot.setAsideEpisodes.isEmpty {
                    setAsideSection
                        .padding(.bottom, 14)
                }
                LaterCaptureList(
                    scope: scope,
                    selectedResult: selectedResult
                )
                    .environmentObject(workspace)
                    .frame(minHeight: 360, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var visibleCount: Int {
        switch scope {
        case .inbox:
            workspace.snapshot.inbox.count + workspace.snapshot.setAsideEpisodes.count
        case .references: workspace.snapshot.referenceCaptures.count
        case .archived: workspace.snapshot.archivedCaptures.count
        }
    }

    /// 「暂时放下」组：完整列表 + 每行一颗「继续」。
    private var setAsideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("set_aside"))
                    .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                // 和等待页的分界线就在这一句：这里的事没人替你推进，
                // 什么时候回去由你定；等待页的事反过来。
                Text(tr("you_set_these_aside_yourself_come"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            .padding(.leading, 2)

            LightAnchorListPanel {
                let entries = setAsideEntries
                ForEach(entries, id: \.episode.id) { entry in
                    setAsideRow(entry)
                    if entry.episode.id != entries.last?.episode.id {
                        LightAnchorRowSeparator()
                    }
                }
            }
        }
    }

    private var setAsideEntries: [(target: AttentionTarget, episode: AttentionEpisode)] {
        workspace.snapshot.setAsideEpisodes.compactMap { episode in
            guard let target = workspace.snapshot.targets[episode.targetID] else { return nil }
            return (target: target, episode: episode)
        }
    }

    private func setAsideRow(_ entry: (target: AttentionTarget, episode: AttentionEpisode)) -> some View {
        HStack(spacing: 12) {
            LightAnchorStatusDot(entry.episode.state, size: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.target.name)
                    .font(LightAnchorTheme.bodyFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                Text(setAsideMeta(entry.episode))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            Spacer(minLength: 12)
            Button(tr("continue")) {
                onSwitch(entry.target.id)
            }
            .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
        }
        .lightAnchorListRow()
        .accessibilityElement(children: .combine)
    }

    private func setAsideMeta(_ episode: AttentionEpisode) -> String {
        let focus = workspace.snapshot.focusMinutes(of: episode.id)
        let aside = UserFacingCopy.setAsideAge(of: episode.updatedAt)
        guard focus > 0 else { return aside }
        return aside + " · " + String(format: tr("total_focus"), UserFacingCopy.focusDuration(focus))
    }

    private var emptyActionTitle: String {
        scope == .inbox ? UserFacingCopy.captureIdea : tr("view_new_items")
    }

    private func performEmptyAction() {
        if scope == .inbox {
            onCapture()
        } else {
            scope = .inbox
        }
    }
}

private struct LaterCaptureList: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let scope: LaterScope
    let selectedResult: WorkspaceSearchResult?
    @State private var captureForTarget: CaptureItem?
    @State private var captureForWaiting: CaptureItem?
    @State private var captureToDelete: CaptureItem?
    @State private var captureForTags: CaptureItem?

    @State private var selectedTag: String?
    @State private var selectedSource: String?

    /// 当前档位的全部条目（未过滤）。
    private var baseItems: [CaptureItem] {
        switch scope {
        case .inbox: workspace.snapshot.inbox
        case .references: workspace.snapshot.referenceCaptures
        case .archived: workspace.snapshot.archivedCaptures
        }
    }

    /// 当前条目里出现过的标签（按名称排序）。
    private var availableTags: [String] {
        var seen = Set<String>()
        return baseItems
            .flatMap(\.tags)
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// 当前条目里出现过的来源应用（按名称排序，最多 8 个再多就没有筛选价值）。
    private var availableSources: [String] {
        var seen = Set<String>()
        return baseItems
            .compactMap { $0.sourceApplication?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCompare($1) == .orderedAscending }
            .prefix(8)
            .map { $0 }
    }

    private var filteredItems: [CaptureItem] {
        var items = baseItems
        if let selectedTag, availableTags.contains(selectedTag) {
            items = items.filter { $0.tags.contains(selectedTag) }
        }
        if let selectedSource, availableSources.contains(selectedSource) {
            items = items.filter { $0.sourceApplication == selectedSource }
        }
        return items
    }

    var body: some View {
        // 样机 .listpanel：白卡 + 内缩发丝分隔，不用 List。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !availableTags.isEmpty || !availableSources.isEmpty {
                    filterRow
                }
                LightAnchorListPanel {
                    let items = filteredItems
                    if scope == .inbox {
                        ForEach(items) { capture in
                            LaterCaptureRow(
                                capture: capture,
                                isSelected: selectedResult?.id == "capture-\(capture.id.uuidString)"
                            ) {
                                captureForTarget = capture
                            } onWaiting: {
                                if workspace.currentEpisode != nil {
                                    captureForWaiting = capture
                                } else {
                                    workspace.presentNotice(tr("start_something_first_then_this_can"))
                                }
                            } onArchive: {
                                _ = workspace.archiveCapture(capture.id)
                            } onDelete: {
                                captureToDelete = capture
                            } onEditTags: {
                                captureForTags = capture
                            }
                            .environmentObject(workspace)
                            if capture.id != items.last?.id {
                                LightAnchorRowSeparator()
                            }
                        }
                    } else {
                        ForEach(items) { capture in
                            compactRow(capture)
                            if capture.id != items.last?.id {
                                LightAnchorRowSeparator()
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 18)
        }
        .sheet(item: $captureForTarget) { capture in
            CaptureTargetEditorView(capture: capture)
                .environmentObject(workspace)
        }
        .sheet(item: $captureForWaiting) { capture in
            if let episode = workspace.currentEpisode {
                CaptureWaitingEditorView(capture: capture, episodeID: episode.id)
                    .environmentObject(workspace)
            }
        }
        .sheet(item: $captureForTags) { capture in
            CaptureTagEditorView(capture: capture)
                .environmentObject(workspace)
        }
        .alert(
            tr("delete_this_item"),
            isPresented: Binding(
                get: { captureToDelete != nil },
                set: { if !$0 { captureToDelete = nil } }
            ),
            presenting: captureToDelete
        ) { capture in
            Button(UserFacingCopy.delete, role: .destructive) {
                _ = workspace.deleteCapture(capture.id)
                captureToDelete = nil
            }
            Button(UserFacingCopy.cancel, role: .cancel) { captureToDelete = nil }
        } message: { capture in
            Text(
                capture.assetURL == nil
                    ? tr("this_can_t_be_undone_if")
                    : tr("this_can_t_be_undone_and")
            )
        }
    }

    /// 资料/归档档的紧凑行：标题 + 附件 + 元信息，动作按档位给。
    @ViewBuilder
    private func compactRow(_ capture: CaptureItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.body.isEmpty ? capture.title ?? tr("saved_items") : capture.body)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .lineLimit(2)
                    // 截断藏的是捕获全文，收件箱档能看全、归档后反而看不全——
                    // 原生 tooltip 把完整值留在可达位置。
                    .help(capture.body.isEmpty ? (capture.title ?? "") : capture.body)
                CaptureAttachmentRow(capture: capture)
                Text(captureMetaLine(capture))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            Spacer(minLength: 14)
            if scope == .references {
                Button(UserFacingCopy.archive) {
                    _ = workspace.archiveCapture(capture.id)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                LightAnchorOverflowMenu(actions: [
                    LightAnchorOverflowAction(
                        title: tr("back_to_inbox"),
                        icon: "tray",
                        action: { _ = workspace.moveCaptureToInbox(capture.id) }
                    ),
                    LightAnchorOverflowAction(
                        title: UserFacingCopy.delete,
                        icon: "trash-2",
                        isDestructive: true,
                        action: { captureToDelete = capture }
                    )
                ])
                .frame(width: 27)
            } else {
                // 归档档：还原是第一动作——归档不是终点。
                Button(tr("back_to_inbox")) {
                    _ = workspace.moveCaptureToInbox(capture.id)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                LightAnchorOverflowMenu(actions: [
                    LightAnchorOverflowAction(
                        title: tr("file_as_reference"),
                        icon: "bookmark",
                        action: { _ = workspace.saveCaptureAsReference(capture.id) }
                    ),
                    LightAnchorOverflowAction(
                        title: UserFacingCopy.delete,
                        icon: "trash-2",
                        isDestructive: true,
                        action: { captureToDelete = capture }
                    )
                ])
                .frame(width: 27)
            }
        }
        .lightAnchorListRow(
            selectedResult?.id == "capture-\(capture.id.uuidString)" ? .found : .plain
        )
    }

    /// 筛选行：「全部」+ 标签胶囊 + 来源应用胶囊，点选过滤列表（可叠加）。
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                LightAnchorTagChip(
                    tag: tr("all"),
                    isSelected: selectedTag == nil && selectedSource == nil
                ) {
                    selectedTag = nil
                    selectedSource = nil
                }
                ForEach(availableTags, id: \.self) { tag in
                    LightAnchorTagChip(tag: "#\(tag)", isSelected: selectedTag == tag) {
                        selectedTag = selectedTag == tag ? nil : tag
                    }
                }
                ForEach(availableSources, id: \.self) { source in
                    LightAnchorTagChip(tag: source, isSelected: selectedSource == source) {
                        selectedSource = selectedSource == source ? nil : source
                    }
                }
            }
            .padding(.leading, 2)
        }
        .padding(.bottom, 10)
        .accessibilityLabel(tr("filter_by_tag_or_source"))
    }
}

/// 捕获附件行：截图出缩略图、语音/文件出小胶囊，点击都交给系统打开。
/// 附件文件不在了整行不显示（可能已被清理）。
private struct CaptureAttachmentRow: View {
    let capture: CaptureItem

    private var availableURL: URL? {
        guard let url = capture.assetURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    var body: some View {
        #if os(macOS)
        if let url = availableURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                if capture.kind == .screenshot, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 88, height: 55)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
                        }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: capture.kind == .voice ? "waveform" : "doc")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(attachmentLabel)
                            .font(LightAnchorTheme.controlFont(size: 11))
                    }
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(LightAnchorTheme.recessed, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(LightAnchorTheme.sidebarHairline, lineWidth: 1)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(tr("open_the_attachment_with_the_system"))
            .accessibilityLabel(attachmentLabel)
        }
        #endif
    }

    private var attachmentLabel: String {
        if capture.kind == .voice {
            if let duration = capture.duration, duration >= 1 {
                return String(format: tr("play_recording_s"), Int(duration.rounded()))
            }
            return tr("play_recording")
        }
        if capture.kind == .screenshot { return tr("view_screenshot") }
        return tr("open_attachment")
    }
}

/// 「X 分钟前 · 文字 · Safari · #标签」式元信息行（来源应用露出，工作记忆·F7）。
func captureMetaLine(_ capture: CaptureItem) -> String {
    var parts = [
        UserFacingCopy.relativeAge(of: capture.capturedAt),
        UserFacingCopy.captureKind(capture.kind)
    ]
    if let source = capture.sourceApplication?.trimmingCharacters(in: .whitespaces), !source.isEmpty {
        parts.append(source)
    }
    if !capture.tags.isEmpty {
        parts.append(capture.tags.map { "#\($0)" }.joined(separator: " "))
    }
    return parts.joined(separator: " · ")
}

/// 编辑一条捕获的标签：标签选择器 + 保存。
private struct CaptureTagEditorView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let capture: CaptureItem
    @State private var tags: [String]

    init(capture: CaptureItem) {
        self.capture = capture
        _tags = State(initialValue: capture.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("edit_tags"))
                .font(LightAnchorTheme.interfaceFont(size: 14.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
            Text(capture.body.isEmpty ? capture.title ?? tr("saved_items") : capture.body)
                .font(LightAnchorTheme.supportingFont(size: 12))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .lineLimit(2)

            LightAnchorTagPicker(
                selected: $tags,
                knownTags: workspace.snapshot.allCaptureTags
            )

            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button(UserFacingCopy.cancel) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                Button(UserFacingCopy.save) {
                    _ = workspace.setCaptureTags(capture.id, tags: tags)
                    dismiss()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
            }
        }
        .padding(18)
        .frame(width: 330)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .onExitCommand { dismiss() }
    }
}

private struct LaterCaptureRow: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let capture: CaptureItem
    let isSelected: Bool
    let onStart: () -> Void
    let onWaiting: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onEditTags: () -> Void

    private var suggestion: SemanticSuggestion {
        LocalSemanticAnalyzer().analyze(capture)
    }

    var body: some View {
        // 样机 .row：标题/元信息/蓝色建议语在左，.btn.sm 操作组靠右，无行首图标。
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.body.isEmpty ? capture.title ?? tr("saved_items") : capture.body)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    // 用户自己写的正文最容易变长，多行时补库内一贯的 +3 行距。
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                CaptureAttachmentRow(capture: capture)
                    .padding(.vertical, 2)
                Text(captureMetaLine(capture))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                if !suggestion.summary.isEmpty {
                    Text(actionPrompt)
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.accentInk)
                }
            }

            Spacer(minLength: 14)

            HStack(spacing: 6) {
                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                if workspace.currentEpisode != nil && suggestion.disposition != .waiting {
                    Button(tr("wait_for_a_result"), action: onWaiting)
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                }
                LightAnchorOverflowMenu(actions: overflowActions)
                    .frame(width: 27)
            }
            .layoutPriority(1)
        }
        .lightAnchorListRow(isSelected ? .found : .plain)
    }

    private var overflowActions: [LightAnchorOverflowAction] {
        var actions = [
            LightAnchorOverflowAction(
                title: tr("edit_tags"),
                icon: "bookmark",
                action: onEditTags
            )
        ]
        // 资料不是死水：随时可以回到收件箱重新决定去向。
        if capture.status == .reference {
            actions.append(LightAnchorOverflowAction(
                title: tr("back_to_inbox"),
                icon: "tray",
                action: { _ = workspace.moveCaptureToInbox(capture.id) }
            ))
        }
        actions.append(LightAnchorOverflowAction(
            title: UserFacingCopy.archive,
            icon: "archive",
            action: onArchive
        ))
        actions.append(LightAnchorOverflowAction(
            title: UserFacingCopy.delete,
            icon: "trash-2",
            isDestructive: true,
            action: onDelete
        ))
        return actions
    }

    private var primaryActionTitle: String {
        switch suggestion.disposition {
        case .action, .idea: tr("start")
        case .waiting: UserFacingCopy.waitForResult
        case .reference, .context: tr("save_reference")
        }
    }

    private var actionPrompt: String {
        switch suggestion.disposition {
        case .action, .idea: tr("you_can_start_here")
        case .waiting: tr("looks_like_this_is_waiting_on")
        case .reference: tr("worth_keeping_to_look_up_later")
        case .context: tr("part_of_where_you_just_were")
        }
    }

    private func primaryAction() {
        switch suggestion.disposition {
        case .action, .idea:
            onStart()
        case .waiting:
            onWaiting()
        case .reference, .context:
            _ = workspace.saveCaptureAsReference(capture.id)
        }
    }
}

private struct WaitingSpaceView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let onRestore: (WaitingItem) -> Void
    let onCreateWaiting: () -> Void
    let selectedResult: WorkspaceSearchResult?

    private var readyItems: [WaitingItem] {
        workspace.snapshot.readyWaitingItems
    }

    private var inProgressItems: [WaitingItem] {
        workspace.snapshot.activeWaitingItems.filter { $0.status == .waiting }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 样机 .readout：等待｜结果不由你推进｜可返回 N · 等结果中 N。
                // 副标题刻意不提「放下」：那是稍后页的语义，等待页借它来
                // 自我介绍时，两页就成了同一页。
                LightAnchorReadout(tr("waiting"), status: tr("results_you_don_t_push_them")) {
                    LightAnchorReadoutCount(segments: [
                        (readyItems.count, tr("ready")),
                        (inProgressItems.count, tr("waiting_for_result"))
                    ])
                    Button(tr("add_a_wait")) {
                        onCreateWaiting()
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                    .disabled(workspace.currentEpisode == nil)
                    .help(
                        workspace.currentEpisode == nil
                            ? tr("start_a_current_task_first_to")
                            : tr("hand_results_you_re_watching_for")
                    )
                }

                if readyItems.isEmpty && inProgressItems.isEmpty {
                    LightAnchorEmptyState(
                        // 蓝点点环 = 「等待外部结果」，正好是这一页的语义。
                        markState: .waiting,
                        title: UserFacingCopy.noWaitingItems,
                        detail: tr("when_you_re_waiting_on_a")
                    )
                    .padding(.top, 4)
                } else {
                    if !readyItems.isEmpty {
                        waitingGroup(title: tr("ready_to_return"), icon: "checkmark.circle", items: readyItems, isReadyGroup: true)
                    }
                    if !inProgressItems.isEmpty {
                        waitingGroup(title: tr("waiting_for_result"), icon: "hourglass", items: inProgressItems, isReadyGroup: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private func waitingGroup(title: String, icon: String, items: [WaitingItem], isReadyGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 样机 .grouphead + .listpanel。
            LightAnchorGroupHead(
                role: isReadyGroup ? .ready : .waiting,
                title: title,
                badge: String(format: items.count == 1 ? tr("items_one") : tr("items"), items.count)
            )

            LightAnchorListPanel {
                ForEach(items) { waiting in
                    WaitingRow(
                        waiting: waiting,
                        isSelected: selectedResult?.id == "waiting-\(waiting.id.uuidString)",
                        isFrost: !isReadyGroup,
                        onRestore: onRestore
                    )
                        .environmentObject(workspace)
                    if waiting.id != items.last?.id {
                        LightAnchorRowSeparator()
                    }
                }
            }
        }
    }
}

private struct WaitingRow: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let waiting: WaitingItem
    let isSelected: Bool
    var isFrost = false
    let onRestore: (WaitingItem) -> Void

    private var isReady: Bool { waiting.status == .ready }

    /// Agent / 终端事件自动归集的等待：确认不切换当前工作，进行中不提供手动完成。
    private var isAutoManaged: Bool { waiting.monitor?.eventAutoManaged == true }

    /// 「已等 18 分钟」式的相对时间（V7 文案密度）。原来这里写的是
    /// 「18 分钟前放下」——但一件正在等外部结果的事，用户并没有「放下」它，
    /// 是它还没回来。手动等待和自动等待在这一点上没有区别，所以不再分动词。
    private var relativeStartLabel: String {
        UserFacingCopy.waitedAge(of: waiting.startedAt)
    }

    private var metaLine: String {
        var parts = [UserFacingCopy.waitingProgress(for: waiting), relativeStartLabel]
        if !waiting.completionCondition.isEmpty {
            parts.append(
                String(format: tr("return_cue_is"), waiting.completionCondition)
            )
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // 样机 .row：标题/元信息在左，.btn.sm 操作组靠右。普通行无行首
        // 图标；来自外部工具的自动等待带对方的产品图标——一眼认出是谁。
        HStack(alignment: .center, spacing: 12) {
            if let brand = IntegrationBrand.forAutoWait(waiting) {
                // 此处图标是「来自哪个工具」的唯一来源（描述就是事件标题），
                // 对旁白不能隐藏，否则两条同名等待无从区分。
                IntegrationBrandIcon(brand: brand, size: 20, isDecorative: false)
                    .opacity(isFrost ? 0.75 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(waiting.description)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    // 「N 分钟前放下」每分钟跳变，比例数字会让整行横移。
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(2)
                if !waiting.evidence.isEmpty {
                    Text(waiting.evidence)
                        .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .medium))
                        .foregroundStyle(isReady ? LightAnchorDesign.success : LightAnchorTheme.mutedInk)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 14)

            HStack(spacing: 6) {
                if isReady {
                    if isAutoManaged {
                        // Agent 回合 / 终端命令的结果：确认即可，不切换当前工作。
                        Button(tr("got_it")) {
                            _ = workspace.acknowledgeWaitingResult(waiting.id)
                        }
                        .buttonStyle(LightAnchorSuccessButtonStyle(compact: true))
                        // 忽略已到结果全程一个名字：「不再需要」（与手动等待那侧一致；
                        // 原「不再关注」在两处对应两种不同操作，最危险的同词异义）。
                        Button(tr("no_longer_needed")) {
                            _ = workspace.dismissWaitingResult(waiting.id)
                        }
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    } else {
                        Button(tr("back_to_work")) {
                            onRestore(waiting)
                        }
                        .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                        Button(tr("no_longer_needed")) {
                            _ = workspace.dismissWaitingResult(waiting.id)
                        }
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    }
                } else if isAutoManaged {
                    // 取消等待全程一个名字：「不再等待」，与手动侧同词同样式。
                    Button(tr("stop_waiting"), role: .destructive) {
                        _ = workspace.cancelWaiting(waiting.id, evidence: "用户停止等待。")
                    }
                    .buttonStyle(LightAnchorDestructiveQuietButtonStyle(compact: true))
                } else {
                    Button(tr("result_is_in")) {
                        _ = workspace.completeWaiting(
                            waiting.id,
                            evidence: "用户确认可以返回。"
                        )
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    Button(tr("stop_waiting"), role: .destructive) {
                        _ = workspace.cancelWaiting(waiting.id, evidence: "用户停止等待。")
                    }
                    .buttonStyle(LightAnchorDestructiveQuietButtonStyle(compact: true))
                }
            }
            .layoutPriority(1)
        }
        .lightAnchorListRow(isSelected ? .found : (isFrost ? .frost : .plain))
    }
}

struct StartWorkView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note = ""
    @State private var showingMore = false
    @State private var environmentProfileID: UUID?
    @State private var prepareEnvironment = false

    /// 「换一件事」浮层里敲了一半的名字带进来，用户不用再打一遍。
    init(initialName: String = "") {
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LightAnchorSheetHeader(
                eyebrow: tr("start_working"),
                title: UserFacingCopy.startWork,
                subtitle: tr("just_write_down_what_you_re"),
                icon: "play"
            )
            LightAnchorSettingsSection(
                title: tr("what_you_re_doing_now"),
                detail: tr("the_name_becomes_your_way_back"),
                icon: "pencil"
            ) {
                TextField(tr("e_g_organise_the_interview_notes"), text: $name)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .onSubmit(start)
            }
            LightAnchorSettingsSection(
                title: tr("how_to_prepare"),
                detail: tr("optional_you_can_still_change_it"),
                icon: "panels-top-left"
            ) {
                LightAnchorDisclosure(title: tr("more_settings"), isExpanded: $showingMore) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(tr("optional_note"), text: $note, axis: .vertical)
                            .textFieldStyle(LightAnchorTextFieldStyle())
                            .lineLimit(2...4)
                        if !workspace.snapshot.environments.isEmpty {
                            LightAnchorSelectField(
                                tr("how_you_work"),
                                selection: $environmentProfileID,
                                options: [UUID?.none] + workspace.snapshot.environments.values
                                    .sorted { $0.name < $1.name }
                                    .map { Optional($0.id) }
                            ) { profileID in
                                guard let profileID else { return tr("none_for_now") }
                                return workspace.snapshot.environments[profileID]?.name ?? tr("none_for_now")
                            }
                            if let environmentProfileID,
                               let environment = workspace.snapshot.environments[environmentProfileID] {
                                Toggle(tr("set_the_scene_on_start"), isOn: $prepareEnvironment)
                                    .toggleStyle(.switch)
                                Text(
                                    prepareEnvironment
                                        ? String(
                                            format: environment.actions.filter(\.isEnabled).count == 1
                                                ? tr("will_run_n_actions_on_start_one")
                                                : tr("will_run_n_actions_on_start"),
                                            environment.actions.filter(\.isEnabled).count
                                          )
                                        : tr("only_links_this_environment_actions_won")
                                )
                                .font(LightAnchorTheme.supportingFont(size: 11))
                                .foregroundStyle(LightAnchorTheme.mutedInk)
                            }
                        }
                    }
                }
            }
            LightAnchorSheetActionBar {
                Button(UserFacingCopy.cancel) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                Button(UserFacingCopy.startWork, action: start)
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 560, height: 520)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .onExitCommand { dismiss() }
    }

    private func start() {
        let environmentToPrepare = prepareEnvironment
            ? environmentProfileID.flatMap { workspace.snapshot.environments[$0] }
            : nil
        guard let target = workspace.createTarget(
            name: name,
            note: note,
            environmentProfileID: environmentProfileID
        ) else { return }
        _ = workspace.startEpisode(targetID: target.id)
        if let environmentToPrepare {
            Task { @MainActor in
                let execution = await EnvironmentActionRunner().executeSession(environmentToPrepare)
                workspace.recordEnvironmentRun(profile: environmentToPrepare, execution: execution)
                let failed = execution.results.filter { $0.status == .failed }.count
                let succeeded = execution.results.filter { $0.status == .succeeded }.count
                var notice = String(
                    format: tr("scene_prepared_n_done_n_failed"),
                    succeeded,
                    failed
                )
                if failed > 0 {
                    notice += tr("do_a_trial_run_in_the")
                }
                if execution.isCloseOutMeaningful {
                    notice += tr("after_finishing_wind_down_on_the")
                }
                workspace.presentNotice(notice)
            }
        }
        dismiss()
    }
}

private struct WorkDetailsView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let target: AttentionTarget
    let episode: AttentionEpisode
    let onClose: () -> Void
    @State private var isEditing = false
    @State private var name: String
    @State private var note: String
    @State private var environmentProfileID: UUID?
    @State private var returnCue: String
    @State private var contextNote: String
    @State private var showingAbandonConfirmation = false

    init(target: AttentionTarget, episode: AttentionEpisode, onClose: @escaping () -> Void = {}) {
        self.target = target
        self.episode = episode
        self.onClose = onClose
        _name = State(initialValue: target.name)
        _note = State(initialValue: target.note)
        _environmentProfileID = State(initialValue: target.environmentProfileID)
        _returnCue = State(initialValue: episode.returnCue)
        _contextNote = State(initialValue: episode.context.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                LightAnchorDockHead(tr("scene"))
                Spacer()
                Button {
                    isEditing.toggle()
                } label: {
                    LightAnchorIcon(isEditing ? "x" : "pencil", size: 14)
                }
                .buttonStyle(LightAnchorIconButtonStyle())
                .help(isEditing ? UserFacingCopy.cancel : tr("edit_current_work"))
                .accessibilityLabel(isEditing ? UserFacingCopy.cancel : tr("edit_current_work"))
            }

            if isEditing {
                TextField(tr("name_of_this_work"), text: $name)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                TextField(tr("optional_detail"), text: $note, axis: .vertical)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .lineLimit(2...5)
                TextField(tr("what_to_look_at_first_2"), text: $returnCue, axis: .vertical)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .lineLimit(2...4)
                TextField(tr("context_note_optional"), text: $contextNote, axis: .vertical)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .lineLimit(2...4)
                if !workspace.snapshot.environments.isEmpty {
                    LightAnchorSelectField(
                        tr("set_up_when_entering"),
                        selection: $environmentProfileID,
                        options: [UUID?.none] + workspace.snapshot.environments.values
                            .sorted { $0.name < $1.name }
                            .map { Optional($0.id) }
                    ) { profileID in
                        guard let profileID else { return tr("none_for_now") }
                        return workspace.snapshot.environments[profileID]?.name ?? tr("none_for_now")
                    }
                }
                HStack {
                    Spacer()
                    Button(UserFacingCopy.cancel) {
                        resetEditingState()
                        isEditing = false
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    Button(UserFacingCopy.save) {
                        var updatedContext = episode.context
                        updatedContext.note = contextNote
                        guard workspace.updateContext(
                            for: episode.id,
                            context: updatedContext,
                            returnCue: returnCue
                        ), workspace.updateTarget(
                            target.id,
                            name: name,
                            note: note,
                            environmentProfileID: environmentProfileID
                        ) else { return }
                        onClose()
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(target.name)
                    .font(LightAnchorTheme.interfaceFont(size: 14.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !target.note.isEmpty {
                    Text(target.note)
                        .font(LightAnchorTheme.supportingFont(size: 12.5))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 键值行（样机 .dock .kv）：状态用文字蓝；环境行常驻，
                // 未绑定时显示「未指定」——样机三行齐全，缺行会显得残缺。
                VStack(alignment: .leading, spacing: 8) {
                    LightAnchorDockKeyValue(
                        key: tr("status"),
                        value: UserFacingCopy.waitingState(episode.state),
                        accent: true
                    )
                    LightAnchorDockKeyValue(
                        key: tr("started_2"),
                        value: episode.startedAt.formatted(date: .omitted, time: .shortened)
                    )
                    LightAnchorDockKeyValue(key: tr("environments"), value: environmentName)
                }

                // 「回来先看」卡常驻（样机 .cue）：没写线索时给一条引导占位。
                if episode.returnCue.isEmpty {
                    LightAnchorDockCueCard(
                        label: tr("look_at_this_first"),
                        text: tr("no_return_cue_yet_click_edit")
                    )
                } else {
                    LightAnchorDockCueCard(label: tr("look_at_this_first"), text: episode.returnCue)
                }
                if !episode.context.note.isEmpty {
                    Text(String(format: tr("context_note"), episode.context.note))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LightAnchorDockSeparator()
            contextFacts

            LightAnchorDockSeparator()
            VStack(alignment: .leading, spacing: 8) {
                LightAnchorDockKeyValue(key: tr("later"), value: "\(workspace.snapshot.inbox.count)")
                LightAnchorDockKeyValue(
                    key: tr("waiting"),
                    value: "\(workspace.snapshot.activeWaitingItems.count)"
                )
            }

            Spacer(minLength: 0)
            Button(tr("abandon_current_work")) {
                showingAbandonConfirmation = true
            }
            .buttonStyle(LightAnchorDestructiveQuietButtonStyle())
            .accessibilityHint(tr("opens_a_confirmation_dialog"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
        .background(LightAnchorTheme.contentBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .alert(tr("abandon_current_work_2"), isPresented: $showingAbandonConfirmation) {
            Button(tr("discard"), role: .destructive) {
                if workspace.abandonEpisode(episode.id) {
                    onClose()
                }
            }
            Button(UserFacingCopy.cancel, role: .cancel) { }
        } message: {
            Text(tr("this_ends_the_current_work_the"))
        }
        .onExitCommand(perform: onClose)
        .onChange(of: episode.id) {
            // Switching work while the inspector is open must not leave the
            // previous target's text in the fields, ready to be saved onto the
            // new one.
            isEditing = false
            resetEditingState()
        }
    }

    private var environmentName: String {
        guard let profileID = target.environmentProfileID,
              let environment = workspace.snapshot.environments[profileID] else { return tr("unspecified") }
        return environment.name
    }

    private func resetEditingState() {
        name = target.name
        note = target.note
        environmentProfileID = target.environmentProfileID
        returnCue = episode.returnCue
        contextNote = episode.context.note
    }

    @ViewBuilder
    private var contextFacts: some View {
        Group {
            if !episode.context.applications.isEmpty {
                LightAnchorLabel(
                    title: tr("apps_2") + episode.context.applications.joined(separator: "、"),
                    icon: "app-window"
                )
            }
            if !episode.context.files.isEmpty {
                LightAnchorLabel(
                    title: tr("files") + episode.context.files.map(\.lastPathComponent).joined(separator: "、"),
                    icon: "file"
                )
            }
            if !episode.context.links.isEmpty {
                LightAnchorLabel(
                    title: tr("pages") + episode.context.links.map(\.absoluteString).joined(separator: "、"),
                    icon: "link"
                )
                .lineLimit(2)
            }
        }
        .font(LightAnchorTheme.supportingFont(size: 12))
        .foregroundStyle(LightAnchorTheme.mutedInk)
    }
}


private struct CaptureTargetEditorView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let capture: CaptureItem
    @State private var name: String
    @State private var note = ""
    @State private var environmentProfileID: UUID?

    init(capture: CaptureItem) {
        self.capture = capture
        let suggestedName = capture.title
            ?? capture.body.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? "新的当前工作"
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("capture"),
                title: tr("start_from_this_capture"),
                subtitle: capture.body.isEmpty ? (capture.sourceURL?.absoluteString ?? "") : capture.body,
                icon: "play"
            )
            LightAnchorSettingsSection(
                title: tr("what_it_is"),
                detail: tr("turn_this_capture_into_work_you"),
                icon: "pencil"
            ) {
                TextField(tr("name_of_this_work"), text: $name)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                TextField(tr("optional_detail"), text: $note, axis: .vertical)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .lineLimit(2...4)
                if !workspace.snapshot.environments.isEmpty {
                    LightAnchorSelectField(
                        tr("set_up_when_entering"),
                        selection: $environmentProfileID,
                        options: [UUID?.none] + workspace.snapshot.environments.values
                            .sorted { $0.name < $1.name }
                            .map { Optional($0.id) }
                    ) { profileID in
                        guard let profileID else { return tr("none_for_now") }
                        return workspace.snapshot.environments[profileID]?.name ?? tr("none_for_now")
                    }
                }
            }
            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("create_and_start")) {
                    guard workspace.createTargetFromCapture(
                        capture.id,
                        name: name,
                        note: note,
                        environmentProfileID: environmentProfileID
                    ) != nil else { return }
                    dismiss()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 560, height: 460)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
    }
}

private enum WaitingReturnTiming: String, CaseIterable, Identifiable {
    case selfManaged
    case scheduled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selfManaged: tr("i_ll_confirm")
        case .scheduled: tr("timed_reminder")
        }
    }
}

private struct CaptureWaitingEditorView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let capture: CaptureItem
    let episodeID: UUID
    @State private var returnTiming: WaitingReturnTiming = .selfManaged
    @State private var reminderDate = Date().addingTimeInterval(1800)
    @State private var returnCue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("capture"),
                title: tr("turn_this_capture_into_a_wait"),
                subtitle: capture.body.isEmpty ? (capture.sourceURL?.absoluteString ?? "") : capture.body,
                icon: "hourglass"
            )
            LightAnchorSettingsSection(
                title: tr("when_to_look_again"),
                detail: tr("confirm_it_yourself_or_have_it"),
                icon: "clock"
            ) {
                LightAnchorChoiceField(
                    tr("how_to_get_back"),
                    selection: $returnTiming,
                    options: WaitingReturnTiming.allCases,
                    titleForValue: { $0.title },
                    iconForValue: { $0 == .scheduled ? "clock" : "circle-check" }
                )
                if returnTiming == .scheduled {
                    HStack {
                        Text(tr("reminder_time"))
                            .font(LightAnchorTheme.controlFont())
                        Spacer()
                        LightAnchorDateField(tr("reminder_time"), selection: $reminderDate, in: Date()...)
                    }
                }
                TextField(tr("return_cue_optional"), text: $returnCue)
                    .textFieldStyle(LightAnchorTextFieldStyle())
            }
            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("start_waiting")) {
                    guard workspace.beginWaitingFromCapture(
                        capture.id,
                        episodeID: episodeID,
                        kind: .manual,
                        completionCondition: returnCue,
                        restorePolicy: returnTiming == .scheduled ? .notify : .manual,
                        monitor: returnTiming == .scheduled
                            ? WaitingMonitorConfiguration(kind: .date, date: reminderDate)
                            : nil
                    ) != nil else { return }
                    dismiss()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        // 高度随内容走：切到「定时提醒」时弹窗自己长高，不用滚动去找时间字段。
        .frame(width: 560)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
    }
}


struct WaitingEditorView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let episodeID: UUID
    @State private var description = ""
    @State private var returnCue = ""
    @State private var returnTiming: WaitingReturnTiming = .selfManaged
    @State private var reminderDate = Date().addingTimeInterval(1800)

    init(episodeID: UUID) {
        self.episodeID = episodeID
        #if DEBUG
        // 调试后门（截图/验收用）：直接落在定时提醒状态。
        if ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_WAITING_TIMING"] == "scheduled" {
            _returnTiming = State(initialValue: .scheduled)
        }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("waiting"),
                title: tr("start_waiting"),
                subtitle: tr("hand_results_worth_watching_to_this"),
                icon: "hourglass"
            )

            LightAnchorSettingsSection(
                title: tr("what_you_re_waiting_for"),
                detail: tr("phrase_it_so_you_ll_recognise"),
                icon: "hourglass"
            ) {
                TextField(tr("e_g_waiting_for_the_client"), text: $description)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                TextField(tr("return_cue_optional"), text: $returnCue)
                    .textFieldStyle(LightAnchorTextFieldStyle())
            }

            LightAnchorSettingsSection(
                title: tr("when_to_look_again"),
                detail: tr("a_timed_reminder_moves_this_to"),
                icon: "clock"
            ) {
                LightAnchorChoiceField(
                    tr("how_to_get_back"),
                    selection: $returnTiming,
                    options: WaitingReturnTiming.allCases,
                    titleForValue: { $0.title },
                    iconForValue: { $0 == .scheduled ? "clock" : "circle-check" }
                )
                if returnTiming == .scheduled {
                    HStack {
                        Text(tr("reminder_time"))
                            .font(LightAnchorTheme.controlFont())
                        Spacer()
                        LightAnchorDateField(tr("reminder_time"), selection: $reminderDate, in: Date()...)
                    }
                }
            }

            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("start_waiting")) {
                    guard workspace.beginWaiting(
                        episodeID: episodeID,
                        kind: .manual,
                        description: description,
                        completionCondition: returnCue,
                        restorePolicy: returnTiming == .scheduled ? .notify : .manual,
                        monitor: returnTiming == .scheduled
                            ? WaitingMonitorConfiguration(kind: .date, date: reminderDate)
                            : nil
                    ) != nil else { return }
                    dismiss()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        // 高度随内容走：切到「定时提醒」时弹窗自己长高，不再需要滚动。
        .frame(width: 600)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
    }
}

struct CaptureView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @EnvironmentObject private var themeController: LightAnchorThemeController
    @Environment(\.dismiss) private var dismiss
    @State private var draftID = UUID()
    @State private var kind: CaptureKind = .text
    @State private var text = ""
    @State private var linkText = ""
    @State private var selectedFileURL: URL?
    @State private var screenshotData: Data?
    @State private var showingFileImporter = false
    @State private var isCapturingScreenshot = false
    @State private var validationMessage: String?
    @State private var errorMessage: String?
    @State private var voiceSession: MacVoiceCaptureSession?
    @State private var voiceResult: VoiceCaptureResult?
    @State private var isRecordingVoice = false
    @State private var sourceContext = ContextCapsule()
    /// 捕获前的前台应用：保存后把焦点还回去用（见 returnFocusToSourceApplication）。
    @State private var sourceApplicationBundleIdentifier: String?
    @State private var sourceProcessIdentifier: Int32?
    @State private var contextLimitations: [String] = []
    @State private var showingTerminationAlert = false
    @State private var selectedTags: [String] = []
    @State private var showingTagPicker = false
    /// 去向：由工具栏 + 菜单在开窗前写入偏好，这里开窗时消费一次后即重置——
    /// 普通开窗（⌥⌘N/菜单栏/空态按钮）永远进稍后，不留看不见的粘性状态。
    @State private var destination: CaptureStatus = .inbox
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var validationAccessibilityFocused: Bool
    var onClose: (() -> Void)? = nil

    var body: some View {
        windowComposer
        .padding(20)
        // 样机 capwin：四周均匀 20 的米白边——不给隐藏标题栏留安全区，
        // 并把安全区计入窗高的那 28pt 从底部扣回来，否则窗底多一截空白。
        .ignoresSafeArea(.container, edges: .top)
        .padding(.bottom, -28)
        .frame(width: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LightAnchorTheme.windowBackground)
        .modifier(CaptureWindowChromeModifier(enabled: true))
        .foregroundStyle(LightAnchorTheme.ink)
        .tint(LightAnchorThemePalette(theme: themeController.resolvedTheme).color(for: .primary))
        .onAppear {
            draftID = CaptureDraftCoordinator.shared.begin()
            let defaults = UserDefaults.standard
            destination = CaptureStatus(
                rawValue: defaults.string(
                    forKey: LightAnchorCaptureDestinationPreference.storageKey
                ) ?? ""
            ) == .reference ? .reference : .inbox
            defaults.set(
                CaptureStatus.inbox.rawValue,
                forKey: LightAnchorCaptureDestinationPreference.storageKey
            )
            loadSourceContext()
            focused = kind == .text
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item]
        ) { result in
            switch result {
            case .success(let url): selectedFileURL = url
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .requestCaptureDraftTerminationDecision
            )
        ) { _ in
            showingTerminationAlert = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .saveCaptureDraftForTermination
            )
        ) { _ in
            guard showingTerminationAlert else { return }
            if save() {
                AppTerminationController.shared.captureDraftDidSaveOrDiscard()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .discardCaptureDraftForTermination
            )
        ) { _ in
            guard showingTerminationAlert else { return }
            discardDraft()
            AppTerminationController.shared.captureDraftDidSaveOrDiscard()
        }
        .onChange(of: text) { _, _ in handleDraftContentChange() }
        .onChange(of: linkText) { _, _ in handleDraftContentChange() }
        .onChange(of: selectedFileURL) { _, _ in handleDraftContentChange() }
        .onChange(of: screenshotData) { _, _ in handleDraftContentChange() }
        .onChange(of: voiceResult) { _, _ in handleDraftContentChange() }
        .onChange(of: isRecordingVoice) { _, _ in handleDraftContentChange() }
        .onChange(of: kind) { _, value in
            validationMessage = nil
            validationAccessibilityFocused = false
            focused = value == .text || value == .link
            updateDraftState()
        }
        .alert(tr("unsaved_content"), isPresented: $showingTerminationAlert) {
            Button(tr("save_and_close")) {
                if save() {
                    AppTerminationController.shared.captureDraftDidSaveOrDiscard()
                } else {
                    AppTerminationController.shared.resolveCaptureDraftDecision(.cancel)
                }
            }
            Button(tr("discard_and_close"), role: .destructive) {
                discardDraft()
                AppTerminationController.shared.captureDraftDidSaveOrDiscard()
            }
            Button(UserFacingCopy.cancel, role: .cancel) {
                AppTerminationController.shared.resolveCaptureDraftDecision(.cancel)
            }
        } message: {
            Text(tr("the_capture_window_still_has_content"))
        }
        .onDisappear {
            CaptureDraftCoordinator.shared.end(draftID: draftID)
        }
        .onExitCommand { discardDraft() }
    }

    /// 悬浮写作条（样机 .capfloat）：呼出即写——开放输入区直接落在卡面上，
    /// 无标题行；底部一排无描边小图标工具 + 类型 chip + 取消 / 纸飞机发送键。
    private var windowComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputView
                .padding(.top, 2)
                .padding(.bottom, 26)

            captureFeedback

            captureActions
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(LightAnchorTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.10), radius: 22, y: 10)
    }

    @ViewBuilder
    private var captureFeedback: some View {
        if let validationMessage {
            LightAnchorLabel(title: validationMessage, icon: "alert-triangle", spacing: 7)
                .font(LightAnchorTheme.supportingFont(weight: .medium))
                .foregroundStyle(LightAnchorTheme.error)
                .padding(.horizontal, 8)
                .accessibilityLabel(String(format: tr("can_t_save"), validationMessage))
                .accessibilityFocused($validationAccessibilityFocused)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(LightAnchorTheme.supportingFont())
                .foregroundStyle(LightAnchorTheme.error)
                .padding(.horizontal, 8)
                .accessibilityLabel(String(format: tr("failed"), errorMessage))
        }

        ForEach(contextLimitations, id: \.self) { limitation in
            Text(limitation)
                .font(LightAnchorTheme.supportingFont())
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .padding(.horizontal, 8)
        }
    }

    /// 底部一排（样机 .capbottom）：小图标工具 + 类型 chip ｜ 取消 + 纸飞机。
    private var captureActions: some View {
        HStack(spacing: 4) {
            captureTool(.link, icon: "link")
            captureTool(.fileReference, icon: "file")
            captureTool(.screenshot, icon: "scan")
            captureTool(.voice, icon: "mic")

            captureDestinationChip
                .padding(.leading, 6)

            captureTagChip
                .padding(.leading, 6)

            Spacer(minLength: 12)

            Button(UserFacingCopy.cancel) { discardDraft() }
                .buttonStyle(LightAnchorInlineButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
            Button {
                _ = save()
            } label: {
                LightAnchorIcon("arrow-up", size: 14)
                    .frame(width: 46, height: 32)
                    .foregroundStyle(LightAnchorTheme.onAction)
                    .background(
                        LightAnchorTheme.primaryAction,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(CaptureSendButtonStyle())
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isCapturingScreenshot)
            .opacity(isCapturingScreenshot ? 0.4 : 1)
            .help(tr("return_to_where_you_were_after"))
            .accessibilityLabel(UserFacingCopy.save)
        }
    }

    /// 无描边小图标工具（样机 .ictool）：30×30、圆角 8，点选对应捕获方式。
    private func captureTool(_ option: CaptureKind, icon: String) -> some View {
        let isSelected = option == kind
        return Button {
            // 类型 chip 已让位给去向：再点一次选中的图标 = 回到「想法」。
            kind = isSelected ? .text : option
        } label: {
            LightAnchorIcon(icon, size: 16)
                .foregroundStyle(isSelected ? LightAnchorTheme.ink : LightAnchorTheme.mutedInk)
                .frame(width: 30, height: 30)
                .background(
                    isSelected ? LightAnchorTheme.recessed : LightAnchorThemeColor.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .lightAnchorHoverFill(cornerRadius: 8, isActive: !isSelected)
        .help(UserFacingCopy.captureKind(option))
        .accessibilityLabel(UserFacingCopy.captureKind(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 类型 chip（样机 .typechip「想法 ▾」）：菜单里列出全部捕获方式。
    /// 去向 chip（原类型 chip 的位置和骨架）：稍后 / 暂存箱，菜单勾选。
    /// 捕获方式由左边四个图标承担（再点一次选中的图标回到「想法」）。
    private var captureDestinationChip: some View {
        Menu {
            Picker(tr("save_to"), selection: $destination) {
                Text(tr("later")).tag(CaptureStatus.inbox)
                Text(tr("reference")).tag(CaptureStatus.reference)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(LightAnchorTheme.primary)
                    .frame(width: 7, height: 7)
                Text(destination == .reference ? tr("reference") : tr("later"))
                    .font(LightAnchorTheme.controlFont(size: 12, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                LightAnchorIcon("chevron-down", size: 8)
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                LightAnchorTheme.recessed,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LightAnchorTheme.sidebarHairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tr("save_to"))
        .accessibilityValue(destination == .reference ? tr("reference") : tr("later"))
    }

    /// 标签 chip（与 typechip 同语言）：无标签时是「# 标签」灰字入口，
    /// 选了标签后显示 #名字；点开弹窗挑现有标签或敲一个新的。
    private var captureTagChip: some View {
        Button {
            showingTagPicker = true
        } label: {
            HStack(spacing: 6) {
                Text(tagChipTitle)
                    .font(LightAnchorTheme.controlFont(size: 12, weight: .medium))
                    .foregroundStyle(selectedTags.isEmpty ? LightAnchorTheme.mutedInk : LightAnchorTheme.accentInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                selectedTags.isEmpty ? LightAnchorTheme.recessed : LightAnchorTheme.accentWash,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selectedTags.isEmpty ? LightAnchorTheme.sidebarHairline : LightAnchorThemeColor.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingTagPicker, arrowEdge: .top) {
            LightAnchorTagPicker(
                selected: $selectedTags,
                knownTags: workspace.snapshot.allCaptureTags
            )
        }
        .help(tr("tags"))
        .accessibilityLabel(
            selectedTags.isEmpty
                ? tr("add_tag")
                : String(format: tr("tags_are"), selectedTags.joined(separator: "、"))
        )
    }

    private var tagChipTitle: String {
        if selectedTags.isEmpty { return tr("tags_2") }
        let shown = selectedTags.prefix(2).map { "#\($0)" }.joined(separator: " ")
        return selectedTags.count > 2 ? "\(shown) +\(selectedTags.count - 2)" : shown
    }

    @ViewBuilder
    private var inputView: some View {
        switch kind {
        case .text:
            // 开放写字板：光标直接落在卡面上，无输入框描边（V7）。
            TextField(tr("write_down_what_s_on_your"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(LightAnchorTheme.interfaceFont(size: 15.5))
                .lineLimit(3...6)
                .focused($focused)
                .accessibilityLabel(tr("the_thought"))
                .onSubmit { _ = save() }

        case .link:
            TextField(tr("paste_a_link_e_g_https"), text: $linkText)
                .textFieldStyle(.plain)
                .font(LightAnchorTheme.interfaceFont(size: 15))
                .focused($focused)
                .accessibilityLabel(tr("link"))
                .onSubmit { _ = save() }

        case .fileReference:
            HStack {
                LightAnchorIcon("file", size: 17)
                Text(selectedFileURL?.path ?? tr("no_file_chosen_yet"))
                    .foregroundStyle(selectedFileURL == nil ? LightAnchorTheme.mutedInk : LightAnchorTheme.ink)
                    .lineLimit(2)
                Spacer()
                Button(tr("choose_file")) { showingFileImporter = true }
                    .buttonStyle(LightAnchorQuietButtonStyle())
            }

        case .screenshot:
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    captureScreenshot()
                } label: {
                    LightAnchorLabel(
                        title: isCapturingScreenshot ? tr("waiting_for_area_selection") : tr("select_screenshot_area"),
                        icon: "scan"
                    )
                }
                .buttonStyle(LightAnchorQuietButtonStyle())
                if screenshotData != nil {
                    LightAnchorLabel(title: tr("screenshot_ready"), icon: "circle-check")
                        .foregroundStyle(LightAnchorTheme.accentInk)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("note_optional"))
                        .font(LightAnchorTheme.controlFont())
                        .foregroundStyle(LightAnchorTheme.secondaryInk)
                    TextField(tr("e_g_keep_the_error_message"), text: $text, axis: .vertical)
                        .textFieldStyle(LightAnchorTextFieldStyle())
                        .lineLimit(2...4)
                        .accessibilityLabel(tr("note_optional"))
                }
            }

        case .voice:
            #if os(macOS)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if isRecordingVoice {
                        stopVoiceCapture()
                    } else {
                        startVoiceCapture()
                    }
                } label: {
                    LightAnchorLabel(
                        title: isRecordingVoice ? tr("stop_recording") : tr("start_recording"),
                        icon: isRecordingVoice ? "circle-stop" : "mic"
                    )
                }
                .buttonStyle(LightAnchorQuietButtonStyle())
                if let voiceResult {
                    LightAnchorLabel(title: tr("voice_transcribed"), icon: "circle-check")
                        .foregroundStyle(LightAnchorTheme.accentInk)
                    Text(voiceResult.transcript)
                        .textSelection(.enabled)
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
            }
            #else
            EmptyView()
            #endif
        }
    }

    private var draftValidationMessage: String? {
        if isCapturingScreenshot {
            return tr("finish_selecting_the_screenshot_area_before")
        }
        return switch kind {
        case .text:
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? tr("write_down_what_to_save")
                : nil
        case .link:
            LinkCaptureParser().parse(linkText) == nil
                ? tr("enter_a_full_link_e_g")
                : nil
        case .fileReference:
            selectedFileURL == nil ? tr("choose_the_file_to_save") : nil
        case .screenshot:
            screenshotData == nil ? tr("select_a_screenshot_area_first") : nil
        case .voice:
            if isRecordingVoice {
                tr("finish_the_recording_before_saving_the")
            } else {
                voiceResult == nil ? tr("start_and_finish_a_recording_before") : nil
            }
        }
    }

    private func captureScreenshot() {
        isCapturingScreenshot = true
        errorMessage = nil
        Task {
            do {
                screenshotData = try await MacScreenshotCapture().captureSelection()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCapturingScreenshot = false
        }
    }

    #if os(macOS)
    private func startVoiceCapture() {
        errorMessage = nil
        Task {
            let permissionService = PrivacyPermissionService()
            guard await permissionService.request(.microphone) == .granted,
                  await permissionService.request(.speechRecognition) == .granted
            else {
                errorMessage = tr("needs_microphone_and_speech_recognition_permissions")
                return
            }
            do {
                let session = try MacVoiceCaptureSession()
                try session.start()
                voiceSession = session
                isRecordingVoice = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopVoiceCapture() {
        guard let voiceSession else { return }
        Task {
            do {
                voiceResult = try await voiceSession.stop()
                isRecordingVoice = false
            } catch {
                voiceSession.cancel()
                self.voiceSession = nil
                isRecordingVoice = false
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    @discardableResult
    private func save() -> Bool {
        validationMessage = draftValidationMessage
        guard validationMessage == nil else {
            if kind == .text || kind == .link {
                focused = true
            } else {
                validationAccessibilityFocused = true
            }
            return false
        }

        let context = currentContext()
        let application = context.applications.first
        let window = context.windows.first
        let capture: CaptureItem?
        switch kind {
        case .text:
            capture = workspace.captureText(
                text,
                sourceApplication: application,
                sourceWindowTitle: window,
                destination: destination
            )
        case .link:
            guard let url = LinkCaptureParser().parse(linkText) else {
                errorMessage = tr("enter_a_valid_link")
                return false
            }
            capture = workspace.captureLink(
                url,
                sourceApplication: application,
                sourceWindowTitle: window,
                destination: destination
            )
        case .fileReference:
            guard let selectedFileURL else {
                errorMessage = tr("choose_a_file_to_save")
                return false
            }
            capture = workspace.captureFileReference(
                selectedFileURL,
                sourceApplication: application,
                sourceWindowTitle: window,
                destination: destination
            )
        case .screenshot:
            guard let screenshotData else {
                errorMessage = tr("select_a_screenshot_area_first")
                return false
            }
            capture = workspace.captureScreenshot(
                data: screenshotData,
                note: text,
                sourceApplication: application,
                sourceWindowTitle: window,
                destination: destination
            )
        case .voice:
            if let voiceResult {
                capture = workspace.captureVoice(
                    transcript: voiceResult.transcript,
                    audioFileURL: voiceResult.audioURL,
                    duration: voiceResult.duration,
                    sourceApplication: application,
                    sourceWindowTitle: window,
                    destination: destination
                )
            } else {
                capture = nil
            }
        }
        guard let capture else {
            errorMessage = workspace.lastError ?? tr("save_failed_try_again_later")
            return false
        }
        if !selectedTags.isEmpty {
            _ = workspace.setCaptureTags(capture.id, tags: selectedTags)
        }
        #if os(macOS)
        if let voiceURL = voiceResult?.audioURL {
            try? FileManager.default.removeItem(at: voiceURL)
        }
        #endif
        CaptureDraftCoordinator.shared.end(draftID: draftID)
        closeCapture()
        #if os(macOS)
        // 「保存后回到原上下文」由设置页开关控制（样机 setrow，默认开）。
        if UserDefaults.standard.object(
            forKey: LightAnchorCaptureReturnPreference.storageKey
        ) as? Bool ?? true {
            returnFocusToSourceApplication()
        }
        #endif
        return true
    }

    private func discardDraft() {
        #if os(macOS)
        voiceSession?.cancel()
        if let voiceURL = voiceResult?.audioURL {
            try? FileManager.default.removeItem(at: voiceURL)
        }
        #endif
        CaptureDraftCoordinator.shared.discard(draftID: draftID)
        closeCapture()
    }

    private func closeCapture() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func handleDraftContentChange() {
        validationMessage = nil
        validationAccessibilityFocused = false
        updateDraftState()
    }

    private func updateDraftState() {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedFileURL != nil
            || screenshotData != nil
            || voiceResult != nil
            || isRecordingVoice
        CaptureDraftCoordinator.shared.update(
            draftID: draftID,
            hasUnsavedContent: hasContent
        )
    }

    private func currentContext() -> ContextCapsule {
        sourceContext
    }

    #if os(macOS)
    /// 把焦点还给捕获前那个应用。捕获窗刚关，等一帧再激活，否则窗口关闭本身
    /// 会把焦点再抢回来。失败只记诊断、不弹提示：这时用户已经在别的应用里干活，
    /// 一条回不到工作区的提示只会晚点冒出来打断人。
    private func returnFocusToSourceApplication() {
        let processIdentifier = sourceProcessIdentifier
        let bundleIdentifier = sourceApplicationBundleIdentifier
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            let returned = MacContextRestorer().returnFocus(
                toProcessIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            guard !returned else { return }
            let name = bundleIdentifier ?? "unknown"
            LocalDiagnostics.shared.record(
                operation: "context.return.after-capture",
                message: "回不到捕获前的应用：\(name)"
            )
        }
    }
    #endif

    private func loadSourceContext() {
        #if os(macOS)
        if let observation = CaptureContextStore.shared.consume() {
            sourceContext = observation.capsule
            sourceApplicationBundleIdentifier = observation.sourceApplicationBundleIdentifier
            sourceProcessIdentifier = observation.sourceProcessIdentifier
            contextLimitations = observation.limitations
            return
        }
        let observation = MacContextRecorder().capture(
            options: ContextCaptureOptions(preferences: .load())
        )
        sourceContext = observation.capsule
        sourceApplicationBundleIdentifier = observation.sourceApplicationBundleIdentifier
        sourceProcessIdentifier = observation.sourceProcessIdentifier
        #else
        sourceContext = ContextCapsule()
        #endif
    }
}

/// 样机 .sendbtn：hover 提亮 5%、按下缩到 .96、常驻蓝影。
private struct CaptureSendButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .shadow(color: .init(red: 91/255, green: 167/255, blue: 206/255).opacity(0.40), radius: 4, y: 2)
            .brightness(isHovered ? 0.05 : 0)
            // reduceMotion 全静态：这是全 app 唯一漏接的按压缩放，补齐与 Theme 一致。
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct CaptureWindowChromeModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .background(LightAnchorWindowConfigurator(chrome: .capture))
        } else {
            content
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.lightAnchorPalette) private var palette

    var body: some View {
        // 分钟数每分钟自己走（与主窗同一处理）。
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            menuBarContent
        }
    }

    private var menuBarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 当前状态行（样机 .cur）：蓝点 + 粗体任务名 + 右侧时长。
            currentStatusRow
                .padding(.bottom, 3)

            // 快捷按钮（样机 .mbtns .btn { flex:1 }）：标签先撑满再套按钮
            // 样式，单键时也占整行，不会缩成一枚窄药丸。
            HStack(spacing: 6) {
                Button {
                    openCaptureWindow()
                } label: {
                    Text(tr("capture_a_thought")).frame(maxWidth: .infinity)
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                if let episode = workspace.currentEpisode {
                    if episode.state == .active {
                        Button {
                            _ = workspace.pauseEpisode(episode.id, returnCue: episode.returnCue)
                        } label: {
                            Text(tr("set_aside")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    } else if episode.state == .paused {
                        Button {
                            _ = workspace.resumeEpisode(episode.id)
                        } label: {
                            Text(tr("continue")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)

            // 三行计数（样机 .mline）：宜绿「可以返回」/ 暖黄虚线「等结果中」/ 稍后。
            // 计数走 WaitingSurfaceSnapshot 投影，别在这里重算一遍过滤条件。
            let surface = workspace.snapshot.waitingSurface
            let readyCount = surface.readyCount
            let waitingCount = surface.waitingCount
            let inboxCount = workspace.snapshot.inbox.count

            if readyCount > 0 {
                countLine(
                    dot: Circle().fill(LightAnchorTheme.successBadge),
                    title: tr("ready_to_return"),
                    count: readyCount,
                    tint: LightAnchorDesign.success,
                    countTint: LightAnchorDesign.success
                )
            }
            if waitingCount > 0 {
                countLine(
                    dot: Circle().stroke(
                        LightAnchorTheme.warning,
                        style: StrokeStyle(lineWidth: 2, dash: [2.4, 2.4])
                    ),
                    title: tr("waiting_for_result"),
                    count: waitingCount,
                    tint: LightAnchorTheme.ink,
                    countTint: LightAnchorTheme.ink
                )
            }
            if inboxCount > 0 {
                countLine(
                    dot: Circle().fill(LightAnchorTheme.faintInk),
                    title: tr("inbox"),
                    count: inboxCount,
                    tint: LightAnchorTheme.ink,
                    countTint: LightAnchorTheme.accentInk
                )
            }

            // 打开工作区（样机 .open）：靠左文字键。
            Button {
                openWindow(id: "main")
            } label: {
                Text(tr("open_workspace_2"))
                    .font(LightAnchorTheme.interfaceFont(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarOpenButtonStyle())
            .padding(.top, 8)
            .padding(.horizontal, 2)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 264)
        .foregroundStyle(LightAnchorTheme.ink)
        .background(LightAnchorTheme.windowBackground)
        .tint(palette.color(for: .primary))
        .accentColor(palette.color(for: .primary))
    }

    @ViewBuilder
    private var currentStatusRow: some View {
        if let episode = workspace.currentEpisode,
           let target = workspace.snapshot.targets[episode.targetID] {
            HStack(spacing: 9) {
                LightAnchorStatusDot(episode.state, size: 8)
                Text(target.name)
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(durationLabel(for: episode))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            // 点形态对旁白不可见（accessibilityHidden 的几何绘制），
            // 把状态补成行的可及值，「等待→可以返回」才听得到。
            .accessibilityElement(children: .combine)
            .accessibilityValue(UserFacingCopy.waitingState(episode.state))
        } else {
            HStack(spacing: 9) {
                LightAnchorStatusDot(LightAnchorStatusDotForm.paused, size: 8)
                Text(tr("nothing_in_progress_2"))
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Spacer(minLength: 0)
            }
        }
    }

    private func countLine(
        dot: some View,
        title: String,
        count: Int,
        tint: LightAnchorThemeColor,
        countTint: LightAnchorThemeColor
    ) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
            HStack(spacing: 8) {
                dot
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: tint == LightAnchorTheme.ink ? .regular : .medium))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(LightAnchorTheme.interfaceFont(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(countTint)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 2)
        }
    }

    private func durationLabel(for episode: AttentionEpisode) -> String {
        UserFacingCopy.focusDuration(workspace.snapshot.focusMinutes(of: episode.id))
    }

    private func openCaptureWindow() {
        #if os(macOS)
        CaptureContextStore.shared.prepare()
        #endif
        openWindow(id: "capture")
    }
}

/// 菜单栏浮窗底部「打开工作区 →」：muted 文字，悬停转正文墨色（样机 .open）。
private struct MenuBarOpenButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isHovered || configuration.isPressed
                    ? LightAnchorTheme.ink
                    : LightAnchorTheme.mutedInk
            )
            .onHover { isHovered = $0 }
    }
}
