import Foundation

#if os(macOS)
import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Security
import Speech
import UserNotifications
#endif

enum SceneSourceRuleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case excludeListed
    case includeOnlyListed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .excludeListed: tr("exclude_listed_sources")
        case .includeOnlyListed: tr("capture_listed_sources_only")
        }
    }
}

/// 现场记录的本机隐私边界。规则在读取窗口事实时应用，而不是在展示层隐藏，
/// 因而被排除的应用、网站、终端目录与标题不会进入事件日志。
struct SceneCapturePreferences: Codable, Equatable, Sendable {
    static let storageKey = "lightanchor.sceneCapturePreferences"

    var isAutomaticCapturePaused: Bool
    var applicationRuleMode: SceneSourceRuleMode
    var applicationBundleIdentifiers: Set<String>
    var websiteRuleMode: SceneSourceRuleMode
    var websiteHosts: Set<String>

    init(
        isAutomaticCapturePaused: Bool = false,
        applicationRuleMode: SceneSourceRuleMode = .excludeListed,
        applicationBundleIdentifiers: Set<String> = [],
        websiteRuleMode: SceneSourceRuleMode = .excludeListed,
        websiteHosts: Set<String> = []
    ) {
        self.isAutomaticCapturePaused = isAutomaticCapturePaused
        self.applicationRuleMode = applicationRuleMode
        self.applicationBundleIdentifiers = Self.normalizedBundleIdentifiers(
            applicationBundleIdentifiers
        )
        self.websiteRuleMode = websiteRuleMode
        self.websiteHosts = Self.normalizedHosts(websiteHosts)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return decoded.normalized()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func allowsApplication(_ bundleIdentifier: String) -> Bool {
        let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return applicationRuleMode == .excludeListed }
        let isListed = applicationBundleIdentifiers.contains(value)
        switch applicationRuleMode {
        case .excludeListed: return !isListed
        case .includeOnlyListed: return isListed
        }
    }

    /// 非网页 URL（例如本地文档）不受网站规则影响。
    func allowsDocumentURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return true }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return websiteRuleMode == .excludeListed
        }
        let isListed = websiteHosts.contains { rule in
            host == rule || host.hasSuffix(".\(rule)")
        }
        switch websiteRuleMode {
        case .excludeListed: return !isListed
        case .includeOnlyListed: return isListed
        }
    }

    func normalized() -> Self {
        Self(
            isAutomaticCapturePaused: isAutomaticCapturePaused,
            applicationRuleMode: applicationRuleMode,
            applicationBundleIdentifiers: applicationBundleIdentifiers,
            websiteRuleMode: websiteRuleMode,
            websiteHosts: websiteHosts
        )
    }

    private static func normalizedBundleIdentifiers(_ values: Set<String>) -> Set<String> {
        Set(values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func normalizedHosts(_ values: Set<String>) -> Set<String> {
        Set(values.compactMap { value in
            var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let url = URL(string: normalized.contains("://") ? normalized : "https://\(normalized)"),
               let host = url.host {
                normalized = host.lowercased()
            }
            if normalized.hasPrefix("*.") { normalized.removeFirst(2) }
            if normalized.hasPrefix("www.") { normalized.removeFirst(4) }
            while normalized.hasSuffix(".") { normalized.removeLast() }
            return normalized.isEmpty ? nil : normalized
        })
    }
}

enum PrivacyCapability: String, CaseIterable, Identifiable, Codable, Sendable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility
    case notifications
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: tr("microphone")
        case .speechRecognition: tr("speech_recognition")
        case .screenRecording: tr("screen_recording")
        case .accessibility: tr("accessibility")
        case .notifications: tr("notifications")
        case .calendar: tr("calendar_access")
        }
    }

    var explanation: String {
        switch self {
        case .microphone: tr("used_only_when_you_start_a")
        case .speechRecognition: tr("transcribes_your_recordings_on_this_mac")
        case .screenRecording: tr("used_for_screenshot_regions_you_select")
        case .accessibility: tr("reads_app_and_window_facts_you")
        case .notifications: tr("optional_notifications_when_results_arrive")
        case .calendar: tr("reads_event_times_you_pick_for")
        }
    }

    /// 授权动作发生在应用之外——系统只把人送进「系统设置」，开关是在那里拨的。
    /// 这类能力永远拿不到一个明确的「拒绝」：没开就是没开，分不清是还没去拨
    /// 还是拨了又关。所以它们不许伪造 `.denied`，只报 `.awaitingSystemSettings`。
    var isGrantedInSystemSettings: Bool {
        switch self {
        case .screenRecording, .accessibility: true
        case .microphone, .speechRecognition, .notifications, .calendar: false
        }
    }

    /// 屏幕录制的授权结果在进程内被缓存，拨完开关必须重开轻锚才生效。
    var requiresRelaunchAfterGrant: Bool {
        self == .screenRecording
    }

    #if os(macOS)
    var systemSettingsURL: URL? {
        // 面板 id 用 macOS 13 起的 ExtensionKit 扩展标识（旧的
        // com.apple.preference.security 只靠系统的兼容映射还活着）。
        if self == .notifications {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }

        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .notifications: anchor = "Notifications"
        case .calendar: anchor = "Privacy_Calendars"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        )
    }
    #endif
}

