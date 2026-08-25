import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 设置窗（样机 setwin）：暖色标头（红绿灯 + 「设置」）+ 顶部药丸标签行，
/// 内容住在浅一档的奶油白区域里，分组白卡行式。
struct WorkspaceSettingsView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @EnvironmentObject private var themeController: LightAnchorThemeController
    @Environment(\.lightAnchorPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("settings.selectedPane") private var selectedPaneRawValue = SettingsPane.appearance.rawValue

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRawValue) ?? .appearance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标头（样机 .sethead）：标题紧跟原生红绿灯。
            Text(tr("settings"))
                .font(LightAnchorTheme.interfaceFont(size: 14, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .padding(.leading, 78)
                .padding(.top, 16)

            // 药丸标签行（样机 .settabs）。
            HStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    settingsTab(pane)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 14)

            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)

            // 内容区（样机 .setbody）：浅一档底色。
            Group {
                switch selectedPane {
                case .appearance:
                    AppearanceSettingsPane()
                case .shortcuts:
                    ShortcutSettingsPane()
                        .environmentObject(workspace)
                case .permissions:
                    PrivacyView()
                        .environmentObject(workspace)
                case .intelligence:
                    IntelligenceView()
                        .environmentObject(workspace)
                case .connections:
                    IntegrationView()
                case .data:
                    DataManagementView()
                        .environmentObject(workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LightAnchorTheme.contentBackground)
        }
        .frame(minWidth: 880, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        // 标头要一直铺到窗顶（样机 sethead：红绿灯和「设置」同一行）。
        .ignoresSafeArea(.container, edges: .top)
        .background(LightAnchorTheme.sidebarBackground)
        .background(LightAnchorWindowConfigurator(chrome: .settings))
        .foregroundStyle(LightAnchorTheme.ink)
        .tint(palette.color(for: .primary))
        .accentColor(palette.color(for: .primary))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedPaneRawValue)
        .onAppear {
            #if DEBUG
            // 调试后门（截图/验收用）：指定初始标签页。
            if let pane = ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_SETTINGS_PANE"],
               SettingsPane(rawValue: pane) != nil {
                selectedPaneRawValue = pane
            }
            #endif
        }
    }

    private func settingsTab(_ pane: SettingsPane) -> some View {
        Button {
            selectedPaneRawValue = pane.rawValue
        } label: {
            Text(pane.title)
                .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
        }
        .buttonStyle(SettingsTabButtonStyle(isSelected: selectedPane == pane))
        .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
    }
}

/// 顶部药丸标签（样机 .settab）：32 高、圆角 10，选中 = 选中药丸底。
private struct SettingsTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isSelected || isHovered ? LightAnchorTheme.ink : LightAnchorTheme.mutedInk
            )
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                isSelected
                    ? LightAnchorTheme.sidebarSelection
                    : (isHovered ? LightAnchorTheme.hoverFill : LightAnchorThemeColor.clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// 设置六页。曾经还有一页「接收」，里面只有 Agent / 终端两个自动等待开关——
/// 和「连接」页的接入/移除是同一件事的两个闸，删掉了：一个来源一个真相。
private enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case shortcuts
    case permissions
    case intelligence
    case connections
    case data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: tr("appearance")
        case .shortcuts: tr("shortcuts")
        case .permissions: tr("permissions")
        case .intelligence: tr("intelligence")
        case .connections: tr("connections")
        case .data: tr("data")
        }
    }
}

