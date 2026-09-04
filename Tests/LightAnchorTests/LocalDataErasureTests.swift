import Foundation
import XCTest
@testable import LightAnchor

/// 「删除全部本地数据」的守门测试。
///
/// 这里守的不是某个函数怎么写，而是一条承诺：确认弹窗说「已删除这台 Mac 上的
/// 工作区数据」，那盘上就不能留下用户以为删掉的东西。它曾经漏过对话记录、
/// 用户手写的回顾正文和云端 API Key，所以清单要可枚举、要被核对。
final class LocalDataErasureTests: XCTestCase {

    // MARK: - 清单完整性

    /// 源码里出现的每一个偏好键，都必须被 LocalDataErasure 显式分类：
    /// 要么删（内容、凭据、缓存），要么留（界面与隐私偏好）。新增一个键忘了
    /// 分类，这条会红——这正是当初漏删的成因。
    func testEveryPreferenceKeyInSourceIsClassified() throws {
        let classified = Set(
            LocalDataErasure.erasableUserDefaultsKeys + LocalDataErasure.preservedUserDefaultsKeys
        )
        let unclassified = try preferenceKeyLiteralsInSource().filter { key in
            if classified.contains(key) { return false }
            // 权限缓存是「前缀 + capability」拼出来的，源码里只出现前缀。
            return !classified.contains { $0.hasPrefix(key) }
        }

        XCTAssertTrue(
            unclassified.isEmpty,
            "这些偏好键没有归入 LocalDataErasure 的删/留清单：\(unclassified.sorted())"
        )
    }

    /// 同一个键不能同时在两张清单里——那种矛盾下行为取决于执行顺序。
    func testEraseAndPreserveListsDoNotOverlap() {
        let erasable = Set(LocalDataErasure.erasableUserDefaultsKeys)
        let preserved = Set(LocalDataErasure.preservedUserDefaultsKeys)
        XCTAssertTrue(
            erasable.isDisjoint(with: preserved),
            "同时出现在删与留两张清单里：\(erasable.intersection(preserved).sorted())"
        )
    }

    /// 数据根目录下应用写的文件都要在文件清单里。用真实的写入点反查：
    /// 新加一个 `LightAnchorStorage` 文件却忘了进清单，这条会红。
    func testFileListCoversEveryStorageFileExceptTheDocumentedExceptions() {
        let covered = Set(LocalDataErasure.fileNames)
        // 附件目录、诊断日志各有自己的清理入口；锁文件刻意不删。
        let handledElsewhere: Set<String> = ["assets", "diagnostics.log"]
        let storageFiles = [
            LightAnchorStorage.eventsURL(),
            LightAnchorStorage.assetsURL(),
            LightAnchorStorage.diagnosticsURL(),
            LightAnchorStorage.launchMarkerURL(),
            LightAnchorStorage.memoryChatURL(),
            LightAnchorStorage.recordingsURL(),
            LightAnchorStorage.clipboardHistoryURL()
        ].map(\.lastPathComponent)

        for name in storageFiles where !handledElsewhere.contains(name) {
            XCTAssertTrue(covered.contains(name), "\(name) 不在删除清单里")
        }
    }

    // MARK: - 真删

