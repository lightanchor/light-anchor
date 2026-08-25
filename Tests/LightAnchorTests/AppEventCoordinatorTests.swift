import Foundation
import XCTest
@testable import LightAnchor

/// 全局 ⌥⌘N 在「窗口全关」状态下必须照样呼出捕获窗：主窗关掉之后应用仍然
/// 驻留，而快捷键是设置页明确承诺过的「在任何应用里呼出捕获窗」。
@MainActor
final class AppEventCoordinatorTests: XCTestCase {
    // MARK: - 接线

    func testCaptureHotKeyIsHandledOutsideTheMainWindowView() throws {
        // 这几处接线是「关掉主窗之后 ⌥⌘N 还有反应」的全部依据。把观察者搬回
        // 视图里，快捷键就又只在窗口开着的时候管用了。
        let app = try source(at: "Sources/LightAnchor/App/LightAnchorApp.swift")
        XCTAssertTrue(app.contains("AppEventCoordinator.shared.start()"))

        let workspaceView = try source(at: "Sources/LightAnchor/Views/MainWorkspaceView.swift")
        XCTAssertFalse(workspaceView.contains("publisher(for: .openCaptureWindow)"))
        XCTAssertTrue(workspaceView.contains("AppEventCoordinator.shared.adopt(openWindow: openWindow)"))
    }

    func testReopenLeavesTheWindowToAppKit() throws {
        // `openWindow(id:)` 对 WindowGroup 是「新开」而不是「聚焦」，所以
        // 自己在 reopen 里再开一个就会得到两个主窗。
        let lifecycle = try source(at: "Sources/LightAnchor/Services/AppLifecycleKit.swift")
        XCTAssertFalse(lifecycle.contains("openMainWindow"))

        // 快捷键的「打开主窗口」走接线员：必须先复用已有主窗
        // （makeKeyAndOrderFront），全关了才 openWindow 重建。
        let coordinator = try source(at: "Sources/LightAnchor/App/AppEventCoordinator.swift")
        XCTAssertTrue(coordinator.contains("makeKeyAndOrderFront"))
    }

    func testCaptureWindowRequestActivatesTheApp() throws {
        // 全局快捷键是从别的应用里按的：不激活轻锚，捕获窗拿不到键盘焦点，
        // 闪烁的光标下面打不进字。
        let coordinator = try source(at: "Sources/LightAnchor/App/AppEventCoordinator.swift")
        XCTAssertTrue(coordinator.contains("NSApp.activate()"))
        // 现场快照记的是「最前面是哪个应用」，激活之后再采就只剩轻锚自己，
        // 所以采集必须留在按键那一刻，不能搬进接线员。
        XCTAssertFalse(coordinator.contains("CaptureContextStore.shared.prepare()"))

        let app = try source(at: "Sources/LightAnchor/App/LightAnchorApp.swift")
        let press = try XCTUnwrap(app.range(of: "hotKeys.onAction = {"))
        let body = app[press.upperBound...].prefix(while: { $0 != "}" })
        XCTAssertTrue(body.contains("CaptureContextStore.shared.prepare()"))
    }

    // MARK: - 工具

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