enum PrivacyPermissionStatus: String, Equatable {
    case notDetermined
    case granted
    /// 系统明确回了「不给」。只有会弹窗要答案的能力（麦克风、语音识别、通知）
    /// 才会走到这里；辅助功能和屏幕录制用 `awaitingSystemSettings`。
    case denied
    /// 已经把人送去系统设置，开关还没拨。这不是拒绝，只是还没到。
    case awaitingSystemSettings
    case restricted
    case unavailable

    var title: String {
        switch self {
        case .notDetermined: tr("not_determined")
        case .granted: tr("granted")
        case .denied: tr("rejected")
        case .awaitingSystemSettings: tr("waiting_on_system_settings")
        case .restricted: tr("restricted")
        case .unavailable: tr("unavailable")
        }
    }
}

struct AppPermissionSnapshot: Codable, Equatable, Sendable {
    struct Permission: Codable, Equatable, Sendable {
        let id: String
        let status: String
        let detail: String
    }

    let schemaVersion: Int
    let generatedAt: Date
    let operatingSystem: String
    let bundleIdentifier: String?
    let appVersion: String
    let buildNumber: String
    let bundlePath: String
    let executable: String
    let permissions: [Permission]
    let limitations: [String]

    static func make(
        statuses: [PrivacyCapability: PrivacyPermissionStatus],
        generatedAt: Date = Date(),
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        buildNumber: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown",
        bundlePath: String = Bundle.main.bundleURL.path,
        executable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    ) -> Self {
        Self(
            schemaVersion: 1,
            generatedAt: generatedAt,
            operatingSystem: operatingSystem,
            bundleIdentifier: bundleIdentifier,
            appVersion: appVersion,
            buildNumber: buildNumber,
            bundlePath: bundlePath,
            executable: executable,
            permissions: PrivacyCapability.allCases.map { capability in
                Permission(
                    id: capability.rawValue,
                    status: (statuses[capability] ?? .unavailable).rawValue,
                    detail: capability.explanation
                )
            },
            limitations: [
                "This snapshot observes current authorization only; it does not request, deny, or revoke permissions."
            ]
        )
    }
}

enum AppPermissionSnapshotter {
    static let reportEnvironmentKey = "LIGHTANCHOR_PERMISSION_REPORT"

    static func reportURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment[reportEnvironmentKey], path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func capture(
        service: PrivacyPermissionService = PrivacyPermissionService()
    ) async -> AppPermissionSnapshot {
        var statuses: [PrivacyCapability: PrivacyPermissionStatus] = [:]
        for capability in PrivacyCapability.allCases {
            statuses[capability] = await service.statusAsync(for: capability)
        }
        return AppPermissionSnapshot.make(statuses: statuses)
    }

    @discardableResult
    static func writeIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        service: PrivacyPermissionService = PrivacyPermissionService()
    ) async throws -> Bool {
        guard let destination = reportURL(environment: environment) else { return false }
        let snapshot = await capture(service: service)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: destination, options: .atomic)
        return true
    }
}

