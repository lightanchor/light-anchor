import Foundation
#if os(macOS)
import AppKit
#endif

/// 界面文案的本地化入口。key 是稳定的英文标识符（如 "save"、"cloud_configuration_ready"），
/// 不再用中文原文当 key。简体中文是开发语言：zh-Hans 表是唯一事实源，
/// en 等其他语言逐 key 对照翻译；以后加语言 = 加一个 .lproj，零代码改动。
/// 查找顺序：当前语言表 → zh-Hans 表 → key 本身，所以漏译只会回退中文。
/// 表随 SPM 资源 bundle 走（Bundle.module），swift run 开发期也生效。
/// SwiftUI 字面量不再自动查表：所有用户可见文案都必须包 tr()。
func tr(_ key: String) -> String {
    LocalizationTable.string(for: key)
}

enum LocalizationTable {
    /// 单测进程固定读 zh-Hans：让测试里的中文断言与跑测试机器的系统语言无关。
    static let pinToChinese = NSClassFromString("XCTestCase") != nil

    /// 查不到时 localizedString 会原样回吐 value，用不可能出现在文案里的哨兵区分。
    private static let missing = "\u{1}?"

    /// zh-Hans 表所在的子 bundle。目录名的大小写要看 SwiftPM 版本：新版按
    /// Package.swift 原样给出 `zh-Hans.lproj`，旧版（如 CI 上的 6.1）会把
    /// 「默认语言」摊平并小写成 `zh-hans.lproj`。NSBundle 的资源查找区分
    /// 大小写，写死一种拼法就会在另一种上整表落空、tr() 一路回退成 key，
    /// 所以按 bundle 自己报的 localizations 找。
    private static let chineseBundle: Bundle? = {
        let candidates = ["zh-Hans"] + Bundle.module.localizations.filter {
            $0.caseInsensitiveCompare("zh-Hans") == .orderedSame
        }
        for name in candidates {
            if let path = Bundle.module.path(forResource: name, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }()

    static func string(for key: String) -> String {
        if !pinToChinese {
            let value = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            if value != missing { return value }
        }
        if let zh = chineseBundle {
            let value = zh.localizedString(forKey: key, value: missing, table: nil)
            if value != missing { return value }
        }
        return key
    }
}

/// 应用语言偏好。写系统标准的 AppleLanguages 覆盖，重启后整个进程
/// （含系统控件、日期格式）一致切换；「跟随系统」= 清掉覆盖。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    static let appleLanguagesKey = "AppleLanguages"
    static let storageKey = "lightanchor.appLanguage"

    var title: String {
        switch self {
        case .system: tr("follow_system")
        case .chinese: "中文"
        case .english: "English"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// 应用选择：记住偏好并写/清 AppleLanguages 覆盖。返回是否需要重启生效。
    @discardableResult
    static func apply(_ language: AppLanguage) -> Bool {
        let defaults = UserDefaults.standard
        let previous = current
        defaults.set(language.rawValue, forKey: storageKey)
        switch language {
        case .system:
            defaults.removeObject(forKey: appleLanguagesKey)
        case .chinese:
            defaults.set(["zh-Hans"], forKey: appleLanguagesKey)
        case .english:
            defaults.set(["en"], forKey: appleLanguagesKey)
        }
        return language != previous
    }

    #if os(macOS)
    /// 重启应用让语言生效：先起一个新实例，再退出当前实例。
    /// NSApp / NSWorkspace 都是主线程独占的（macOS 15 SDK 起编译器会强制），
    /// 所以整个函数挂在主 actor 上——调用点本来就在 SwiftUI 的按钮动作里。
    @MainActor
    static func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            // 开发期裸二进制没有可重启的 bundle，让用户手动重启。
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            // 回调不在主线程，也不带 actor 隔离——显式跳回主 actor 再 terminate。
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
    #endif
}
