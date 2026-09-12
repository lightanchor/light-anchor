import Foundation
import XCTest
@testable import LightAnchor

/// Blue Dot（暖白 V7）设计语言的 UI 审计。
///
/// 结构分三组：
/// 1. 流程守卫 —— 保证核心入口与路径在重构中不丢失（对应旧 UIControlAuditTests
///    中真正保护行为的断言，按新结构重写）。
/// 2. 设计规则 —— 蓝点识别体系、语义色、动效降级、克制的阴影。
/// 3. 打包与伴生应用 —— 与设计无关、原样保留的安装性检查。
final class BlueDotAuditTests: XCTestCase {

    // MARK: - 1. 流程守卫

    func testWorkspaceUsesStaticTwoPaneShellAndDockIsland() throws {
        let source = try mainWorkspaceSource()

        // 样机 .win：固定 226pt 侧栏 + 舞台的静态双栏。不用
        // NavigationSplitView——它自带的分栏线/拖拽柄样机里没有，
        // 其安全区管理还会和 ignoresSafeArea 互相触发布局死循环。
        XCTAssertFalse(source.contains("NavigationSplitView("))
        // 侧栏内容固定 226pt 排版；收进蓝点时外层宽度收拢到 0（经典分栏收拢）。
        XCTAssertTrue(source.contains(".frame(width: LightAnchorDesign.sidebarWidth, alignment: .leading)"))
        // 现场舱（样机 .dock）：内容岛旁 258pt 的第二座圆角岛，推拉进出。
        XCTAssertTrue(source.contains("if showingInspector {"))
        XCTAssertTrue(source.contains("WorkspaceContextRail("))
        XCTAssertTrue(source.contains(".frame(width: 258)"))
        XCTAssertTrue(source.contains("private var workspaceSidebar"))
        XCTAssertTrue(source.contains("attentionDestinations"))
        XCTAssertTrue(source.contains("toolDestinations"))
    }

    func testWorkspaceSplitViewStaysBoundedByTheWindowWhenContentExpands() throws {
        let source = try mainWorkspaceSource()
        let body = try XCTUnwrap(
            source.slice(from: "private var workspaceShell", to: "private var workspaceSidebar")
        )

        XCTAssertTrue(body.contains("minWidth: 980"))
        XCTAssertTrue(body.contains("maxWidth: .infinity"))
        XCTAssertTrue(body.contains("maxHeight: .infinity"))
    }

    func testWorkspaceSidebarKeepsNavigationGroupsInTheViewport() throws {
        let source = try mainWorkspaceSource()
        let sidebar = try XCTUnwrap(
            source.slice(from: "private var workspaceSidebar", to: "private func workspaceNavigationRow")
        )

        XCTAssertFalse(sidebar.contains("ScrollView {"))
        XCTAssertTrue(sidebar.contains("maxHeight: .infinity, alignment: .topLeading"))
    }

    func testWorkspaceRestoresAllThreeWindowControls() throws {
        let source = try source(at: "Sources/LightAnchor/Design/LightAnchorWindowChrome.swift")

        XCTAssertTrue(source.contains("NSWindow.ButtonType.closeButton"))
        XCTAssertTrue(source.contains(".miniaturizeButton"))
        XCTAssertTrue(source.contains(".zoomButton"))
        XCTAssertTrue(source.contains("window.standardWindowButton(button)?.isHidden = false"))
    }

    func testCurrentWorkDetailsAreReachableFromInspector() throws {
        let source = try mainWorkspaceSource()
        let rail = try XCTUnwrap(
            source.slice(from: "private struct WorkspaceContextRail", to: "struct LightAnchorDockHead")
        )

        XCTAssertTrue(rail.contains("WorkDetailsView(target: target, episode: episode"))
        // 现在页的详情按钮必须清掉过期的搜索选择并打开现场舱。
        XCTAssertTrue(source.contains("selectedSearchResult = nil"))
        XCTAssertTrue(source.contains("showingInspector = true"))
    }

    func testSearchRoutesToDestinationScopeAndInspector() throws {
        let source = try mainWorkspaceSource()
        let route = try XCTUnwrap(
            source.slice(from: "private func routeSearchResult", to: "private func restoreWaitingContext")
        )

        XCTAssertTrue(route.contains("selectedSearchResult = result"))
        XCTAssertTrue(route.contains("selectedDestination = result.destination"))
        XCTAssertTrue(route.contains("showingInspector = true"))
    }