/// 权限询问与状态的本机缓存。仅为了在系统只回「未授权」时区分
/// 「还没问过」和「问过被拒」，不是权限的事实源。
enum PrivacyPermissionCache {
    private static let requestedPrefix = "lightanchor.permission.requested."
    private static let statusPrefix = "lightanchor.permission.status."

    static func markRequested(_ capability: PrivacyCapability, in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: requestedKey(for: capability))
    }

    static func wasRequested(_ capability: PrivacyCapability, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: requestedKey(for: capability))
    }

    /// 授权到手后忘掉「问过」。用户之后如果在系统设置里关掉，状态要能回到
    /// 「尚未授权」并重新长出授权按钮——否则一次询问就把入口永久锁死了。
    static func clearRequested(_ capability: PrivacyCapability, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: requestedKey(for: capability))
    }

    static func status(
        for capability: PrivacyCapability,
        in defaults: UserDefaults = .standard
    ) -> PrivacyPermissionStatus? {
        guard let rawValue = defaults.string(forKey: statusKey(for: capability)) else {
            return nil
        }
        return PrivacyPermissionStatus(rawValue: rawValue)
    }

    static func store(
        _ status: PrivacyPermissionStatus,
        for capability: PrivacyCapability,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(status.rawValue, forKey: statusKey(for: capability))
    }

    /// 删除全部本地数据时要清掉的全部缓存键（见 `LocalDataErasure`）。
    static var allCacheKeys: [String] {
        PrivacyCapability.allCases.flatMap {
            [requestedKey(for: $0), statusKey(for: $0)]
        }
    }

    private static func requestedKey(for capability: PrivacyCapability) -> String {
        requestedPrefix + capability.rawValue
    }

    private static func statusKey(for capability: PrivacyCapability) -> String {
        statusPrefix + capability.rawValue
    }
}

#if os(macOS)
/// 本机代码签名事实。TCC 把授权钉在应用的签名上：ad-hoc 包每次重新签名
/// CDHash 都变，旧授权那一条会留在系统设置列表里却对不上新包——看起来
/// 「已打开」，`AXIsProcessTrusted()` 仍然是 false。裸可执行文件
/// （`swift run`，没有 bundle identifier）同理。这类构建要提示用户先移除
/// 旧条目再重新添加，否则会一直以为是应用坏了。
enum AppSignatureFacts {
    /// 授权可能留不住：ad-hoc 签名，或者根本不在 .app 包里跑。
    static let grantsMayNotStick: Bool = isAdHocSigned || Bundle.main.bundleIdentifier == nil

    /// CSCommon.h 的 kSecCodeSignatureAdhoc，没有导出到 Swift。
    private static let adhocSignatureFlag: UInt32 = 0x0000_0002

    private static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let facts = information as? [String: Any],
              let flags = facts[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & adhocSignatureFlag != 0
    }
}
#endif

struct PrivacyPermissionService: Sendable {
    func status(for capability: PrivacyCapability) -> PrivacyPermissionStatus {
        #if os(macOS)
        switch capability {
        case .microphone:
            return mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return mapSpeechAuthorization(SFSpeechRecognizer.authorizationStatus())
        case .screenRecording:
            return systemSettingsStatus(for: capability, isGranted: CGPreflightScreenCaptureAccess())
        case .accessibility:
            return systemSettingsStatus(for: capability, isGranted: AXIsProcessTrusted())
        case .notifications:
            // 缓存只是同步读的兜底，真值靠 statusAsync 问 UNUserNotificationCenter。
            return PrivacyPermissionCache.status(for: capability) ?? .notDetermined
        case .calendar:
            return mapCalendarAuthorization(EKEventStore.authorizationStatus(for: .event))
        }
        #else
        return .unavailable
        #endif
    }

