import Foundation

#if os(macOS)
import CoreGraphics

/// 现场截图：切走 / 开始等待的瞬间存一张全桌面截图进现场舱。
/// 只在「保存窗口截图」开关打开且系统「屏幕录制」权限已授予时工作。
enum SceneScreenshotRecorder {
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗。系统只在应用还没进 TCC 列表时弹这一次，之后由
    /// `PrivacyPermissionService` 把人送进系统设置；走它是为了让设置 → 权限
    /// 页看到同一份「问过了」的状态，而不是各记各的。
    @discardableResult
    static func requestPermission() async -> PrivacyPermissionStatus {
        await PrivacyPermissionService().request(.screenRecording)
    }

    /// 截当前桌面为 JPEG。未授权或失败返回 nil，绝不阻塞抛错——
    /// 自动快照是后台钩子，截图失败不能影响现场保存本身。
    static func captureDesktop() async -> Data? {
        guard hasPermission else { return nil }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightanchor-scene-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            // -x 静默无声；JPEG 控制体积（全桌面 PNG 动辄十几 MB）。
            _ = try await ProcessExecutionSupport.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                arguments: ["-x", "-t", "jpg", temporaryURL.path]
            )
        } catch {
            return nil
        }
        return try? Data(contentsOf: temporaryURL)
    }
}
#endif