    func testSearchOverlayIsCenteredGroupedAndDismissible() throws {
        let source = try mainWorkspaceSource()

        XCTAssertTrue(source.contains("private var workspaceSearchOverlay"))
        XCTAssertTrue(source.contains("groupedSearchResults"))
        XCTAssertTrue(source.contains(".onExitCommand { closeWorkspaceSearch() }"))
        XCTAssertTrue(source.contains(#"keyboardShortcut("f", modifiers: [.command])"#))
        XCTAssertFalse(source.contains(".searchable(text:"), "搜索是居中浮层，不是导航栏搜索框")
    }

    /// 「等待结果」只有一个入口：现在页那条动作条。等待页连同它自己那颗
    /// 「添加一个等待」一起没了——同一个动作两处入口，用户学两遍。
    func testManualWaitingHasASingleEntryPoint() throws {
        let source = try mainWorkspaceSource()
        // 入口住在「现在」页那条浮岛动作条上（NowPageView），别处一处也没有。
        let nowPage = try self.source(at: "Sources/LightAnchor/Views/NowPageView.swift")
        XCTAssertEqual(
            try matches(of: #"UserFacingCopy\.waitForResult"#, in: nowPage), 1
        )
        // 那颗按钮不许在别处再长一遍（清理台里那个只是行动名，不是入口）。
        XCTAssertEqual(
            try matches(of: #"Button\(UserFacingCopy\.waitForResult"#, in: source), 0
        )
        XCTAssertFalse(source.contains(#"tr("add_a_wait")"#), "等待页那颗入口应随页面一起删掉")
        XCTAssertFalse(source.contains("WaitingSpaceView"), "等待不再是一个页面")
    }

    /// 等待不再是一个去处：清单只有一张，分组问的是「下一步在谁手里」。
    func testWaitingIsNotADestinationOfItsOwn() throws {
        XCTAssertFalse(
            WorkspaceDestination.allCases.contains { $0.rawValue == "waiting" },
            "等待不该再占一个顶层导航项"
        )
        XCTAssertEqual(
            WorkspaceDestination.allCases.map(\.rawValue),
            ["now", "later", "environments", "review", "chat"]
        )
    }

    /// 稍后页按归属分两组，且「等着别人」默认收着——你扫这张清单是为了
    /// 挑一件事做，今天挑不了的那几条不该占视线。
    func testLaterPageGroupsByWhoseCourtTheBallIsIn() throws {
        let source = try mainWorkspaceSource()
        let later = try XCTUnwrap(
            source.slice(from: "private struct LaterSpaceView", to: "private struct LaterCaptureList")
        )

        // 分组口径走同一份投影，不在视图里重算过滤条件。
        XCTAssertTrue(later.contains("workspace.snapshot.laterList"))
        XCTAssertTrue(later.contains("laterList.actionable"))
        XCTAssertTrue(later.contains("laterList.blocked"))
        XCTAssertTrue(later.contains(#"tr("later_group_actionable")"#))
        XCTAssertTrue(later.contains(#"tr("later_blocked_summary")"#))
        // 默认收着。
        XCTAssertTrue(later.contains("@State private var blockedExpanded = false"))
        // 折起来那行的尾巴要报最久的一条，收着也知道里面有没有火。
        XCTAssertTrue(later.contains("laterList.blockedLead"))
        // 「结果到了」不单开一组，它是「可以动」里的一个标记。
        XCTAssertTrue(later.contains(#"tr("later_result_arrived")"#))
    }

    /// 「你自己搁下的」这句只属于「可以动」那一组：它就是和「等着别人」的分界线。
    func testActionableGroupNamesTheUserHeldSide() throws {
        let source = try mainWorkspaceSource()
        let group = try XCTUnwrap(
            source.slice(from: "private var actionableSection", to: "private func actionableRow")
        )
        XCTAssertTrue(group.contains(#"tr("later_group_actionable")"#))
        XCTAssertTrue(group.contains(#"tr("you_set_these_aside_yourself_come")"#))
    }

    /// 「换一件事」是**挑一件已有的**：接着做放下的事、从稍后拿一条、
    /// 或者把打好的名字交出去新开一件。它自己不建目标——凭空立一件事要交代的
    /// 期限和开工环境，这个面板问不了（它的右区是给交接用的，新事没有现场可交接）。
    func testSwitchingWorkPicksFromWhatExistsAndHandsOffNewOnes() throws {
        let panel = try source(at: "Sources/LightAnchor/Views/SwitchWorkPanel.swift")
        XCTAssertTrue(panel.contains("setAsideEpisodes"), "接着做：放下的未完成事")
        XCTAssertTrue(panel.contains("snapshot.inbox"), "从稍后拿一条")
        XCTAssertTrue(panel.contains("startEpisode(targetID:"))
        XCTAssertTrue(panel.contains("createTargetFromCapture("))
        XCTAssertTrue(panel.contains("onCreateNew(name)"), "新开一件：名字交给开始一件事")
        XCTAssertFalse(
            panel.contains("createTarget(name:"),
            "面板不许自己建目标——那条路绕开了期限和环境"
        )

        let source = try mainWorkspaceSource()
        let nowPage = try self.source(at: "Sources/LightAnchor/Views/NowPageView.swift")
        let actions = try XCTUnwrap(
            nowPage.slice(from: "struct NowActionDock", to: "private struct NowDockItem")
        )
        XCTAssertTrue(
            actions.contains(#"tr("switch_to_something_else")"#),
            "有当前工作时，动作条上必须能直接换一件事"
        )
        // 开始一件事和换一件事走两个界面：一个是声明，一个是选择。
        XCTAssertEqual(try matches(of: #"onStart: \{ openStartWork\(\) \}"#, in: source), 1)
        XCTAssertEqual(try matches(of: #"onSwitch: openSwitchWork"#, in: source), 1)
    }

    /// 「现在」页是**一整页顺着读**：这件事 → 上次做到哪 → 东西在哪，右缘一条小轨。
    /// 三个并列页签那版被否过好几轮，不许回头。
    func testNowPageIsOneLongPageWithARailNotThreeTabs() throws {
        let page = try source(at: "Sources/LightAnchor/Views/NowPageView.swift")

        XCTAssertEqual(
            NowChapter.allCases.map(\.rawValue),
            ["task", "summary", "items"],
            "三节的顺序就是读的顺序"
        )
        // 一个滚动容器 + 三节 + 一条小轨；小轨跟着滚动高亮。
        XCTAssertEqual(try matches(of: #"ScrollView \{"#, in: page), 2, "长页一个、空状态一个")
        XCTAssertTrue(page.contains("chapterBody(.task)"))
        XCTAssertTrue(page.contains("chapterBody(.summary)"))
        XCTAssertTrue(page.contains("chapterBody(.items)"))
        XCTAssertTrue(page.contains("private func recomputeChapter()"), "读到哪一节，小轨就亮哪一条")
        XCTAssertTrue(page.contains("struct NowRail"))
        // 总结和现场跟着同一个「第几段」走——它们是同一段的两面。
        XCTAssertTrue(page.contains("selectedSegment(of: target)"))
        XCTAssertEqual(try matches(of: #"@State private var segmentIndex"#, in: page), 1)
        XCTAssertFalse(page.contains("TabView"), "页签那版被否了")
        XCTAssertFalse(page.contains("Picker("), "分段控件同样被否")
    }

    /// 「换一件事」右区是**两块等高的方块**（白卡 + 浅蓝块）；邮票整套已经取消。
    func testSwitchWorkPanelShowsTwoEqualBlocksNotAStamp() throws {
        let panel = try source(at: "Sources/LightAnchor/Views/SwitchWorkPanel.swift")

        XCTAssertTrue(panel.contains("SwitchWorkBlock(\n            tone: .now,"))
        XCTAssertTrue(panel.contains("tone: .destination,"))
        XCTAssertTrue(panel.contains("private var blockHeight: CGFloat"), "两块共用一个高度")
        XCTAssertEqual(try matches(of: #"height: blockHeight"#, in: panel), 4, "两块 + 箭头 + 空态")
        // 邮票：齿孔、面值、内框、撕边复写条，全部不许回来。
        for gone in ["SwitchWorkStamp", "SwitchWorkPerforation", "SwitchWorkTornTeeth", "lightAnchorStampShadow"] {
            XCTAssertFalse(panel.contains(gone), "邮票残留：\(gone)")
        }
        // 现场与「现在」页同源：两张白卡 + 同一个清单网格，不再按类别分组。
        XCTAssertTrue(panel.contains("SceneThingsGrid("))
        XCTAssertTrue(panel.contains("NowCard {"))
        XCTAssertFalse(panel.contains("sceneGroupHeader("), "现场清单不再分组")
    }

    /// 「开始一件事」照的是随手记那个窗的骨架，不是设置对话框：先聚焦必填名称，
    /// 底下一排安静的 chip，右边是明确的启动动作。期限就是其中一颗 chip。
    func testStartingWorkLooksLikeTheCaptureWindowNotASettingsSheet() throws {
        let source = try mainWorkspaceSource()
        let sheet = try XCTUnwrap(
            source.slice(from: "struct StartWorkView: View", to: "private func start()")
        )
        XCTAssertTrue(sheet.contains("dueAt: $dueAt"), "创建时就能押期限")
        XCTAssertTrue(sheet.contains(#"placeholder: tr("no_rush")"#), "空着自己会说话")
        XCTAssertTrue(sheet.contains("chip: true"), "期限是底栏上的一颗 chip")
        XCTAssertTrue(sheet.contains(".textFieldStyle(.plain)"), "开放写字板，无描边")
        XCTAssertTrue(sheet.contains(".onSubmit(start)"), "打完名字回车就开始")
        XCTAssertTrue(sheet.contains(#"Button(tr("start_something"), action: start)"#), "启动动作必须说清楚")
        // 不许再退回设置对话框那套：头部铺垫、表单行、「更多」三角、开关+字段两步。
        XCTAssertFalse(sheet.contains("LightAnchorSheetHeader"), "便笺不要四行头部铺垫")
        XCTAssertFalse(sheet.contains("LightAnchorSettingsSection"))
        XCTAssertFalse(sheet.contains("LightAnchorDisclosure"))
        XCTAssertFalse(sheet.contains("hasDeadline"))
        // 便笺里不该出现选择器那套东西。
        XCTAssertFalse(sheet.contains("candidateRows"))
        XCTAssertFalse(sheet.contains("SwitchWork"))
    }

    /// 期限那一格只挑日子：押的是日期，「周五 23:51」里那个 23:51 是噪声。
    func testDeadlineFieldPicksADayNotAMoment() throws {
        let theme = try source(at: "Sources/LightAnchor/Design/LightAnchorTheme.swift")
        XCTAssertTrue(theme.contains("private var isDueMode: Bool"))
        XCTAssertTrue(theme.contains(#"tr("no_deadline_after_all")"#), "面板里能撤掉期限")
        XCTAssertTrue(
            theme.contains("bySettingHour: 23, minute: 59"),
            "期限落在那天末尾：周五要交是周五结束前"
        )
    }

    /// 展开「等着别人」时组头行不许变高——点一下，你点的那一行自己长高了，
    /// 手感像跳了一下。
    func testBlockedHeaderKeepsItsHeightWhenExpanded() throws {
        let source = try mainWorkspaceSource()
        let header = try XCTUnwrap(
            source.slice(from: "private var blockedHeader", to: "private var blockedDot")
        )
        XCTAssertFalse(
            header.contains("if showsBlocked {"),
            "组头行里不许有随展开出现的第二行"
        )
        XCTAssertTrue(header.contains("blockedSummary"))
    }

    func testLaterWorkspaceSurfacesBothScopes() throws {
        let source = try mainWorkspaceSource()

        XCTAssertTrue(source.contains("LaterScope.allCases"))
        XCTAssertTrue(source.contains("LaterCaptureList("))
    }

    func testCaptureUsesAStatefulComposerAndVisibleCaptureModes() throws {
        let source = try mainWorkspaceSource()
        let capture = try XCTUnwrap(
            source.slice(from: "struct CaptureView", to: "private struct CaptureWindowChromeModifier")
        )

        // 捕获方式由底排四个图标承担（类型 chip 已让位给去向 chip，2026-08-24）。
        XCTAssertTrue(capture.contains("captureTool(.link"))
        XCTAssertTrue(capture.contains("captureTool(.voice"))
        XCTAssertTrue(capture.contains("captureDestinationChip"))
        XCTAssertTrue(capture.contains("draftValidationMessage"))
        XCTAssertTrue(capture.contains("CaptureDraftCoordinator.shared.begin()"))
        XCTAssertTrue(capture.contains("CaptureDraftCoordinator.shared.end(draftID: draftID)"))
        XCTAssertTrue(capture.contains("requestCaptureDraftTerminationDecision"))
    }

    /// 保存后回焦只把焦点还给捕获前那个应用。走整套 `restore(_:)` 会按现场清单
    /// 逐个激活应用、并打开里面的文件和链接——随手捕获之后不该把桌面翻乱。
    func testCaptureReturnsFocusToTheSourceApplicationOnlyAfterSaving() throws {
        let source = try mainWorkspaceSource()

        XCTAssertTrue(source.contains("CaptureContextStore.shared.prepare()"))
        XCTAssertTrue(source.contains("returnFocusToSourceApplication()"))
        XCTAssertTrue(source.contains("toProcessIdentifier: processIdentifier"))
        XCTAssertFalse(source.contains("MacContextRestorer().restore(contextToRestore)"))
    }

    func testDeniedPermissionsRouteToSystemSettingsInsteadOfRepeatingAuthorization() throws {
        let source = try source(at: "Sources/LightAnchor/Views/PrivacyView.swift")

        XCTAssertTrue(source.contains(#"tr("open_system_settings")"#))
        XCTAssertTrue(source.contains(".denied"))
    }

    func testSettingsWindowKeepsCommandEntryAndRestoresPane() throws {
        let appSource = try source(at: "Sources/LightAnchor/App/LightAnchorApp.swift")
        let settingsSource = try source(at: "Sources/LightAnchor/Views/WorkspaceSettingsView.swift")

        // 设置窗是 hiddenTitleBar 的普通 Window 场景（样机 setwin：暖色标头
        // 直通窗顶）；Settings 场景做不到。⌘, 与菜单项挂在「关于」之后——
        // 绝不能用 replacing: .appSettings：它会和 SwiftUI 自动维护的设置
        // 项互相触发，release 构建下主菜单每帧重建（主线程 95%+）。
        XCTAssertTrue(appSource.contains(#"Window(tr("settings"), id: "settings")"#))
        XCTAssertTrue(appSource.contains("CommandGroup(after: .appInfo)"))
        XCTAssertFalse(appSource.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(appSource.contains(#".keyboardShortcut(",")"#))
        XCTAssertTrue(settingsSource.contains(#"@SceneStorage("settings.selectedPane")"#))
        // 样机 setwin：顶部药丸标签行替代原生 TabView 工具栏标签。
        XCTAssertTrue(settingsSource.contains("SettingsTabButtonStyle"))
        XCTAssertTrue(settingsSource.contains("ForEach(SettingsPane.allCases)"))
    }

    func testMenuBarKeepsItsCoreEntryPoints() throws {
        let source = try mainWorkspaceSource()
        let menuBar = try XCTUnwrap(
            source.slice(from: "struct MenuBarView", to: "private func openCaptureWindow")
        )

        // 样机 .mbpop：捕获想法 + 暂停 两键，可以返回/暂时放下/收件箱三行计数，
        // 底部「打开工作区 →」。退出保留在应用菜单（⌘Q）。
        XCTAssertTrue(menuBar.contains(#"tr("capture_a_thought")"#))
        // 放下当前工作的按钮和它落地的那一组同名（原来叫「暂停」）。
        XCTAssertTrue(menuBar.contains(#"tr("set_aside")"#))
        XCTAssertFalse(menuBar.contains(#"tr("pause")"#))
        XCTAssertTrue(menuBar.contains(#"tr("ready_to_return")"#))
        // 这一行数的是等待项，不是放下的事。
        XCTAssertTrue(menuBar.contains(#"tr("waiting_for_result")"#))
        XCTAssertTrue(menuBar.contains(#"tr("inbox")"#))
        XCTAssertTrue(menuBar.contains(#"tr("open_workspace_2")"#))

        let appSource = try self.source(at: "Sources/LightAnchor/App/LightAnchorApp.swift")
        XCTAssertTrue(appSource.contains("UserFacingCopy.quit"))
    }

    func testGlobalKeyboardShortcutsCoverCaptureSearchAndDestinations() throws {
        let source = try mainWorkspaceSource()

        XCTAssertTrue(source.contains(#"keyboardShortcut("n", modifiers: [.command, .option])"#))
        XCTAssertTrue(source.contains(#"keyboardShortcut("f", modifiers: [.command])"#))
        // ⌘K 换一件事：任何页面都能换，不必先回「现在」页。
        XCTAssertTrue(source.contains(#"keyboardShortcut("k", modifiers: [.command])"#))
        XCTAssertTrue(source.contains(#"keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])"#))
    }

    // MARK: - 2. Blue Dot 设计规则

    func testProductViewsUseThemeSemanticColors() throws {
        let source = try swiftSource(in: repositoryRoot.appendingPathComponent("Sources/LightAnchor/Views"))

        XCTAssertEqual(try matches(of: #"Color\(red:"#, in: source), 0)
        XCTAssertEqual(try matches(of: #"Color\(hex:"#, in: source), 0)
        XCTAssertEqual(
            try matches(of: #"Color\.(red|blue|green|yellow|orange|purple|pink|black|white)\b"#, in: source),
            0,
            "视图层只允许语义色；黑白直接量只保留在 Design 层的阴影里"
        )
    }

    func testStatusDotFormsCoverEveryEpisodeState() {
        XCTAssertEqual(LightAnchorStatusDotForm(.active), .active)
        XCTAssertEqual(LightAnchorStatusDotForm(.paused), .paused)
        XCTAssertEqual(LightAnchorStatusDotForm(.returning), .returning)
        XCTAssertEqual(LightAnchorStatusDotForm(.ended), .ended)
    }

    func testStatusDotBreathingRespectsReduceMotion() throws {
        let source = try source(at: "Sources/LightAnchor/Design/LightAnchorTheme.swift")
        // 呼吸光环跑在 CALayer（渲染服务器）上——SwiftUI repeatForever
        // 状态动画会让主线程每帧打点，动 frame 更是整窗逐帧重排到无响应。
        XCTAssertTrue(source.contains("struct LightAnchorBreathingHalo"))
        XCTAssertTrue(source.contains("CABasicAnimation"))
        XCTAssertTrue(source.contains("animated: !reduceMotion"))
        XCTAssertFalse(source.contains("repeatForever"), "呼吸动画不许用 SwiftUI repeatForever")
    }

    func testSidebarCarriesTheBlueDotIdentity() throws {
        let source = try mainWorkspaceSource()

        // 弹簧蓝点指示器 + 底部常驻状态点。
        XCTAssertTrue(source.contains(#"matchedGeometryEffect(id: "sidebar-dot""#))
        XCTAssertTrue(source.contains("private var sidebarStatusFooter"))
        XCTAssertTrue(source.contains("LightAnchorStatusDot(episode.state"))
    }

    func testWaitingSemanticsUseAlmanacGreenAndWarmAmber() throws {
        let source = try mainWorkspaceSource()

        XCTAssertTrue(source.contains("LightAnchorTheme.successBadge"), "结果到了用宜绿本色")
        XCTAssertTrue(source.contains("LightAnchorTheme.warning"), "等着别人用暖黄")
        // 过期用告警红：暖黄是「快了」，红是「已经晚了」，两件事不能同色。
        XCTAssertTrue(source.contains("LightAnchorDesign.danger"), "过期用告警色")
        // 语义色落在**点**和**字**上，不是一行挂一颗带底色的标签——
        // 每行一颗黄药丸，整张清单就花了。
        XCTAssertFalse(
            source.contains("LightAnchorTheme.warningBackground"),
            "清单行不许再用暖黄底的药丸"
        )
    }

    func testShadowsStayOnSanctionedSurfacesOnly() throws {
        // 唯一允许阴影的地方：Design 层卡片壳、主窗（搜索浮层/捕获卡）、
        // 设置窗白卡（样机 .setcard 带 shadow-1）、布局原语（圆心插画）。
        // 其余页面必须保持无阴影的平面层次。
        let flatFiles = [
            "Sources/LightAnchor/Views/DataManagementView.swift",
            "Sources/LightAnchor/Views/EnvironmentViews.swift",
            "Sources/LightAnchor/Views/IntelligenceView.swift",
            "Sources/LightAnchor/Views/UpdateSettingsView.swift",
            "Sources/LightAnchor/Views/PrivacyView.swift",
            "Sources/LightAnchor/Views/SceneViews.swift",
            "Sources/LightAnchor/Views/PersonalViews.swift"
        ]
        for path in flatFiles {
            let fileSource = try source(at: path)
            XCTAssertEqual(
                try matches(of: #"\.shadow\("#, in: fileSource),
                0,
                "\(path) 不应引入新的阴影"
            )
        }
    }

    func testThemeSystemOffersExactlyLightAndDark() {
        XCTAssertEqual(LightAnchorResolvedTheme.allCases, [.light, .dark])
        XCTAssertEqual(
            LightAnchorThemeMode.allCases,
            [.automatic, .light, .dark]
        )
    }

    @MainActor
    func testNavigationIconsUseLucideGlyphsForEveryDestination() {
        // 2026-08-22 定稿：导航图标 = Lucide 描边字形、单色跟随 foregroundStyle
        //（自绘剪影和彩色家族都已废弃）——每个去处都要有非空路径，且互不重复。
        var seen: Set<LightAnchorNavGlyph> = []
        for destination in WorkspaceDestination.allCases {
            let glyph = LightAnchorDestinationIcon.glyph(for: destination)
            XCTAssertFalse(glyph.path.isEmpty, "\(destination) 的字形是空路径")
            XCTAssertTrue(seen.insert(glyph).inserted, "\(destination) 和别的去处共用了 \(glyph.rawValue)")
        }
    }

    func testNavigationGlyphsStayInsideThe24Grid() {
        // 生成器（Scripts/import-lucide-glyphs.py）必须原样保住 24 视框：
        // 弧/二次曲线换算一旦算错，路径会溢出网格，17pt 下就会被裁掉。
        for glyph in LightAnchorNavGlyph.allCases {
            let box = glyph.path.boundingRect
            XCTAssertGreaterThanOrEqual(box.minX, -0.01, "\(glyph.rawValue) 左溢出")
            XCTAssertGreaterThanOrEqual(box.minY, -0.01, "\(glyph.rawValue) 上溢出")
            XCTAssertLessThanOrEqual(box.maxX, 24.01, "\(glyph.rawValue) 右溢出")
            XCTAssertLessThanOrEqual(box.maxY, 24.01, "\(glyph.rawValue) 下溢出")
        }
    }

    // MARK: - 3. 打包（与设计无关，原样保留）

    func testAppSmokeUsesAnIsolatedBundleIdentity() throws {
        let smokeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/smoke-macos-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(smokeSource.contains("SMOKE_BUNDLE_ID=\"com.lightanchor.smoke.$$\""))
        XCTAssertTrue(smokeSource.contains("plutil -replace CFBundleIdentifier"))
        XCTAssertTrue(smokeSource.contains("codesign --force --deep --sign -"))
    }

    func testProductUISourceUsesNativeSFSymbolsForMacOSControls() throws {
        let source = try swiftSource(in: repositoryRoot.appendingPathComponent("Sources/LightAnchor"))

        XCTAssertTrue(source.contains("systemName:"))
        XCTAssertTrue(source.contains("systemImage:"))
        XCTAssertTrue(source.contains("NSImage(systemSymbolName: systemName"))
    }

    func testProductUIUsesOnlyNativeSymbolsWithoutLucideDependency() throws {
        let paths = [
            "Package.swift",
            "Sources/LightAnchor/Design/LightAnchorTheme.swift",
            "Scripts/build-release.sh",
            "Scripts/verify-release.sh"
        ]

        for path in paths {
            let fileSource = try source(at: path)
            XCTAssertFalse(
                fileSource.range(of: "lucide", options: .caseInsensitive) != nil,
                "Lucide references must be removed from \(path)"
            )
        }

        for path in ["Package.resolved"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                "Dependency lock file should be removed when no Swift packages are used: \(path)"
            )
        }
    }

    // MARK: - 工具

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func mainWorkspaceSource() throws -> String {
        try source(at: "Sources/LightAnchor/Views/MainWorkspaceView.swift")
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func swiftSource(in directory: URL) throws -> String {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var source = ""
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            source += try String(contentsOf: fileURL, encoding: .utf8)
            source += "\n"
        }
        return source
    }

    private func matches(of pattern: String, in source: String) throws -> Int {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker)?.lowerBound,
              let end = range(of: endMarker, range: start..<endIndex)?.lowerBound
        else { return nil }
        return String(self[start..<end])
    }
}
