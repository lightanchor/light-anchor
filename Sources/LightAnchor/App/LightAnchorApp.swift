import SwiftUI

@main
struct LightAnchorApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(LightAnchorApplicationDelegate.self)
    private var applicationDelegate
    #endif

    @StateObject private var workspace: AttentionWorkspace
    @StateObject private var themeController: LightAnchorThemeController
    @AppStorage(LightAnchorMenuBarPreference.storageKey)
    private var menuBarStatusVisible = true
    /// Held directly rather than as a `@StateObject`: no view observes it, and
    /// reading a `@StateObject` from `init` yields a throwaway instance that is
    /// deallocated straight away, cancelling the maintenance loop with it.
    private let runtime: WorkspaceRuntime

    init() {
        AppLifecycleTracker.shared.start()
        let workspace = AttentionWorkspace()
        _workspace = StateObject(wrappedValue: workspace)
        AttentionActionRouter.shared.attach(workspace: workspace)
        AppEventCoordinator.shared.start()
        let themeController = LightAnchorThemeController()
        _themeController = StateObject(wrappedValue: themeController)
        runtime = WorkspaceRuntime(workspace: workspace)
        LocalDiagnostics.shared.installUncaughtExceptionHandler()
        let hotKeys = GlobalHotKeyCenter.shared
        hotKeys.onAction = { action in
            switch action {
            case .capture:
                // 必须在按键这一刻同步采：通知是异步投递的，而激活轻锚会把
                // 「刚才在用哪个应用」这个事实抹掉。
                #if os(macOS)
                CaptureContextStore.shared.prepare()
                #endif
                NotificationCenter.default.post(name: .openCaptureWindow, object: nil)
            case .openMainWindow:
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
        }
        hotKeys.start()
        if let failureMessage = hotKeys.failureMessages.values.first {
            workspace.presentNotice(failureMessage)
        }
        AppTerminationController.shared.attach(runtime: runtime)
        runtime.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWorkspaceView()
                .environmentObject(workspace)
                .environmentObject(themeController)
                .lightAnchorTheme(themeController.resolvedTheme)
                .onOpenURL { url in
                    guard let request = IncomingURLCapture().request(from: url) else { return }
                    _ = workspace.routeIncomingLink(request.url, title: request.title)
                }
        }
        .defaultSize(width: 1180, height: 760)

        Window(tr("capture_a_thought"), id: "capture") {
            CaptureView()
                .environmentObject(workspace)
                .environmentObject(themeController)
                .lightAnchorTheme(themeController.resolvedTheme)
                .tint(LightAnchorThemePalette(theme: themeController.resolvedTheme).color(for: .primary))
        }
        .defaultSize(width: 720, height: 360)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // 设置窗用普通 Window 场景而不是 Settings 场景：样机 setwin 要求
        // 暖色标头直通窗顶、红绿灯浮在暖米白上，而 Settings 场景会在每轮
        // 更新时把 titlebarAppearsTransparent 重置回 false，hiddenTitleBar
        // 对它也不生效。⌘, 与应用菜单入口在 LightAnchorCommands 里接管。
        Window(tr("settings"), id: "settings") {
            WorkspaceSettingsView()
                .environmentObject(workspace)
                .environmentObject(themeController)
                .lightAnchorTheme(themeController.resolvedTheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 640)

        // isInserted 不能直接挂 @AppStorage 投影：SwiftUI 每轮更新都会
        // 回写绑定，AppStorage 的写入又发布变更再触发更新——release
        // 构建下场景图（含主菜单）每帧重建，主线程 95%+ 直到无响应。
        // 用去重绑定切断回写环：值没变就不落盘。
        MenuBarExtra(isInserted: Binding(
            get: { menuBarStatusVisible },
            set: { newValue in
                if newValue != menuBarStatusVisible {
                    menuBarStatusVisible = newValue
                }
            }
        )) {
            MenuBarView()
                .environmentObject(workspace)
                .environmentObject(themeController)
                .lightAnchorTheme(themeController.resolvedTheme)
        } label: {
            MenuBarStatusLabel(state: menuBarMarkState)
        }
        .menuBarExtraStyle(.window)

        .commands {
            LightAnchorCommands()
        }
    }

    private var menuBarMarkState: LightAnchorMarkState {
        LightAnchorMarkState(episodeState: workspace.currentEpisode?.state)
    }
}

/// 菜单栏状态项标签：锚点标记的锚身恒定，顶上的蓝点形态即状态（实心=进行中，
/// 双环=准备返回，点环=等待，空心环=空闲/暂停）。自己画而不用 SF Symbols：
/// circle / circle.circle / circle.dotted 的视觉直径和描边各不相同，切换状态
/// 时图标会跳动，也没有品牌识别。
///
/// 顺带把 `openWindow` 交给接线员：状态项在主窗关掉之后依然活着，是「没有任何
/// 窗口」时唯一还能开窗的入口。
private struct MenuBarStatusLabel: View {
    let state: LightAnchorMarkState

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: LightAnchorMark.cachedStatusItemImage(state))
            .accessibilityLabel(tr("open_workspace"))
            // SwiftUI 的 label 会盖掉 NSImage 自带的状态描述；把「形态即状态」
            // 补成可及值，旁白用户才拿得到菜单栏点的当前状态。
            .accessibilityValue(state.menuBarAccessibilityDescription)
            .onAppear { AppEventCoordinator.shared.adopt(openWindow: openWindow) }
    }
}

extension Notification.Name {
    static let openCaptureWindow = Notification.Name("LightAnchor.openCaptureWindow")
    static let openMainWindow = Notification.Name("LightAnchor.openMainWindow")
    static let requestCaptureDraftTerminationDecision = Notification.Name(
        "LightAnchor.requestCaptureDraftTerminationDecision"
    )
}

private struct LightAnchorCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 设置入口：不能用 replacing: .appSettings——replace 会和 SwiftUI
        // 自动维护的设置菜单项互相触发，release 构建下主菜单每帧重建
        // （主线程 95%+ 直到无响应）。挂在「关于」之后即系统惯例位置。
        CommandGroup(after: .appInfo) {
            Divider()
            Button(tr("settings_2")) {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",")
        }

        CommandGroup(replacing: .appTermination) {
            Button(UserFacingCopy.quit) {
                AppTerminationController.shared.requestQuit()
            }
            .keyboardShortcut("q")
        }

        CommandMenu(tr("workspace")) {
            Button(tr("capture_a_thought")) {
                #if os(macOS)
                CaptureContextStore.shared.prepare()
                #endif
                openWindow(id: "capture")
            }
            .keyboardShortcut("n", modifiers: [.option, .command])

            Divider()

            // 「收进蓝点」：侧栏沉入呼吸蓝点/从蓝点展开（系统惯例 ⌃⌘S）。
            Button(tr("collapse_or_expand_sidebar")) {
                NotificationCenter.default.post(name: .lightAnchorToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

        }
    }
}

extension Notification.Name {
    /// 应用菜单 → 主窗：收进蓝点 / 从蓝点展开侧栏（⌃⌘S）。
    static let lightAnchorToggleSidebar = Notification.Name("LightAnchor.toggleSidebar")
}
