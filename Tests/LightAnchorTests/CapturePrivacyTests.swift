import Foundation
import XCTest
@testable import LightAnchor
import CoreGraphics

/// 采集与恢复两端的隐私 / 安全护栏：终端命令与剪贴板脱敏、链接去 token、
/// 恢复端白名单、截图排除规则、快捷指令参数、端侧语音识别错误。
final class CapturePrivacyTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - 终端命令

    func testTerminalCommandIsRedactedBeforeTruncation() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let command = "curl -H \"Authorization: Bearer \(token)\" https://api.example.com/v1/things"
        let sanitized = MacTerminalWorkingDirectoryProvider.sanitizedCommand(command, limit: 120)

        XCTAssertFalse(sanitized.contains(token))
        XCTAssertTrue(sanitized.contains(SecretRedactor.placeholder))
        XCTAssertLessThanOrEqual(sanitized.count, 120)
    }

    func testTerminalCommandTruncationNeverKeepsHalfAToken() {
        // 先截断再脱敏会把 token 切成看不出形态的一半留下；这里保证先脱敏。
        let token = "sk-" + String(repeating: "b", count: 60)
        let command = "export OPENAI_API_KEY=\(token)"
        let sanitized = MacTerminalWorkingDirectoryProvider.sanitizedCommand(command, limit: 40)

        XCTAssertFalse(sanitized.contains("bbbbbbbb"))
        XCTAssertTrue(sanitized.hasPrefix("export OPENAI_API_KEY="))
    }

    func testPlainTerminalCommandIsKeptVerbatim() {
        XCTAssertEqual(
            MacTerminalWorkingDirectoryProvider.sanitizedCommand("swift test --filter Foo"),
            "swift test --filter Foo"
        )
    }

    // MARK: - 剪贴板

    func testClipboardTextIsRedactedAndTruncated() {
        let secret = "xoxb-" + String(repeating: "1", count: 30)
        let text = "  slack token: \(secret) and some more text  "
        let sanitized = MacContextRecorder.sanitizedClipboardText(text, limit: 2000)

        XCTAssertFalse(sanitized.contains(secret))
        XCTAssertTrue(sanitized.hasPrefix("slack token:"))
        XCTAssertLessThanOrEqual(
            MacContextRecorder.sanitizedClipboardText(text, limit: 10).count, 10
        )
    }

    func testClipboardIsSkippedForTerminalsAndPasswordManagers() {
        for bundleIdentifier in [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.1password.1password",
            "com.bitwarden.desktop",
            "org.keepassxc.keepassxc",
            "com.lastpass.LastPass",
            "com.dashlane.Dashlane",
            "com.apple.Passwords",
            "com.apple.keychainaccess",
        ] {
            XCTAssertTrue(
                MacContextRecorder.isClipboardSensitiveApplication(bundleIdentifier),
                "\(bundleIdentifier) 前台时不该读剪贴板"
            )
        }
        XCTAssertFalse(MacContextRecorder.isClipboardSensitiveApplication("com.apple.Safari"))
        XCTAssertFalse(MacContextRecorder.isClipboardSensitiveApplication(""))
    }

    // MARK: - 链接清洗

    func testWebURLsLoseCredentialsFragmentsAndTokens() throws {
        let raw = try XCTUnwrap(URL(
            string: "https://user:pw@example.com/docs?page=2&access_token=abc#section"
        ))
        let sanitized = ContextURLSanitizer.sanitized(raw)

        XCTAssertEqual(sanitized.absoluteString, "https://example.com/docs?page=2")
    }

    func testFileURLsAreLeftUntouched() {
        let fileURL = URL(fileURLWithPath: "/tmp/notes token=abc.md")
        XCTAssertEqual(ContextURLSanitizer.sanitized(fileURL), fileURL)
        XCTAssertFalse(ContextURLSanitizer.isWebURL(fileURL))
        XCTAssertTrue(ContextURLSanitizer.isWebURL(URL(string: "HTTP://example.com")!))
    }

    func testEnvironmentDraftStripsLinkTokens() throws {
        let capsule = ContextCapsule(
            links: [try XCTUnwrap(URL(string: "https://example.com/a?token=secret&q=1#frag"))]
        )
        let draft = EnvironmentSnapshotBuilder.draft(from: capsule)
        XCTAssertEqual(draft.actions.map(\.value), ["https://example.com/a?q=1"])
    }

    // MARK: - 恢复端白名单

    func testRestorePolicyAllowsOnlyWebLinks() throws {
        XCTAssertTrue(RestoreItemPolicy.allowsLink(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(RestoreItemPolicy.allowsLink(try XCTUnwrap(URL(string: "http://example.com"))))
        XCTAssertFalse(RestoreItemPolicy.allowsLink(try XCTUnwrap(URL(string: "file:///etc/hosts"))))
        XCTAssertFalse(RestoreItemPolicy.allowsLink(try XCTUnwrap(URL(string: "x-apple.systempreferences:"))))
        XCTAssertFalse(RestoreItemPolicy.allowsLink(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
    }

    func testRestorePolicyAllowsPlainDocuments() throws {
        let document = temporaryDirectory.appendingPathComponent("notes.md")
        try "hello".write(to: document, atomically: true, encoding: .utf8)

        XCTAssertNil(RestoreItemPolicy.fileRejection(document))
        XCTAssertTrue(RestoreItemPolicy.allowsFile(document))
    }

    func testRestorePolicyRejectsExecutablesBundlesSymlinksAndDirectories() throws {
        let fileManager = FileManager.default

        let script = temporaryDirectory.appendingPathComponent("run.txt")
        try "#!/bin/sh\necho hi".write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(RestoreItemPolicy.fileRejection(script), .executable)

        let commandFile = temporaryDirectory.appendingPathComponent("evil.command")
        try "echo hi".write(to: commandFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(RestoreItemPolicy.fileRejection(commandFile), .blockedExtension("command"))

        for ext in ["tool", "terminal", "scpt", "workflow", "pkg", "dmg", "sh"] {
            let blocked = temporaryDirectory.appendingPathComponent("item.\(ext)")
            try "x".write(to: blocked, atomically: true, encoding: .utf8)
            XCTAssertEqual(RestoreItemPolicy.fileRejection(blocked), .blockedExtension(ext), ext)
        }

        let bundle = temporaryDirectory.appendingPathComponent("Fake.app", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertEqual(RestoreItemPolicy.fileRejection(bundle), .notARegularFile)

        let directory = temporaryDirectory.appendingPathComponent("folder", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(RestoreItemPolicy.fileRejection(directory), .notARegularFile)

        let target = temporaryDirectory.appendingPathComponent("target.md")
        try "hello".write(to: target, atomically: true, encoding: .utf8)
        let link = temporaryDirectory.appendingPathComponent("link.md")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(RestoreItemPolicy.fileRejection(link), .symbolicLink)

        let missing = temporaryDirectory.appendingPathComponent("missing.md")
        XCTAssertEqual(RestoreItemPolicy.fileRejection(missing), .missing)

        XCTAssertEqual(
            RestoreItemPolicy.fileRejection(URL(string: "https://example.com/a.md")!),
            .unsupportedScheme
        )
    }

    func testTerminalDirectoryMustBeARealDirectory() throws {
        let fileManager = FileManager.default
        let directory = temporaryDirectory.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(RestoreItemPolicy.allowsTerminalDirectory(directory))

        let file = temporaryDirectory.appendingPathComponent("script.command")
        try "echo hi".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(RestoreItemPolicy.allowsTerminalDirectory(file))

        let link = temporaryDirectory.appendingPathComponent("project-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertFalse(RestoreItemPolicy.allowsTerminalDirectory(link))

        XCTAssertFalse(RestoreItemPolicy.allowsTerminalDirectory(
            temporaryDirectory.appendingPathComponent("gone")
        ))
    }

    func testRestorerRecordsFailureForUnsafeItems() throws {
        var report = ContextRestoreReport()
        let commandFile = temporaryDirectory.appendingPathComponent("evil.command")
        try "echo hi".write(to: commandFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(MacContextRestorer.allowsOpening(commandFile, report: &report))
        XCTAssertFalse(MacContextRestorer.allowsOpening(
            try XCTUnwrap(URL(string: "ssh://host/")), report: &report
        ))
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertEqual(
            report.failures[0],
            String(format: tr("skipped_unsafe_item_on_restore"), commandFile.path)
        )
        XCTAssertEqual(
            report.failures[1],
            String(format: tr("skipped_unsafe_item_on_restore"), "ssh://host/")
        )

        let document = temporaryDirectory.appendingPathComponent("notes.md")
        try "hello".write(to: document, atomically: true, encoding: .utf8)
        XCTAssertTrue(MacContextRestorer.allowsOpening(document, report: &report))
        XCTAssertTrue(MacContextRestorer.allowsOpening(
            try XCTUnwrap(URL(string: "https://example.com")), report: &report
        ))
        XCTAssertEqual(report.failures.count, 2)
    }

    // MARK: - 全桌面截图的排除规则

    func testScreenshotVisibleWindowFilterIgnoresOverlayLayersAndTrivialBounds() {
        func window(layer: Int = 0, alpha: Double = 1, width: CGFloat = 800, height: CGFloat = 600) -> [String: Any] {
            [
                kCGWindowLayer as String: layer,
                kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height)
                    .dictionaryRepresentation as NSDictionary,
            ]
        }
        XCTAssertTrue(SceneScreenshotRecorder.isVisibleContentWindow(window()))
        XCTAssertFalse(SceneScreenshotRecorder.isVisibleContentWindow(window(layer: 25)))
        XCTAssertFalse(SceneScreenshotRecorder.isVisibleContentWindow(window(alpha: 0)))
        XCTAssertFalse(SceneScreenshotRecorder.isVisibleContentWindow(window(width: 1, height: 1)))
        XCTAssertFalse(SceneScreenshotRecorder.isVisibleContentWindow([:]))
    }

    func testScreenshotBlockedWindowCheckHonoursPredicate() {
        // 全放行：无论桌面上有什么，都不算被排除。
        XCTAssertFalse(SceneScreenshotRecorder.visibleDesktopContainsBlockedWindow(
            allowsApplication: { _ in true }
        ))
        // 全拒绝：只要桌面上有任何可见窗口就该拦下；无窗口（无头 CI）时放行。
        let owners = SceneScreenshotRecorder.visibleWindowOwnerBundleIdentifiers()
        XCTAssertEqual(
            SceneScreenshotRecorder.visibleDesktopContainsBlockedWindow(allowsApplication: { _ in false }),
            !owners.isEmpty
        )
    }

    func testScreenshotSkipsWhenAVisibleWindowIsBlocked() async {
        // 被排除的应用在桌面上时必须直接返回 nil，而不是先截再处理。
        // 用「拒绝一切」的规则模拟：只要桌面有任何窗口就该跳过。
        let owners = SceneScreenshotRecorder.visibleWindowOwnerBundleIdentifiers()
        guard !owners.isEmpty else { return }
        let data = await SceneScreenshotRecorder.captureDesktop(allowsApplication: { _ in false })
        XCTAssertNil(data)
    }

    // MARK: - 环境动作

    func testShortcutNamesStartingWithDashAreRejected() {
        XCTAssertNil(EnvironmentActionRunner.shortcutName(from: "-h"))
        XCTAssertNil(EnvironmentActionRunner.shortcutName(from: "  --version"))
        XCTAssertNil(EnvironmentActionRunner.shortcutName(from: "   "))
        XCTAssertEqual(EnvironmentActionRunner.shortcutName(from: " Morning Routine "), "Morning Routine")
    }

    func testRunShortcutWithDashNameFailsWithoutRunning() async {
        let profile = EnvironmentProfile(
            name: "快捷指令",
            actions: [EnvironmentAction(kind: .runShortcut, value: "--help")]
        )
        let runner = EnvironmentActionRunner()

        let previews = runner.preview(profile)
        guard case .blocked(let reason) = previews[0].status else {
            return XCTFail("以 - 开头的名字应在预览里标记为会失败")
        }
        XCTAssertEqual(reason, tr("shortcut_name_can_t_start_with_a_dash"))

        let results = await runner.execute(profile)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertEqual(results[0].message, tr("shortcut_name_can_t_start_with_a_dash"))
    }

    func testOpenURLActionOnlyAcceptsWebLinks() async {
        let profile = EnvironmentProfile(
            name: "链接",
            actions: [EnvironmentAction(kind: .openURL, value: "file:///etc/hosts")]
        )
        let runner = EnvironmentActionRunner()

        guard case .blocked(let reason) = runner.preview(profile)[0].status else {
            return XCTFail("file:// 链接应在预览里标记为会失败")
        }
        XCTAssertEqual(reason, tr("only_http_links_can_be_opened"))

        let results = await runner.execute(profile)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertEqual(results[0].message, tr("only_http_links_can_be_opened"))
    }

    func testOpenFileActionRefusesExecutableDocuments() async throws {
        let commandFile = temporaryDirectory.appendingPathComponent("evil.command")
        try "echo hi".write(to: commandFile, atomically: true, encoding: .utf8)
        let profile = EnvironmentProfile(
            name: "文件",
            actions: [EnvironmentAction(kind: .openFile, value: commandFile.path)]
        )
        let runner = EnvironmentActionRunner()

        guard case .blocked(let reason) = runner.preview(profile)[0].status else {
            return XCTFail("可执行文档应在预览里标记为会失败")
        }
        XCTAssertEqual(reason, tr("file_isn_t_a_plain_document"))

        let results = await runner.execute(profile)
        XCTAssertEqual(results[0].status, .failed)
        XCTAssertEqual(results[0].message, tr("file_isn_t_a_plain_document"))
    }

    // MARK: - 语音

    func testOnDeviceSpeechErrorHasLocalizedDescription() {
        let error = VoiceCaptureError.onDeviceRecognitionUnavailable
        XCTAssertEqual(error.errorDescription, tr("on_device_speech_recognition_unavailable"))
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
}
