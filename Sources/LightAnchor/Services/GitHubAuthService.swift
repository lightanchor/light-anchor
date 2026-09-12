import Foundation
import Security

/// GitHub Device Flow 认证。
///
/// 流程：`begin()` 拿到一次性配对码（用户在 github.com/login/device 输入），
/// `waitForToken()` 轮询直到用户完成授权，令牌存进 Keychain。之后 push/sync
/// 对 github.com 的远端自动带上令牌（见 `GitSnapshotService.authEnvironment`）。
///
/// 令牌只住在 Keychain：不进 UserDefaults、不进 git config、不进备份 zip。
/// 「删除全部本地数据」时由 `eraseStoredToken()` 一并抹掉。
///
struct GitHubDeviceAuthorization: Equatable {
    let deviceCode: String
    /// 给用户看的配对码，如 `WDJB-MJHT`。
    let userCode: String
    /// 用户要打开的网址（github.com/login/device）。
    let verificationURL: URL
    /// 轮询间隔（秒），GitHub 要求不快于它。
    let interval: TimeInterval
    let expiresAt: Date
}

enum GitHubAuthError: LocalizedError, Equatable {
    case notConfigured
    case deviceFlowDisabled
    case authorizationPending
    case expired
    case denied
    case notConnected
    case malformedResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: tr("github_not_configured")
        case .deviceFlowDisabled: tr("github_device_flow_disabled")
        case .authorizationPending: tr("github_waiting_for_you")
        case .expired: tr("github_code_expired")
        case .denied: tr("github_access_denied")
        case .notConnected: tr("github_not_connected")
        case .malformedResponse: tr("github_unexpected_reply")
        case .serverError(let message): message
        }
    }
}

/// 发送表单 POST 并取回 JSON 数据。注入点：测试用假实现，不碰网络。
protocol GitHubHTTPPosting: Sendable {
    /// 表单 POST（Device Flow 端点专用，无需令牌）。
    func post(to url: URL, form: [String: String]) async throws -> Data
    /// REST API 调用（Bearer 令牌），返回 HTTP 状态码让调用方区分 201/404/422。
    func api(_ method: String, _ url: URL, json: [String: Any]?, bearerToken: String) async throws -> (status: Int, data: Data)
}

struct URLSessionGitHubPoster: GitHubHTTPPosting {
    func post(to url: URL, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    func api(_ method: String, _ url: URL, json: [String: Any]?, bearerToken: String) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }
}

/// 令牌保管处。生产走 Keychain；测试用内存实现。
protocol GitHubTokenStoring: Sendable {
    func readToken() -> String?
    func writeToken(_ token: String) throws
    func eraseToken()
}

struct KeychainGitHubTokenStore: GitHubTokenStoring {
    static let service = "com.lightanchor.github-token"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "github"
        ]
    }

    func readToken() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeToken(_ token: String) throws {
        eraseToken()
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHubAuthError.serverError(tr("github_keychain_failed"))
        }
    }

    func eraseToken() {
        SecItemDelete(query as CFDictionary)
    }
}

final class GitHubAuthService: Sendable {
    static let bundledClientID = "Ov23liMYswWDP7qhcsym"

    static var clientID: String {
        configuredClientID(environment: ProcessInfo.processInfo.environment)
    }

