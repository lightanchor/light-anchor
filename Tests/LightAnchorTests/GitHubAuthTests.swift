import Foundation
import XCTest
@testable import LightAnchor

/// Device Flow 状态机测试：HTTP 全部走假实现，令牌存内存，不碰网络与钥匙串。
final class GitHubAuthTests: XCTestCase {
    func testClientIDIsBundledAndEnvironmentCanOverrideIt() {
        XCTAssertEqual(GitHubAuthService.configuredClientID(environment: [:]), "Ov23liMYswWDP7qhcsym")
        XCTAssertEqual(GitHubAuthService.configuredClientID(environment: [
            "LIGHTANCHOR_GITHUB_CLIENT_ID": " \n"
        ]), GitHubAuthService.bundledClientID)
        XCTAssertEqual(GitHubAuthService.configuredClientID(environment: [
            "LIGHTANCHOR_GITHUB_CLIENT_ID": " test-client \n"
        ]), "test-client")
    }

    func testDefaultDeviceFlowUsesConfiguredClientID() async throws {
        let poster = ScriptedPoster([deviceCodeResponse])
        let service = GitHubAuthService(poster: poster, tokenStore: MemoryTokenStore())
        _ = try await service.begin()
        XCTAssertTrue(GitHubAuthService.isConfigured)
        XCTAssertEqual(poster.requests.first?.form["client_id"], GitHubAuthService.clientID)
    }

