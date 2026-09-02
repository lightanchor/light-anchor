import Foundation

#if os(macOS)
import AppKit
import CoreGraphics

/// 现场截图：切走 / 开始等待的瞬间存一张全桌面截图进现场舱。
/// 只在「保存窗口截图」开关打开且系统「屏幕录制」权限已授予时工作。
enum SceneScreenshotRecorder {
    /// 「哪些应用允许进入现场」的判定；传入 bundle ID（读不到时为空字符串）。
    typealias ApplicationPredicate = @Sendable (_ bundleIdentifier: String) -> Bool

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
    ///
    /// `allowsApplication` 是现场来源的排除规则：只要桌面上有任何一个可见窗口
    /// 属于被排除的应用，就整张不截（返回 nil），而不是截了再想办法抹掉——
    /// 全桌面截图没法只遮一个窗口，宁可少一张图，也不把被排除的内容存下来。
    static func captureDesktop(
        allowsApplication: ApplicationPredicate = { _ in true }
    ) async -> Data? {
        guard hasPermission else { return nil }
        guard !visibleDesktopContainsBlockedWindow(allowsApplication: allowsApplication) else {
            return nil
        }
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

    /// 桌面上是否有属于被排除应用的可见窗口。枚举当前屏幕上的普通窗口
    /// （层 0、非零尺寸、非全透明），按拥有进程映射到 bundle ID 后逐个问规则。
    static func visibleDesktopContainsBlockedWindow(
        allowsApplication: ApplicationPredicate
    ) -> Bool {
        let owners = visibleWindowOwnerBundleIdentifiers()
        return owners.contains { !allowsApplication($0) }
    }

    /// 可见普通窗口的拥有者 bundle ID 集合；读不到 bundle ID 的进程记为空字符串，
    /// 交给规则自己决定（排除模式默认放行，仅允许模式默认拒绝）。
    static func visibleWindowOwnerBundleIdentifiers() -> Set<String> {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var processIdentifiers = Set<pid_t>()
        for window in windows where isVisibleContentWindow(window) {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            processIdentifiers.insert(ownerPID)
        }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        var identifiers = Set<String>()
        for processIdentifier in processIdentifiers where processIdentifier != ownProcessIdentifier {
            let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?
                .bundleIdentifier ?? ""
            identifiers.insert(bundleIdentifier)
        }
        return identifiers
    }

    /// 只看真正承载内容的窗口：层 0（普通窗口），尺寸不是象征性的一两个点，
    /// 且没有被设成全透明。菜单栏、Dock、状态项之类都在别的层上。
    static func isVisibleContentWindow(_ window: [String: Any]) -> Bool {
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { return false }
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0 else { return false }
        guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return false }
        return bounds.width >= minimumWindowDimension && bounds.height >= minimumWindowDimension
    }

    private static let minimumWindowDimension: CGFloat = 16
}
#endif