    static func configuredClientID(environment: [String: String]) -> String {
        guard let override = environment["LIGHTANCHOR_GITHUB_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
        else { return bundledClientID }
        return override
    }

    static var isConfigured: Bool { !clientID.isEmpty }

    private let poster: GitHubHTTPPosting
    private let tokenStore: GitHubTokenStoring
    private let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    init(
        poster: GitHubHTTPPosting = URLSessionGitHubPoster(),
        tokenStore: GitHubTokenStoring = KeychainGitHubTokenStore()
    ) {
        self.poster = poster
        self.tokenStore = tokenStore
    }

    var storedToken: String? { tokenStore.readToken() }
    var isConnected: Bool { storedToken != nil }

    func disconnect() {
        tokenStore.eraseToken()
    }

    /// 「删除全部本地数据」的钩子：不管服务实例在不在，都要能抹掉令牌。
    static func eraseStoredToken() {
        KeychainGitHubTokenStore().eraseToken()
    }

    // MARK: - Device Flow

    /// 第一步：要一个配对码。
    func begin(clientID: String = GitHubAuthService.clientID) async throws -> GitHubDeviceAuthorization {
        guard !clientID.isEmpty else { throw GitHubAuthError.notConfigured }
        let data = try await poster.post(
            to: deviceCodeURL,
            form: ["client_id": clientID, "scope": "repo"]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubAuthError.malformedResponse
        }
        if let error = json["error"] as? String {
            if error == "device_flow_disabled" { throw GitHubAuthError.deviceFlowDisabled }
            throw GitHubAuthError.serverError((json["error_description"] as? String) ?? error)
        }
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String,
              let verificationURL = URL(string: uri)
        else {
            throw GitHubAuthError.malformedResponse
        }
        let interval = (json["interval"] as? TimeInterval) ?? 5
        let expiresIn = (json["expires_in"] as? TimeInterval) ?? 900
        return GitHubDeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: interval,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// 单次询问「用户授权了吗」。授权完成时令牌已存好并返回。
    /// 还没完成抛 `.authorizationPending`（调用方按 `interval` 继续轮询）。
    @discardableResult
    func pollOnce(
        _ authorization: GitHubDeviceAuthorization,
        clientID: String = GitHubAuthService.clientID
    ) async throws -> String {
        guard !clientID.isEmpty else { throw GitHubAuthError.notConfigured }
        let data = try await poster.post(
            to: accessTokenURL,
            form: [
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubAuthError.malformedResponse
        }
        if let token = json["access_token"] as? String {
            try tokenStore.writeToken(token)
            return token
        }
        switch json["error"] as? String {
        case "authorization_pending", "slow_down":
            throw GitHubAuthError.authorizationPending
        case "expired_token":
            throw GitHubAuthError.expired
        case "access_denied":
            throw GitHubAuthError.denied
        case let other?:
            throw GitHubAuthError.serverError(other)
        default:
            throw GitHubAuthError.malformedResponse
        }
    }

    /// 一直轮询到用户完成授权（或过期/拒绝）。
    @discardableResult
    func waitForToken(
        _ authorization: GitHubDeviceAuthorization,
        clientID: String = GitHubAuthService.clientID
    ) async throws -> String {
        while Date() < authorization.expiresAt {
            do {
                return try await pollOnce(authorization, clientID: clientID)
            } catch GitHubAuthError.authorizationPending {
                try await Task.sleep(for: .seconds(max(authorization.interval, 1)))
            }
        }
        throw GitHubAuthError.expired
    }

    // MARK: - 备份仓库

    /// 「创建私有备份仓库」按钮的结果：新建，或发现同名库已存在直接采用。
    enum BackupRepoOutcome: Equatable {
        case created(URL)
        case alreadyExisted(URL)
    }

    static let backupRepositoryName = "light-anchor-backup"

    /// 一键备好备份仓库：POST /user/repos 建私有库；同名已存在（422）就直接用它
    /// ——那是换机/重装后的接入路径。只填地址，不动数据（首次同步仍会先确认出机）。
    func ensurePrivateBackupRepository(
        named name: String = GitHubAuthService.backupRepositoryName
    ) async throws -> BackupRepoOutcome {
        guard let token = tokenStore.readToken() else { throw GitHubAuthError.notConnected }
        let createURL = URL(string: "https://api.github.com/user/repos")!
        let (status, data) = try await poster.api(
            "POST", createURL,
            json: ["name": name, "private": true],
            bearerToken: token
        )
        if status == 201,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let html = json["html_url"] as? String, let url = URL(string: html) {
            return .created(url)
        }
        if status == 422 {
            // 422 的响应里没有账号名，补一次 GET /user 拼出已存在仓库的地址。
            let login = try await authenticatedUserLogin(token: token)
            guard let url = URL(string: "https://github.com/\(login)/\(name)") else {
                throw GitHubAuthError.malformedResponse
            }
            return .alreadyExisted(url)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = json?["message"] as? String
        throw GitHubAuthError.serverError(message ?? tr("github_unexpected_reply"))
    }

    private func authenticatedUserLogin(token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/user")!
        let (status, data) = try await poster.api("GET", url, json: nil, bearerToken: token)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String
        else { throw GitHubAuthError.malformedResponse }
        return login
    }
}
