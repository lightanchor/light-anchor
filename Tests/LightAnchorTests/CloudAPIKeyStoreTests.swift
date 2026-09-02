import Foundation
import XCTest
@testable import LightAnchor

/// API Key 不再随偏好 blob 落 UserDefaults：blob 里只剩方案的壳，Key 单独进
/// 钥匙串（测试进程里换成内存实现）。这里守的是「blob 不含 Key、读回来 Key 还在、
/// 老数据第一次读就搬家、删数据把 Key 一起删」。
final class CloudAPIKeyStoreTests: XCTestCase {
    private var store: InMemoryAPIKeyStore!

    override func setUp() {
        super.setUp()
        store = InMemoryAPIKeyStore()
        CloudAPIKeyStore.shared = store
    }

    override func tearDown() {
        CloudAPIKeyStore.resetOverride()
        store = nil
        super.tearDown()
    }

    // MARK: - 存放处本身

    func testInMemoryStoreSetsReadsDeletesAndListsKeys() {
        let a = UUID()
        let b = UUID()

        store.setKey("sk-a", for: a)
        store.setKey("sk-b", for: b)
        XCTAssertEqual(store.key(for: a), "sk-a")
        XCTAssertEqual(store.key(for: b), "sk-b")
        XCTAssertEqual(Set(store.allProfileIDs()), [a, b])

        // 空 Key / nil 都是删除。
        store.setKey("", for: a)
        XCTAssertNil(store.key(for: a))
        store.setKey(nil, for: b)
        XCTAssertNil(store.key(for: b))
        XCTAssertTrue(store.allProfileIDs().isEmpty)

        store.setKey("sk-a", for: a)
        store.removeAll()
        XCTAssertNil(store.key(for: a))
        XCTAssertTrue(store.allProfileIDs().isEmpty)
    }

    func testSharedStoreIsInMemoryUnderXCTest() {
        CloudAPIKeyStore.resetOverride()
        XCTAssertTrue(CloudAPIKeyStore.isRunningUnderXCTest)
        XCTAssertTrue(
            CloudAPIKeyStore.shared is InMemoryAPIKeyStore,
            "测试进程里绝不能碰真实钥匙串"
        )
    }

    // MARK: - 方案编码

    func testProfileEncodingOmitsAPIKeyByDefault() throws {
        let profile = CloudProviderProfile(
            name: "自用",
            provider: .openAI,
            apiProtocol: .openAIChatCompletions,
            apiKey: "sk-secret",
            chatEndpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-5.6-luna"
        )

        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["apiKey"], "默认编码不该带 Key")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sk-secret"))