/// 外观页（样机 setbody 示例）：主题三张预览瓦片 + 行为白卡行式。
private struct AppearanceSettingsPane: View {
    @EnvironmentObject private var themeController: LightAnchorThemeController
    @EnvironmentObject private var workspace: AttentionWorkspace
    @AppStorage(LightAnchorMenuBarPreference.storageKey)
    private var menuBarStatusVisible = true
    @AppStorage(LightAnchorCaptureReturnPreference.storageKey)
    private var captureReturnToContext = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var selectedLanguage = AppLanguage.current
    @State private var showingRelaunchPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupLabel(tr("appearance"))
                settingsCard {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(LightAnchorThemeMode.allCases) { mode in
                            themeTile(for: mode)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }

                settingsGroupLabel(tr("language"))
                settingsCard {
                    // 一行收口：标题 + 一句「需重开生效」说明 + 右侧下拉，
                    // 不再为说明文字单开一行。
                    settingsRow(
                        title: tr("interface_language"),
                        detail: tr("takes_effect_after_reopening_the_app")
                    ) {
                        LightAnchorSelectField(
                            tr("interface_language"),
                            selection: $selectedLanguage,
                            options: AppLanguage.allCases,
                            titleForValue: { $0.title },
                            embedded: true
                        )
                    }
                }
                .onChange(of: selectedLanguage) { _, language in
                    if AppLanguage.apply(language) {
                        showingRelaunchPrompt = true
                    }
                }

                settingsGroupLabel(tr("behavior"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            title: tr("return_to_previous_context_after_saving"),
                            detail: tr("go_back_to_the_previous_app")
                        ) {
                            Toggle("", isOn: $captureReturnToContext)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(tr("return_to_previous_context_after_saving"))
                        }
                        settingsRowDivider
                        settingsRow(
                            title: tr("show_current_state_in_the_menu"),
                            detail: tr("the_dot_s_shape_shows_active")
                        ) {
                            Toggle("", isOn: $menuBarStatusVisible)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(tr("show_current_state_in_the_menu"))
                        }
                        settingsRowDivider
                        settingsRow(title: tr("launch_at_login"), detail: nil) {
                            Toggle("", isOn: $launchAtLogin)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(tr("launch_at_login"))
                                .onChange(of: launchAtLogin) { _, newValue in
                                    applyLaunchAtLogin(newValue)
                                }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(Text(tr("reopen_the_app")), isPresented: $showingRelaunchPrompt) {
            Button(tr("reopen_now")) {
                #if os(macOS)
                AppLanguage.relaunchApp()
                #endif
            }
            Button(tr("later"), role: .cancel) {}
        } message: {
            Text(tr("the_language_applies_the_next_time"))
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            workspace.presentNotice(String(format: tr("couldn_t_update_launch_at_login"), error.localizedDescription))
        }
    }

    /// 外观样张的固定尺寸：小一号（纯色块 148×92 被否「太大且看不出区别」）。
    private static let tileSize = CGSize(width: 116, height: 74)

    private func themeTile(for mode: LightAnchorThemeMode) -> some View {
        let isSelected = themeController.mode == mode
        return Button {
            themeController.select(mode)
        } label: {
            VStack(spacing: 7) {
                tilePreview(for: mode)
                    .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? LightAnchorTheme.primary : LightAnchorTheme.subtleBorder,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(LightAnchorTheme.accentWash)
                                .padding(-3)
                        }
                    }
                    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

                HStack(spacing: 5) {
                    if isSelected {
                        Circle()
                            .fill(LightAnchorTheme.primary)
                            .frame(width: 6, height: 6)
                    }
                    Text(tileLabel(for: mode))
                        .font(LightAnchorTheme.controlFont(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? LightAnchorTheme.ink : LightAnchorTheme.mutedInk)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tileLabel(for: mode))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tileLabel(for mode: LightAnchorThemeMode) -> String {
        mode == .automatic ? tr("auto_follow_system") : mode.title
    }

    /// 样张 = 本软件的缩样窗（纯色块看不出是轻锚，也分不清浅色和自动）：
    /// 侧栏三行（首行选中药丸 + 蓝点）+ 内容区白卡上一枚蜜芽方块。
    /// 自动模式按 macOS 惯例对角一半浅一半深。
    @ViewBuilder
    private func tilePreview(for mode: LightAnchorThemeMode) -> some View {
        switch mode {
        case .light:
            miniAppWindow(palette: LightAnchorThemePalette(theme: .light))
        case .dark:
            miniAppWindow(palette: LightAnchorThemePalette(theme: .dark))
        case .automatic:
            ZStack {
                miniAppWindow(palette: LightAnchorThemePalette(theme: .light))
                miniAppWindow(palette: LightAnchorThemePalette(theme: .dark))
                    .clipShape(DiagonalHalf())
            }
        }
    }

    private func miniAppWindow(palette: LightAnchorThemePalette) -> some View {
        HStack(spacing: 0) {
            // 侧栏：一行选中药丸（带蓝点）+ 两行灰条。
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(palette.color(for: .primary))
                        .frame(width: 4, height: 4)
                    Capsule()
                        .fill(palette.color(for: .mutedForeground).opacity(0.75))
                        .frame(width: 18, height: 3)
                }
                .padding(.horizontal, 4)
                .frame(height: 12)
                .background(
                    palette.color(for: .sidebarAccent),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                Capsule()
                    .fill(palette.color(for: .mutedForeground).opacity(0.4))
                    .frame(width: 20, height: 3)
                    .padding(.leading, 4)
                Capsule()
                    .fill(palette.color(for: .mutedForeground).opacity(0.4))
                    .frame(width: 15, height: 3)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: Self.tileSize.width * 0.36, alignment: .topLeading)
            .background(palette.color(for: .sidebar))

            // 内容区：白卡上一枚蜜芽方块——看一眼就知道是轻锚。
            ZStack {
                palette.color(for: .background)
                VStack(alignment: .leading, spacing: 5) {
                    LightAnchorMarkView(state: .active)
                        .frame(width: 21, height: 20)
                    Capsule()
                        .fill(palette.color(for: .mutedForeground).opacity(0.55))
                        .frame(width: 30, height: 3.5)
                    Capsule()
                        .fill(palette.color(for: .mutedForeground).opacity(0.3))
                        .frame(width: 40, height: 3)
                }
                .padding(9)
                .frame(width: 58, alignment: .leading)
                .background(
                    palette.color(for: .card),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.color(for: .border).opacity(0.6), lineWidth: 0.5)
                )
            }
        }
    }
}

/// 「自动」样张的对角切分（右上三角显示深色一半，macOS 外观选择的惯例）。
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 组标签（样机 .setgroup-label）。
@MainActor
func settingsGroupLabel(_ title: String) -> some View {
    Text(title)
        .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
        .foregroundStyle(LightAnchorTheme.faintInk)
        .padding(.leading, 4)
        .padding(.bottom, -8)
}

/// 白卡容器（样机 .setcard）：白底 + 发丝描边 + 圆角 14。
@MainActor
func settingsCard(@ViewBuilder content: () -> some View) -> some View {
    VStack(spacing: 0) {
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LightAnchorTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
}

/// 行式设置项（样机 .setrow）：左标题 + 说明，右控件。
@MainActor
func settingsRow(
    title: String,
    detail: String?,
    @ViewBuilder control: () -> some View
) -> some View {
    HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                .foregroundStyle(LightAnchorTheme.ink)
            if let detail {
                Text(detail)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
        }
        Spacer(minLength: 14)
        control()
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 13)
}

/// 行间内缩发丝线（样机 .setrow + .setrow::before）。
@MainActor
var settingsRowDivider: some View {
    Rectangle()
        .fill(LightAnchorTheme.hairlineBorder)
        .frame(height: 1)
        .padding(.horizontal, 18)
}

/// 菜单栏常驻状态的偏好键：设置页开关与 MenuBarExtra 共用。
enum LightAnchorMenuBarPreference {
    static let storageKey = "lightanchor.menuBarStatusVisible"
}

/// 「保存后回到原上下文」偏好键（样机 .setrow 第二行）：
/// 设置页开关与捕获窗保存逻辑共用，默认开启。
enum LightAnchorCaptureReturnPreference {
    static let storageKey = "lightanchor.captureReturnToContext"
}

/// 捕获去向偏好：稍后（要做的事）或暂存箱（想法/链接留存）。
/// 记住上次选择；工具栏 + 菜单的两个入口会显式覆写。
enum LightAnchorCaptureDestinationPreference {
    static let storageKey = "lightanchor.captureDestination"
}

/// 快捷键页：全局快捷键集中在这里配置。行式白卡 + 录制控件。
private struct ShortcutSettingsPane: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @State private var preferences = GlobalHotKeyPreferences.load()
    @State private var failures: [GlobalHotKeyAction: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupLabel(tr("global_shortcuts"))
                settingsCard {
                    VStack(spacing: 0) {
                        let actions = GlobalHotKeyAction.allCases
                        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                            shortcutRow(for: action)
                            if index < actions.count - 1 {
                                settingsRowDivider
                            }
                        }
                    }
                }

                Text(tr("global_shortcuts_work_in_any_app"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            failures = GlobalHotKeyCenter.shared.failureMessages
        }
    }

    @ViewBuilder
    private func shortcutRow(for action: GlobalHotKeyAction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(title: action.title, detail: action.detail) {
                HStack(spacing: 8) {
                    LightAnchorHotKeyRecorder(
                        title: action.title,
                        binding: preferences.binding(for: action),
                        onRecord: { updateBinding($0, for: action) },
                        onClear: { updateBinding(nil, for: action) }
                    )
                }
            }
            if let failure = failures[action] {
                Text(failure)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 11)
                    .padding(.top, -5)
            }
        }
    }

    private func updateBinding(_ binding: HotKeyBinding?, for action: GlobalHotKeyAction) {
        preferences.setBinding(binding, for: action)
        applyAndSave()
    }

    private func applyAndSave() {
        preferences.save()
        failures = GlobalHotKeyCenter.shared.apply(preferences: preferences)
    }
}

