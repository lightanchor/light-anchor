import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// 应用级事件的常驻接线员。
///
/// 全局捕获快捷键可能在「一个窗口都没有」的时候按下：主窗关掉之后应用仍然
/// 驻留（`applicationShouldTerminateAfterLastWindowClosed` 返回 false），菜单栏
/// 图标是唯一的入口。
///
/// 它原来挂在 `MainWorkspaceView` 的 `.onReceive` 上，而 `.onReceive` 只在视图
/// 活着的时候订阅——窗口一关，⌥⌘N 就彻底没反应了。接线员由 App 直接持有，
/// 生命周期等于进程，所以不受窗口开关影响。
@MainActor
final class AppEventCoordinator {
    static let shared = AppEventCoordinator()

    private var openWindowAction: OpenWindowAction?
    private var observers: [NSObjectProtocol] = []

    /// SwiftUI 只在视图环境里提供 `openWindow`。取到的 action 是值类型，绑的是
    /// 场景桥而不是提供它的那个视图，存下来之后窗口关掉仍然可用；主窗和菜单栏
    /// 标签都会在出现时交出自己那份，两者都关不掉的情况不存在。
    func adopt(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            observe(.openCaptureWindow) { $0.openCaptureWindow() },
            observe(.openMainWindow) { $0.openMainWindow() },
        ]
    }

    /// 全局快捷键把主窗带到前台。`openWindow(id:)` 对 WindowGroup 是
    /// 「再开一个」而不是「聚焦已有」，所以主窗开着时直接把它带到最前，
    /// 只有全关了才用 openWindow 重建。
    func openMainWindow() {
        #if os(macOS)
        activateApp()
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true
        }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        #endif
        openWindowAction?(id: "main")
    }

    /// 现场快照不在这里采：`CaptureContextStore.prepare()` 记的是「当前最前面
    /// 的应用和窗口」，激活轻锚之后再采就只会采到轻锚自己。采集留在按键那一刻
    /// 同步做（见 `LightAnchorApp` 里的 `hotKey.onPress`）。
    func openCaptureWindow() {
        #if os(macOS)
        // 全局快捷键从别的应用里按下时轻锚不是前台应用。捕获窗虽然是
        // floating 层会浮在最上面，但不激活应用就拿不到键盘焦点，闪烁的
        // 光标下面打不进字。
        activateApp()
        #endif
        openWindowAction?(id: "capture")
    }

    private func observe(
        _ name: Notification.Name,
        perform action: @escaping @MainActor (AppEventCoordinator) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                action(AppEventCoordinator.shared)
            }
        }
    }

    #if os(macOS)
    private func activateApp() {
        // 权限/上下文探针会把激活策略设成 .prohibited（无 UI 跑批），
        // 那种进程里不该抢焦点。
        guard NSApp.activationPolicy() == .regular else { return }
        NSApp.activate()
    }
    #endif
}
