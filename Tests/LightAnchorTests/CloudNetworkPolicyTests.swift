import Foundation
import XCTest
@testable import LightAnchor

/// 云端请求的出网规则：Key 只走 https（本机 http 例外）、不跟换主机/降协议的
/// 重定向、流式回答与网页抓取都有大小上限。全部在拼请求这一步就能验，不出网。
final class CloudNetworkPolicyTests: XCTestCase {

    // MARK: - 本机与明文

    func testLoopbackHostsAreRecognised() {
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "::1", "[::1]"] {
            XCTAssertTrue(CloudNetworkPolicy.isLoopback(host: host), host)
        }
        for host in ["example.com", "192.168.1.10", "10.0.0.1", "", "localhost.example"] {
            XCTAssertFalse(CloudNetworkPolicy.isLoopback(host: host), host)
        }
        XCTAssertFalse(CloudNetworkPolicy.isLoopback(host: nil))
    }

    func testInsecureRemoteMeansPlainHTTPToANonLoopbackHost() {
        XCTAssertTrue(CloudNetworkPolicy.isInsecureRemote(endpoint: "http://api.example.com/v1"))
        XCTAssertTrue(CloudNetworkPolicy.isInsecureRemote(endpoint: "http://192.168.1.10:11434/v1"))
        XCTAssertFalse(CloudNetworkPolicy.isInsecureRemote(endpoint: "http://localhost:11434/v1"))
        XCTAssertFalse(CloudNetworkPolicy.isInsecureRemote(endpoint: "http://127.0.0.1:1234/v1"))
        XCTAssertFalse(CloudNetworkPolicy.isInsecureRemote(endpoint: "https://api.example.com/v1"))
        // 解析不出 URL 不算「不安全」，那是另一种错（invalidEndpoint）。
        XCTAssertFalse(CloudNetworkPolicy.isInsecureRemote(endpoint: "not-an-url"))
        XCTAssertFalse(CloudNetworkPolicy.isInsecureRemote(endpoint: ""))
    }

    func testAPIKeyTransportValidation() throws {
        let remoteHTTP = URL(string: "http://api.example.com/v1/chat/completions")!
        let loopbackHTTP = URL(string: "http://localhost:11434/v1/chat/completions")!
        let https = URL(string: "https://api.example.com/v1/chat/completions")!

        XCTAssertThrowsError(
            try CloudNetworkPolicy.validateAPIKeyTransport(url: remoteHTTP, apiKey: "sk-test")
        ) { error in
            XCTAssertEqual(
                error as? CloudNetworkPolicy.Error,
                .apiKeyOverInsecureTransport(host: "api.example.com")
            )
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        // 只有空白的 Key 等于没有 Key。
        XCTAssertNoThrow(try CloudNetworkPolicy.validateAPIKeyTransport(url: remoteHTTP, apiKey: "  "))
        XCTAssertNoThrow(try CloudNetworkPolicy.validateAPIKeyTransport(url: remoteHTTP, apiKey: ""))
        XCTAssertNoThrow(try CloudNetworkPolicy.validateAPIKeyTransport(url: loopbackHTTP, apiKey: "sk-test"))
        XCTAssertNoThrow(try CloudNetworkPolicy.validateAPIKeyTransport(url: https, apiKey: "sk-test"))
    }

    func testMakeRequestRefusesToAttachKeyOverPlainHTTPToRemoteHost() {
        XCTAssertThrowsError(try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "http://api.example.com/v1/chat/completions",
            model: "m",
            apiProtocol: .openAIChatCompletions,
            system: "s",
            user: "u",
            jsonSchemaName: nil,
            jsonSchema: nil
        )) { error in
            XCTAssertTrue(error is CloudNetworkPolicy.Error, "\(error)")
        }
    }

    func testMakeRequestStillAllowsPlainHTTPWithoutKeyAndToLoopbackWithKey() throws {
        // 免鉴权网关：http 但没有 Key，照发。
        let keyless = try CloudIntelligenceEngine.makeRequest(
            apiKey: "",
            endpoint: "http://gateway.internal/v1/chat/completions",
            model: "m",
            apiProtocol: .openAIChatCompletions,
            system: "s",
            user: "u",
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        XCTAssertNil(keyless.value(forHTTPHeaderField: "Authorization"))

        // Ollama / LM Studio：本机 http 带 Key 也行。
        let local = try CloudIntelligenceEngine.makeRequest(
            apiKey: "ollama",
            endpoint: "http://localhost:11434/v1/chat/completions",
            model: "llama3",
            apiProtocol: .openAIChatCompletions,
            system: "s",
            user: "u",
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        XCTAssertEqual(local.value(forHTTPHeaderField: "Authorization"), "Bearer ollama")
        XCTAssertEqual(local.url?.host, "localhost")
    }

    func testModelCatalogRefusesKeyOverPlainHTTPBeforeTouchingTheNetwork() async {
        // 192.0.2.0/24 是文档保留网段：若真发出去只会超时，所以必须在发出前就抛。
        do {
            _ = try await CloudModelCatalog().fetchModels(
                apiKey: "sk-test",
                endpoint: "http://192.0.2.1/v1/models"
            )
            XCTFail("带 Key 的明文请求不该发出去")
        } catch {
            XCTAssertEqual(
                error as? CloudNetworkPolicy.Error,
                .apiKeyOverInsecureTransport(host: "192.0.2.1")
            )
        }
    }

    // MARK: - 重定向

    func testRedirectsMayNotChangeHostPortOrDowngradeScheme() {
        let origin = URL(string: "https://api.example.com/v1/chat/completions")!

        XCTAssertTrue(CloudNetworkPolicy.allowsRedirect(
            from: origin, to: URL(string: "https://api.example.com/v2/chat/completions")!
        ))
        XCTAssertTrue(CloudNetworkPolicy.allowsRedirect(
            from: origin, to: URL(string: "https://API.EXAMPLE.COM:443/v1/chat/completions")!
        ), "默认端口与显式 443 是同一处")
        XCTAssertFalse(CloudNetworkPolicy.allowsRedirect(
            from: origin, to: URL(string: "https://evil.example.net/v1/chat/completions")!
        ), "换主机")
        XCTAssertFalse(CloudNetworkPolicy.allowsRedirect(
            from: origin, to: URL(string: "http://api.example.com/v1/chat/completions")!
        ), "降协议")
        XCTAssertFalse(CloudNetworkPolicy.allowsRedirect(
            from: origin, to: URL(string: "https://api.example.com:8443/v1/chat/completions")!
        ), "换端口")

        // 同主机 http → https 升级是安全的，放行（网页 301 到 https 太常见）。
        let plain = URL(string: "http://blog.example.com/post")!
        XCTAssertTrue(CloudNetworkPolicy.allowsRedirect(
            from: plain, to: URL(string: "https://blog.example.com/post")!
        ))
        XCTAssertFalse(CloudNetworkPolicy.allowsRedirect(
            from: plain, to: URL(string: "https://www.example.com/post")!
        ))
    }

    func testRedirectGuardRefusesCrossHostRedirectAndFollowsSameHost() {
        let session = URLSession.shared
        let origin = URL(string: "https://api.example.com/v1/chat/completions")!
        // 只造任务不 resume：拿到带 originalRequest 的 URLSessionTask 即可。
        let task = session.dataTask(with: URLRequest(url: origin))
        defer { task.cancel() }
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let redirectGuard = CloudRedirectGuard()

        // 守门人同步作答：回调在返回前就被调用。
        let crossHost = RedirectDecision()
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://evil.example.net/steal")!)
        ) { request in
            crossHost.record(request)
        }
        XCTAssertTrue(crossHost.wasCalled)
        XCTAssertNil(crossHost.request, "换主机的重定向要被拒（回 nil）")

        let sameHost = RedirectDecision()
        let next = URLRequest(url: URL(string: "https://api.example.com/v2/chat/completions")!)
        redirectGuard.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: next
        ) { request in
            sameHost.record(request)
        }
        XCTAssertTrue(sameHost.wasCalled)
        XCTAssertEqual(sameHost.request?.url, next.url)
    }

    func testSharedCloudSessionIsGuardedAndEphemeral() {
        let session = CloudNetworkPolicy.session
        XCTAssertTrue(session.delegate is CloudRedirectGuard)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertEqual(session.configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(session.configuration.urlCache?.diskCapacity ?? 0, 0, "临时会话不落磁盘缓存")
    }

    // MARK: - 上限

    func testStreamingAndTitleFetchCapsAreBounded() {
        XCTAssertEqual(CloudIntelligenceEngine.maxStreamedAnswerBytes, 512 * 1024)
        XCTAssertEqual(InboxLinkTitleFetcher.maxBytes, 64 * 1024)
    }

    func testTitleFetcherIgnoresNonHTTPSchemes() async {
        let title = await InboxLinkTitleFetcher.fetchTitle(for: URL(string: "file:///etc/hosts")!)
        XCTAssertNil(title)
        let ftp = await InboxLinkTitleFetcher.fetchTitle(for: URL(string: "ftp://example.com/x")!)
        XCTAssertNil(ftp)
    }
}

/// 重定向回调是 @Sendable：用一个带锁的盒子接结果。
private final class RedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    private var called = false

    func record(_ request: URLRequest?) {
        lock.withLock {
            stored = request
            called = true
        }
    }

    var request: URLRequest? { lock.withLock { stored } }
    var wasCalled: Bool { lock.withLock { called } }
}