/// 快捷键录制方框：平时显示当前按键；点按进入录制态，按下的第一组
/// 带修饰键的按键成为新快捷键，Esc 取消。录制期间吞掉本地键盘事件。
private struct LightAnchorHotKeyRecorder: View {
    /// 所属动作名：名称承载「这是谁的快捷键」，值承载「现在是什么按键」，
    /// 不分开的话设置页几个录制器对旁白听起来一模一样。
    let title: String
    let binding: HotKeyBinding?
    let onRecord: (HotKeyBinding) -> Void
    /// 清除当前快捷键。不单独占一颗按钮：平时悬停键帽右缘露出 ⓧ
    /// 一步清除，录制态里按 ⌫ 也能清——录制态本身不再放 ⓧ，
    /// 那里出现它更像「取消录制」，语义是混的。
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var isHovered = false
    @State private var keyMonitor: Any?

    /// 平时态悬停且确实有键可清时才露出 ⓧ（输入框清除按钮的惯例，
    /// Raycast/Alfred 的快捷键控件同款）；录制态交给 ⌫。
    private var showsClear: Bool { isHovered && !isRecording && binding != nil }

    var body: some View {
        // 控件骨架照旧（26 高的可点方框），但未编辑时的展示
        // 走 0.1.0 只读键帽的气质：等宽 11 号、recessed 底、发丝描边，
        // hover 微亮提示可点；点按进入录制态才亮起来。
        ZStack(alignment: .trailing) {
            recorderBox
            // ⓧ 常驻视图树、只变透明度：悬停时条件插入会重建 hover
            // 追踪区域，hover 状态被打断又恢复，图标就一直闪。
            Button {
                onClear()
            } label: {
                LightAnchorIcon("circle-x", size: 13)
                    .foregroundStyle(LightAnchorTheme.iconSoft)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .opacity(showsClear ? 1 : 0)
            .allowsHitTesting(showsClear)
            .help(tr("clear"))
            .accessibilityLabel(tr("clear_shortcut"))
            .accessibilityHidden(!showsClear)
        }
        // hover 也挂在外层稳定容器上（区域覆盖键帽含 ⓧ），
        // 不随内部状态变化而重建。
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: showsClear)
        .onDisappear { stopRecording() }
    }