        // 解码回来：壳完整、Key 为空（由 load 从存放处补）。
        let decoded = try JSONDecoder().decode(CloudProviderProfile.self, from: data)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, "自用")
        XCTAssertEqual(decoded.chatEndpoint, profile.chatEndpoint)
        XCTAssertEqual(decoded.model, "gpt-5.6-luna")
        XCTAssertTrue(decoded.apiKey.isEmpty)
    }

    func testProfileEncodingIncludesAPIKeyOnlyWhenAskedExplicitly() throws {
        let profile = CloudProviderProfile(
            name: "自用",
            provider: .openAI,
            apiProtocol: .openAIChatCompletions,
            apiKey: "sk-secret",
            chatEndpoint: "https://api.openai.com/v1/chat/completions",
            model: "m"
        )
        let encoder = JSONEncoder()
        encoder.userInfo[CloudProviderProfile.encodeAPIKeyUserInfoKey] = true

        let decoded = try JSONDecoder().decode(
            CloudProviderProfile.self,
            from: try encoder.encode(profile)
        )
        XCTAssertEqual(decoded.apiKey, "sk-secret")
    }

    // MARK: - 偏好存取

    func testSaveKeepsKeyOutOfDefaultsAndLoadRestoresItFromStore() throws {
        let defaults = try makeScratchDefaults()
        var preferences = IntelligencePreferences.default
        preferences.activeCloudProfile.apiKey = "sk-secret"
        preferences.activeCloudProfile.model = "m"
        let profileID = preferences.activeCloudProfileID

        preferences.save(to: defaults)

        let blob = try XCTUnwrap(defaults.data(forKey: IntelligencePreferences.storageKey))
        XCTAssertFalse(
            String(decoding: blob, as: UTF8.self).contains("sk-secret"),
            "UserDefaults blob 里不许出现 Key"
        )
        XCTAssertEqual(store.key(for: profileID), "sk-secret")

        let loaded = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(loaded.activeCloudProfileID, profileID)
        XCTAssertEqual(loaded.activeCloudProfile.apiKey, "sk-secret")
        XCTAssertEqual(loaded.activeCloudProfile.model, "m")
    }

    func testLoadMigratesLegacyBlobThatStillCarriesKeys() throws {
        let defaults = try makeScratchDefaults()
        let profileID = UUID()
        // 钥匙串之前的版本写出的 blob：方案里带着 apiKey。
        let legacy = """
        {"engine":"cloud","cloudProfiles":[{"id":"\(profileID.uuidString)","name":"自用",
        "provider":"openAI","apiProtocol":"openAIChatCompletions","apiKey":"sk-legacy",
        "chatEndpoint":"https://api.openai.com/v1/chat/completions","model":"m"}],
        "activeCloudProfileID":"\(profileID.uuidString)"}
        """
        defaults.set(Data(legacy.utf8), forKey: IntelligencePreferences.storageKey)

        let loaded = IntelligencePreferences.load(from: defaults)

        XCTAssertEqual(loaded.activeCloudProfileID, profileID)
        XCTAssertEqual(loaded.activeCloudProfile.apiKey, "sk-legacy", "升级不能把用户填过的 Key 吞掉")
        XCTAssertEqual(store.key(for: profileID), "sk-legacy", "Key 要搬进存放处")
        let rewritten = try XCTUnwrap(defaults.data(forKey: IntelligencePreferences.storageKey))
        XCTAssertFalse(
            String(decoding: rewritten, as: UTF8.self).contains("sk-legacy"),
            "读到老 blob 要立刻把不含 Key 的版本写回"
        )
        // 再读一次：Key 从存放处来，id 不变。
        let again = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(again.activeCloudProfileID, profileID)
        XCTAssertEqual(again.activeCloudProfile.apiKey, "sk-legacy")
    }

    func testLoadMigratesFlatZeroPointOneCloudFields() throws {
        let defaults = try makeScratchDefaults()
        let legacy = """
        {"engine":"cloud","cloudAPIKey":"sk-flat","cloudModel":"gpt-4o-mini"}
        """
        defaults.set(Data(legacy.utf8), forKey: IntelligencePreferences.storageKey)

        let loaded = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(loaded.activeCloudProfile.apiKey, "sk-flat")
        XCTAssertEqual(loaded.activeCloudProfile.model, "gpt-4o-mini")
        XCTAssertEqual(store.key(for: loaded.activeCloudProfileID), "sk-flat")

        let rewritten = String(
            decoding: try XCTUnwrap(defaults.data(forKey: IntelligencePreferences.storageKey)),
            as: UTF8.self
        )
        XCTAssertFalse(rewritten.contains("sk-flat"))
        XCTAssertFalse(rewritten.contains("cloudAPIKey"))
        // 迁移后的 id 稳定：第二次读还是同一套方案。
        XCTAssertEqual(IntelligencePreferences.load(from: defaults).activeCloudProfileID,
                       loaded.activeCloudProfileID)
    }

    func testEraseCloudConfigurationRemovesEveryStoredKey() throws {
        let defaults = try makeScratchDefaults()
        var preferences = IntelligencePreferences.default
        preferences.activeCloudProfile.apiKey = "sk-a"
        preferences.addCloudProfile(provider: .anthropic)
        preferences.activeCloudProfile.apiKey = "sk-b"
        preferences.save(to: defaults)
        XCTAssertEqual(store.allProfileIDs().count, 2)
        // 存放处里还有一把不属于任何当前方案的孤儿 Key，也要一起清。
        store.setKey("sk-orphan", for: UUID())

        IntelligencePreferences.eraseCloudConfiguration(in: defaults)

        XCTAssertTrue(store.allProfileIDs().isEmpty, "删除全部本地数据必须清空所有 Key")
        let after = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(after.cloudProfiles.count, 1)
        XCTAssertTrue(after.activeCloudProfile.apiKey.isEmpty)
    }

    func testSavingAfterRemovingAProfilePrunesItsKey() throws {
        let defaults = try makeScratchDefaults()
        var preferences = IntelligencePreferences.default
        let firstID = preferences.activeCloudProfileID
        preferences.activeCloudProfile.apiKey = "sk-a"
        let secondID = preferences.addCloudProfile(provider: .anthropic)
        preferences.activeCloudProfile.apiKey = "sk-b"
        preferences.save(to: defaults)
        XCTAssertEqual(store.key(for: secondID), "sk-b")

        preferences.removeCloudProfile(id: secondID)
        preferences.save(to: defaults)

        XCTAssertNil(store.key(for: secondID), "删掉的方案不该在钥匙串里留下 Key")
        XCTAssertEqual(store.key(for: firstID), "sk-a")
    }

    func testDuplicatedProfileCarriesKeyToItsOwnID() throws {
        let defaults = try makeScratchDefaults()
        var preferences = IntelligencePreferences.default
        preferences.activeCloudProfile.apiKey = "sk-a"
        let originalID = preferences.activeCloudProfileID

        let copyID = preferences.duplicateActiveCloudProfile()
        preferences.save(to: defaults)

        XCTAssertNotEqual(copyID, originalID)
        XCTAssertEqual(store.key(for: originalID), "sk-a")
        XCTAssertEqual(store.key(for: copyID), "sk-a")
        let loaded = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(loaded.cloudProfiles.map(\.apiKey), ["sk-a", "sk-a"])
    }

    func testClearingAKeyInTheEditorDeletesItFromTheStore() throws {
        let defaults = try makeScratchDefaults()
        var preferences = IntelligencePreferences.default
        preferences.activeCloudProfile.apiKey = "sk-a"
        preferences.save(to: defaults)

        preferences.activeCloudProfile.apiKey = ""
        preferences.save(to: defaults)

        XCTAssertNil(store.key(for: preferences.activeCloudProfileID))
        XCTAssertTrue(IntelligencePreferences.load(from: defaults).activeCloudProfile.apiKey.isEmpty)
    }

    // MARK: - 隐私默认值

    func testClipboardCaptureIsOffByDefault() {
        XCTAssertFalse(
            IntelligencePreferences.default.saveClipboardContent,
            "剪贴板最容易装下别人的信息：默认不存，用户自己开"
        )
    }

    // MARK: - 工具

    /// 独立的 UserDefaults 域：测试绝不能碰跑测试这台机器上的真实偏好。
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "light-anchor.tests.keystore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
}
