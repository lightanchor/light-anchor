import Foundation
import Security

// 云端 API Key 的存放处。
//
// Key 以前和其他偏好一起 JSON 编码进 UserDefaults 的 `intelligence.preferences`
// blob：明文落盘、随备份 zip 一起被带走。现在 blob 里只剩方案的「壳」（名字、
// 端点、模型），Key 单独放进钥匙串，按方案 id 一把一把存。

/// 按方案 id 存取 API Key。空 Key 等于删除：方案本来就允许不带 Key。
protocol CloudAPIKeyStoring: Sendable {
    func key(for profileID: UUID) -> String?
    func setKey(_ key: String?, for profileID: UUID)
    func removeAll()
}

/// 进程内的存放处：单测用，绝不碰跑测试这台机器的真实钥匙串。
final class InMemoryAPIKeyStore: CloudAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    init() {}

    func key(for profileID: UUID) -> String? {
        lock.withLock { storage[profileID] }
    }

    func setKey(_ key: String?, for profileID: UUID) {
        lock.withLock {
            if let key, !key.isEmpty {
                storage[profileID] = key
            } else {
                storage.removeValue(forKey: profileID)
            }
        }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}

/// 系统钥匙串：通用密码项，service 固定、account 是方案 id。
///
/// 用的是登录钥匙串（文件型）而不是 data-protection 钥匙串：后者要求应用带
/// application-identifier 权限，`swift run` 与 ad-hoc 签名的构建都没有，会直接
/// 拒绝写入。项目不同步到 iCloud 钥匙串；`kSecAttrAccessible` 只对
/// data-protection 钥匙串有意义，这里不带。
final class KeychainAPIKeyStore: CloudAPIKeyStoring {
    static let defaultService = "com.lightanchor.cloud-api-key"

    private let service: String

    init(service: String = KeychainAPIKeyStore.defaultService) {
        self.service = service
    }

    func key(for profileID: UUID) -> String? {
        var query = baseQuery(account: profileID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    func setKey(_ key: String?, for profileID: UUID) {
        let query = baseQuery(account: profileID.uuidString)
        guard let key, !key.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Light Anchor 云端 API Key"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func removeAll() {
        var query = baseQuery(account: nil)
        // 文件型钥匙串的 SecItemDelete 默认只删一条；限定「全部」才真清空。
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}

/// 全应用共用的 Key 存放处。
///
/// 默认落钥匙串；XCTest 进程里换成内存实现——现有测试大量「造一份带 Key 的
/// 偏好、存进临时 UserDefaults 再读回」，这些不该在跑测试的机器上留下钥匙串项。
/// 测试也可以显式换一个实现（`shared` 可写，用完换回原来的）。
enum CloudAPIKeyStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: any CloudAPIKeyStoring = {
        if isRunningUnderXCTest {
            return InMemoryAPIKeyStore()
        }
        return KeychainAPIKeyStore()
    }()

    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var shared: any CloudAPIKeyStoring {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