    private var recorderBox: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(label)
                .font(LightAnchorTheme.monoFont(size: isRecording ? 12 : 11))
                .foregroundStyle(
                    isRecording
                        ? LightAnchorTheme.accentInk
                        : (binding == nil ? LightAnchorTheme.faintInk : LightAnchorTheme.mutedInk)
                )
                .padding(.horizontal, 10)
                .frame(height: 26)
                // 悬停的 ⓧ 覆在右缘的留白上，不改任何度量——
                // 静止、悬停、录制三态同宽，几行键帽才排得齐。
                .frame(minWidth: 116)
                .background(
                    isRecording ? LightAnchorTheme.accentWash : LightAnchorTheme.recessed,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? LightAnchorTheme.primary
                                : (isHovered ? LightAnchorTheme.subtleBorder : LightAnchorTheme.hairlineBorder),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(String(format: tr("shortcut_for_action"), title))
        .accessibilityValue(
            isRecording
                ? tr("recording_shortcut")
                : (binding?.displayString ?? tr("no_shortcut_set"))
        )
    }

    private var label: String {
        if isRecording { return tr("press_new_keys") }
        return binding?.displayString ?? tr("click_to_set")
    }

    private func startRecording() {
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc 取消录制。
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            // ⌫ 清除当前快捷键（这类控件的通用约定）。
            if event.keyCode == UInt16(kVK_Delete) {
                stopRecording()
                onClear()
                return nil
            }
            guard let recorded = HotKeyBinding(event: event) else { return nil }
            guard recorded.hasCommandingModifier else {
                // 没有 ⌘/⌥/⌃ 的按键不能当全局热键，会吞掉正常输入。
                NSSound.beep()
                return nil
            }
            stopRecording()
            onRecord(recorded)
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
    }
}