    func statusAsync(for capability: PrivacyCapability) async -> PrivacyPermissionStatus {
        #if os(macOS)
        guard capability == .notifications else { return status(for: capability) }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let result: PrivacyPermissionStatus
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: result = .granted
        case .denied: result = .denied
        case .notDetermined: result = .notDetermined
        @unknown default: result = .unavailable
        }
        PrivacyPermissionCache.store(result, for: capability)
        return result
        #else
        return .unavailable
        #endif
    }

    func request(_ capability: PrivacyCapability) async -> PrivacyPermissionStatus {
        #if os(macOS)
        // 「之前问过没有」必须在 markRequested 之前读：系统只在应用还没进 TCC
        // 列表时弹一次窗，第二次点授权得靠我们把人送进系统设置。
        let hadAskedBefore = PrivacyPermissionCache.wasRequested(capability)
        PrivacyPermissionCache.markRequested(capability)
        switch capability {
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            let result: PrivacyPermissionStatus = granted ? .granted : .denied
            PrivacyPermissionCache.store(result, for: capability)
            return result
        case .speechRecognition:
            let result = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: self.mapSpeechAuthorization(status))
                }
            }
            PrivacyPermissionCache.store(result, for: capability)
            return result
        case .screenRecording:
            // 弹窗是 UI，必须在主线程发起；它只是把人送进系统设置，
            // 返回值几乎总是当前状态（还没授权）。
            let granted = await MainActor.run { CGRequestScreenCaptureAccess() }
            return await settleSystemSettingsRequest(
                capability,
                isGranted: granted,
                hadAskedBefore: hadAskedBefore
            )
        case .accessibility:
            // 常量 kAXTrustedCheckOptionPrompt 是全局 var，Swift 6 并发检查不放行，
            // 这里直接写它的字面值。
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let granted = await MainActor.run { AXIsProcessTrustedWithOptions(options) }
            return await settleSystemSettingsRequest(
                capability,
                isGranted: granted,
                hadAskedBefore: hadAskedBefore
            )
        case .notifications:
            let center = UNUserNotificationCenter.current()
            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let result: PrivacyPermissionStatus = granted == true ? .granted : .denied
            PrivacyPermissionCache.store(result, for: capability)
            return result
        case .calendar:
            // 读日历事件需要 fullAccess（macOS 14+ 的读写二分里，读属于 full）。
            let store = EKEventStore()
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            let result: PrivacyPermissionStatus = granted ? .granted : .denied
            PrivacyPermissionCache.store(result, for: capability)
            return result
        }
        #else
        return .unavailable
        #endif
    }

    #if os(macOS)
    /// 辅助功能 / 屏幕录制的读数。授权到手时顺手把「问过」标记清掉，
    /// 这样用户之后在系统设置里关掉，状态会回到「尚未授权」而不是卡在等待。
    private func systemSettingsStatus(
        for capability: PrivacyCapability,
        isGranted: Bool
    ) -> PrivacyPermissionStatus {
        guard isGranted else {
            return PrivacyPermissionCache.wasRequested(capability) ? .awaitingSystemSettings : .notDetermined
        }
        // 权限页开着时这里每秒都会被问一次，只在真的变了才落盘。
        if PrivacyPermissionCache.wasRequested(capability) {
            PrivacyPermissionCache.clearRequested(capability)
        }
        if PrivacyPermissionCache.status(for: capability) != .granted {
            PrivacyPermissionCache.store(.granted, for: capability)
        }
        return .granted
    }

    /// 系统设置类授权的收尾。没到手不算拒绝——报「等系统设置」，由页面上的
    /// 轮询在开关拨过来的那一刻自己跟上。
    private func settleSystemSettingsRequest(
        _ capability: PrivacyCapability,
        isGranted: Bool,
        hadAskedBefore: Bool
    ) async -> PrivacyPermissionStatus {
        guard !isGranted else {
            PrivacyPermissionCache.clearRequested(capability)
            PrivacyPermissionCache.store(.granted, for: capability)
            return .granted
        }
        PrivacyPermissionCache.store(.awaitingSystemSettings, for: capability)
        if hadAskedBefore, let url = capability.systemSettingsURL {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        return .awaitingSystemSettings
    }

    private func mapAVAuthorization(_ status: AVAuthorizationStatus) -> PrivacyPermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    private func mapSpeechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> PrivacyPermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    private func mapCalendarAuthorization(_ status: EKAuthorizationStatus) -> PrivacyPermissionStatus {
        switch status {
        case .fullAccess: .granted
        // 只写权限读不到事件时间，对「从日历选时间」来说等同被拒。
        case .denied, .writeOnly: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    #endif
}