    /// 端到端：在临时数据根目录里放齐事件日志、对话记录、启动标记，删一次之后
    /// 盘上不能还剩下它们。
    @MainActor
    func testDeleteAllDataRemovesEveryFileUnderTheDataRoot() throws {
        let root = try makeTemporaryRoot()
        let eventsURL = root.appendingPathComponent("events.json")
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: eventsURL))
        _ = workspace.createTarget(name: "写文档")

        for url in LocalDataErasure.fileURLs(in: root) {
            try Data("{}".utf8).write(to: url)
        }
        let defaults = try makeScratchDefaults()

        XCTAssertTrue(workspace.deleteAllData(defaults: defaults))

        for url in LocalDataErasure.fileURLs(in: root) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) 删完还在"
            )
        }
    }

    /// 云端 API Key 与保存的方案必须清空；同一个 blob 里的采集开关必须留下。
    /// 删数据把「不保存剪贴板」退回默认（默认是保存）等于悄悄放宽隐私设置。
    @MainActor
    func testDeleteAllDataClearsCloudCredentialsButKeepsPrivacyToggles() throws {
        let root = try makeTemporaryRoot()
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: root.appendingPathComponent("events.json"))
        )
        let defaults = try makeScratchDefaults()

        var preferences = IntelligencePreferences.default
        preferences.cloudProfiles = [
            CloudProviderProfile(
                name: "自用",
                provider: .anthropic,
                apiProtocol: .anthropicMessages,
                apiKey: "sk-secret",
                chatEndpoint: "https://api.anthropic.com/v1/messages",
                model: "claude-opus-5"
            ),
            CloudProviderProfile(
                name: "公司网关",
                provider: .custom,
                apiProtocol: .openAIChatCompletions,
                apiKey: "",
                chatEndpoint: "https://gateway.internal/v1/chat/completions",
                model: "gpt-4o-mini"
            ),
        ]
        preferences.activeCloudProfileID = preferences.cloudProfiles[0].id
        // 用户收紧过的两个采集开关。
        preferences.saveClipboardContent = false
        preferences.saveTerminalCommands = false
        preferences.save(to: defaults)

        XCTAssertTrue(workspace.deleteAllData(defaults: defaults))

        let after = IntelligencePreferences.load(from: defaults)
        // 方案全清，只留一套空的默认配置（云端引擎必须有一套可指）。
        XCTAssertEqual(after.cloudProfiles.count, 1, "保存的供应商方案没删掉")
        XCTAssertTrue(after.activeCloudProfile.apiKey.isEmpty, "API Key 没删掉")
        XCTAssertEqual(after.activeCloudProfile.provider, .openAI)
        XCTAssertEqual(after.activeCloudProfileID, after.cloudProfiles[0].id)
        XCTAssertFalse(
            after.cloudProfiles.contains { $0.name == "自用" || $0.name == "公司网关" },
            "用户命名的方案还留着"
        )
        XCTAssertFalse(after.saveClipboardContent, "删数据把剪贴板开关放宽回默认了")
        XCTAssertFalse(after.saveTerminalCommands, "删数据把终端开关放宽回默认了")
    }

    /// 内容与缓存键清空，界面偏好留着。
    @MainActor
    func testDeleteAllDataClearsContentKeysAndKeepsInterfacePreferences() throws {
        let root = try makeTemporaryRoot()
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: root.appendingPathComponent("events.json"))
        )
        let defaults = try makeScratchDefaults()

        for key in LocalDataErasure.erasableUserDefaultsKeys {
            defaults.set("填过", forKey: key)
        }
        for key in LocalDataErasure.preservedUserDefaultsKeys {
            defaults.set("填过", forKey: key)
        }

        XCTAssertTrue(workspace.deleteAllData(defaults: defaults))

        for key in LocalDataErasure.erasableUserDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) 删完还在")
        }
        for key in LocalDataErasure.preservedUserDefaultsKeys
        where key != IntelligencePreferences.storageKey {
            XCTAssertNotNil(defaults.object(forKey: key), "\(key) 不该被删")
        }
    }

    // MARK: - 工具

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("light-anchor-erasure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// 独立的 UserDefaults 域：测试绝不能碰到跑测试这台机器上的真实偏好。
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        // 只捕域名，不捕 UserDefaults 实例：跨隔离域传实例会被并发检查拦下。
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    /// 扫源码里的偏好键字面量。约定：应用自己的键都带 `lightanchor.` 前缀，
    /// 另有几个不带前缀的键（系统键与自有命名的）单列。
    private func preferenceKeyLiteralsInSource() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var keys: Set<String> = [
            IntelligencePreferences.storageKey,
            AppLanguage.appleLanguagesKey,
            LightAnchorThemeController.storageKey
        ]
        let pattern = try NSRegularExpression(pattern: "\"(lightanchor\\.[A-Za-z0-9_.]*)\"")
        // 接入脚本的文件名同样是 lightanchor.xxx，按扩展名排除。
        let scriptExtensions = ["ts", "js", "zsh", "sh", "py", "json", "plist"]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[captured])
                let suffix = literal.split(separator: ".").last.map(String.init) ?? ""
                guard !scriptExtensions.contains(suffix) else { continue }
                keys.insert(literal)
            }
        }
        return keys
    }
}