    /// 按调用顺序回放预置响应的假 HTTP。
    private final class ScriptedPoster: GitHubHTTPPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String]
        private(set) var requests: [(url: URL, form: [String: String])] = []
        private(set) var apiCalls: [(method: String, url: URL)] = []
        private var apiResponses: [(status: Int, body: String)]

        init(_ responses: [String], apiResponses: [(status: Int, body: String)] = []) {
            self.responses = responses
            self.apiResponses = apiResponses
        }

        func post(to url: URL, form: [String: String]) async throws -> Data {
            let next: String? = lock.withLock {
                requests.append((url, form))
                return responses.isEmpty ? nil : responses.removeFirst()
            }
            guard let next else {
                throw GitHubAuthError.serverError("脚本响应用完了")
            }
            return Data(next.utf8)
        }

        func api(_ method: String, _ url: URL, json: [String: Any]?, bearerToken: String) async throws -> (status: Int, data: Data) {
            let next: (status: Int, body: String)? = lock.withLock {
                apiCalls.append((method, url))
                return apiResponses.isEmpty ? nil : apiResponses.removeFirst()
            }
            guard let next else {
                throw GitHubAuthError.serverError("脚本 API 响应用完了")
            }
            return (next.status, Data(next.body.utf8))
        }
    }

    private final class MemoryTokenStore: GitHubTokenStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?

        func readToken() -> String? {
            lock.lock(); defer { lock.unlock() }
            return token
        }

        func writeToken(_ newToken: String) throws {
            lock.lock(); defer { lock.unlock() }
            token = newToken
        }

        func eraseToken() {
            lock.lock(); defer { lock.unlock() }
            token = nil
        }
    }

    private let deviceCodeResponse = """
    {"device_code":"dev-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}
    """

    func testBeginParsesDeviceAuthorization() async throws {
        let poster = ScriptedPoster([deviceCodeResponse])
        let service = GitHubAuthService(poster: poster, tokenStore: MemoryTokenStore())

        let authorization = try await service.begin(clientID: "test-client")
        XCTAssertEqual(authorization.userCode, "WDJB-MJHT")
        XCTAssertEqual(authorization.deviceCode, "dev-123")
        XCTAssertEqual(authorization.verificationURL.host, "github.com")
        XCTAssertEqual(poster.requests.first?.form["client_id"], "test-client")
        XCTAssertEqual(poster.requests.first?.form["scope"], "repo")
    }

    func testBeginWithoutClientIDThrowsNotConfigured() async {
        let service = GitHubAuthService(poster: ScriptedPoster([]), tokenStore: MemoryTokenStore())
        do {
            _ = try await service.begin(clientID: "")
            XCTFail("没配 client id 应该抛错")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testDisabledDeviceFlowGivesActionableError() async {
        let poster = ScriptedPoster([
            #"{"error":"device_flow_disabled","error_description":"Device Flow must be explicitly enabled for this App"}"#
        ])
        let service = GitHubAuthService(poster: poster, tokenStore: MemoryTokenStore())
        do {
            _ = try await service.begin()
            XCTFail("Device Flow 未开启时必须报错")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .deviceFlowDisabled)
            XCTAssertTrue(error.localizedDescription.contains("OAuth Apps"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertFalse(service.isConnected)
    }

    func testWaitForTokenPollsThroughPendingThenStoresToken() async throws {
        let poster = ScriptedPoster([
            deviceCodeResponse,
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down"}"#,
            #"{"access_token":"gho_abc123","token_type":"bearer","scope":"repo"}"#
        ])
        let store = MemoryTokenStore()
        let service = GitHubAuthService(poster: poster, tokenStore: store)

        let authorization = try await service.begin(clientID: "test-client")
        let token = try await service.waitForToken(authorization, clientID: "test-client")

        XCTAssertEqual(token, "gho_abc123")
        XCTAssertEqual(store.readToken(), "gho_abc123", "令牌应存进保管处")
        XCTAssertTrue(service.isConnected)
    }

    func testDeniedStopsPollingWithError() async throws {
        let poster = ScriptedPoster([deviceCodeResponse, #"{"error":"access_denied"}"#])
        let service = GitHubAuthService(poster: poster, tokenStore: MemoryTokenStore())
        let authorization = try await service.begin(clientID: "test-client")
        do {
            _ = try await service.waitForToken(authorization, clientID: "test-client")
            XCTFail("拒绝授权应该抛错")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .denied)
        }
    }

    func testExpiredTokenSurfacesAsExpired() async throws {
        let poster = ScriptedPoster([deviceCodeResponse, #"{"error":"expired_token"}"#])
        let service = GitHubAuthService(poster: poster, tokenStore: MemoryTokenStore())
        let authorization = try await service.begin(clientID: "test-client")
        do {
            _ = try await service.pollOnce(authorization, clientID: "test-client")
            XCTFail("过期应该抛错")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .expired)
        }
    }

    func testDisconnectErasesToken() throws {
        let store = MemoryTokenStore()
        try store.writeToken("gho_old")
        let service = GitHubAuthService(poster: ScriptedPoster([]), tokenStore: store)
        XCTAssertTrue(service.isConnected)
        service.disconnect()
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(store.readToken())
    }

    // MARK: - 备份仓库

    func testEnsureBackupRepoCreatesPrivateRepository() async throws {
        let store = MemoryTokenStore()
        try store.writeToken("gho_token")
        let poster = ScriptedPoster([], apiResponses: [
            (201, #"{"html_url":"https://github.com/me/light-anchor-backup"}"#),
        ])
        let service = GitHubAuthService(poster: poster, tokenStore: store)

        let outcome = try await service.ensurePrivateBackupRepository()
        XCTAssertEqual(outcome, .created(URL(string: "https://github.com/me/light-anchor-backup")!))
        // 只发建库请求：成功响应里自带地址，不需要再查账号。
        XCTAssertEqual(poster.apiCalls.count, 1)
        XCTAssertEqual(poster.apiCalls.first?.method, "POST")
    }

    func testEnsureBackupRepoAdoptsExistingRepositoryOn422() async throws {
        // 换机/重装路径：同名库已存在（422），补查账号名后直接采用它。
        let store = MemoryTokenStore()
        try store.writeToken("gho_token")
        let poster = ScriptedPoster([], apiResponses: [
            (422, #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#),
            (200, #"{"login":"me"}"#),
        ])
        let service = GitHubAuthService(poster: poster, tokenStore: store)

        let outcome = try await service.ensurePrivateBackupRepository()
        XCTAssertEqual(outcome, .alreadyExisted(URL(string: "https://github.com/me/light-anchor-backup")!))
        XCTAssertEqual(poster.apiCalls.map(\.method), ["POST", "GET"])
    }

    func testEnsureBackupRepoRequiresConnection() async throws {
        let service = GitHubAuthService(poster: ScriptedPoster([]), tokenStore: MemoryTokenStore())
        do {
            _ = try await service.ensurePrivateBackupRepository()
            XCTFail("没连接时不该建库")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    func testEnsureBackupRepoSurfacesGitHubMessageOnFailure() async throws {
        let store = MemoryTokenStore()
        try store.writeToken("gho_token")
        let poster = ScriptedPoster([], apiResponses: [
            (403, #"{"message":"API rate limit exceeded"}"#),
        ])
        let service = GitHubAuthService(poster: poster, tokenStore: store)
        do {
            _ = try await service.ensurePrivateBackupRepository()
            XCTFail("403 应该抛错")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .serverError("API rate limit exceeded"))
        }
    }

    // MARK: - 认证头注入

    func testAuthEnvironmentOnlyAppliesToGitHubHTTPSRemotes() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAuthTests-\(UUID().uuidString)", isDirectory: true)
        let service = GitSnapshotService(
            rootURL: root,
            userDefaults: UserDefaults(suiteName: "light-anchor.tests.\(UUID().uuidString)")!,
            tokenProvider: { "gho_secret" }
        )

        // github.com 的 https 远端：带认证头，令牌不出现在明文里。
        let env = service.authEnvironment(for: URL(string: "https://github.com/me/data.git")!)
        XCTAssertEqual(env["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraheader")
        let value = try? XCTUnwrap(env["GIT_CONFIG_VALUE_0"])
        XCTAssertTrue(value?.hasPrefix("Authorization: Basic ") == true)
        XCTAssertFalse(value?.contains("gho_secret") == true, "令牌必须是 base64 形式，不能明文")
        let base64 = value?.replacingOccurrences(of: "Authorization: Basic ", with: "") ?? ""
        let decoded = String(data: Data(base64Encoded: base64) ?? Data(), encoding: .utf8)
        XCTAssertEqual(decoded, "x-access-token:gho_secret")

        // 其他远端一概不带：file://、别家 https、ssh。
        XCTAssertTrue(service.authEnvironment(for: URL(string: "file:///tmp/bare.git")!).isEmpty)
        XCTAssertTrue(service.authEnvironment(for: URL(string: "https://gitlab.com/me/data.git")!).isEmpty)

        // 没有令牌时 github 远端也不带。
        let anonymous = GitSnapshotService(
            rootURL: root,
            userDefaults: UserDefaults(suiteName: "light-anchor.tests.\(UUID().uuidString)")!,
            tokenProvider: { nil }
        )
        XCTAssertTrue(anonymous.authEnvironment(for: URL(string: "https://github.com/me/data.git")!).isEmpty)
    }
}
