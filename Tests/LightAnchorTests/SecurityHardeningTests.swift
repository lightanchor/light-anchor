import Foundation
import XCTest
@testable import LightAnchor

/// 安全审查后补的守门测试：备份文件是外部输入，
/// 这里核对它再也拿不到「删任意文件」「跑任意命令」这几把钥匙。
@MainActor
final class SecurityHardeningTests: XCTestCase {

    // MARK: - 附件目录收口

    func testAssetStoreOnlyRemovesFilesInsideItsOwnDirectory() throws {
        let scratch = try makeScratchDirectory()
        let assets = scratch.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let store = LocalAssetStore(directoryURL: assets)

        let outsideFile = scratch.appendingPathComponent("precious.txt")
        try Data("keep me".utf8).write(to: outsideFile)
        let outsideDirectory = scratch.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let nested = assets.appendingPathComponent("deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("x.jpg")
        try Data([1]).write(to: nestedFile)
        let managed = try store.save(data: Data([1, 2, 3]), fileExtension: "jpg")

        XCTAssertFalse(store.isManaged(outsideFile))
        XCTAssertFalse(store.isManaged(outsideDirectory))
        XCTAssertFalse(store.isManaged(nestedFile))
        XCTAssertFalse(store.isManaged(assets))
        XCTAssertTrue(store.isManaged(managed))

        store.removeIfPresent(at: outsideFile)
        store.removeIfPresent(at: outsideDirectory)
        store.removeIfPresent(at: assets)
        store.removeIfPresent(at: managed)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
    }

    // MARK: - 恢复备份后的自动化隔离

    func testQuarantineDisarmsCommandActions() throws {
        let workspace = makeWorkspace()
        let environment = try XCTUnwrap(
            workspace.createEnvironment(
                name: "写代码",
                actions: [
                    EnvironmentAction(kind: .runCommand, value: "rm -rf ~"),
                    EnvironmentAction(kind: .runShortcut, value: "Send Files"),
                    EnvironmentAction(kind: .openApplication, value: "com.apple.Terminal")
                ]
            )
        )

        XCTAssertEqual(workspace.quarantineAutomation(), 1)

        let actions = try XCTUnwrap(workspace.snapshot.environments[environment.id]).actions
        XCTAssertEqual(actions.filter { $0.kind == .runCommand }.map(\.isEnabled), [false])
        XCTAssertEqual(actions.filter { $0.kind == .runShortcut }.map(\.isEnabled), [false])
        XCTAssertEqual(actions.filter { $0.kind == .openApplication }.map(\.isEnabled), [true])

        // 再跑一次没有东西可隔离。
        XCTAssertEqual(workspace.quarantineAutomation(), 0)
    }

    func testReloadFromDiskQuarantinesWhenAskedTo() throws {
        let fileURL = temporaryFileURL()
        let writer = makeWorkspace(fileURL: fileURL)
        let environment = try XCTUnwrap(
            writer.createEnvironment(
                name: "备份来源",
                actions: [EnvironmentAction(kind: .runCommand, value: "true")]
            )
        )

        let reader = makeWorkspace(fileURL: fileURL)
        XCTAssertTrue(reader.reloadFromDisk(quarantiningRestoredAutomation: true))
        let actions = try XCTUnwrap(reader.snapshot.environments[environment.id]).actions
        XCTAssertEqual(actions.map(\.isEnabled), [false])
    }

    // MARK: - 备份里的偏好

    func testRestoreSkipsUpdateChainKeysAndNarrowsIntelligencePreferences() throws {
        let defaults = try makeScratchDefaults()
        var archived = IntelligencePreferences.default
        archived.engine = .cloud
        archived.saveWindowScreenshot = true
        archived.saveClipboardContent = true
        let scratchSource = try makeScratchDefaults()
        archived.save(to: scratchSource)
        let blob = try XCTUnwrap(scratchSource.data(forKey: IntelligencePreferences.storageKey))

        let crafted: [String: Any] = [
            "lightanchor.updateManifestURL": "https://evil.example/manifest.json",
            "lightanchor.updateChecksEnabled": true,
            "lightanchor.updateLastCheckedAt": 1.0,
            IntelligencePreferences.storageKey: blob
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: crafted, format: .xml, options: 0)

        try LocalPreferencesArchive.restore(from: data, into: defaults)

        XCTAssertNil(defaults.object(forKey: "lightanchor.updateManifestURL"))
        XCTAssertNil(defaults.object(forKey: "lightanchor.updateChecksEnabled"))
        XCTAssertNil(defaults.object(forKey: "lightanchor.updateLastCheckedAt"))
        let restored = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(restored.engine, .onDevice)
        XCTAssertFalse(restored.saveWindowScreenshot)
        XCTAssertFalse(restored.saveClipboardContent)
    }

    func testDataRootGuardRejectsObviouslyWrongRoots() {
        XCTAssertThrowsError(try LocalDataArchiveService.guardDataRoot(URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(
            try LocalDataArchiveService.guardDataRoot(URL(fileURLWithPath: NSHomeDirectory()))
        )
        XCTAssertNoThrow(
            try LocalDataArchiveService.guardDataRoot(
                FileManager.default.temporaryDirectory.appendingPathComponent("LightAnchor")
            )
        )
    }

    func testPreRestoreCopiesAreEnumeratedAndPruned() throws {
        let scratch = try makeScratchDirectory()
        let root = scratch.appendingPathComponent("LightAnchor", isDirectory: true)
        for stamp in ["20260101000000", "20260201000000", "20260301000000"] {
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent("LightAnchor.pre-restore-\(stamp)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("Unrelated.pre-restore-1", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(LocalDataArchiveService.preRestoreCopies(of: root).count, 3)
        LocalDataArchiveService.removePreRestoreCopies(of: root, keepingLatest: 1)
        let remaining = LocalDataArchiveService.preRestoreCopies(of: root)
        XCTAssertEqual(remaining.map(\.lastPathComponent), ["LightAnchor.pre-restore-20260301000000"])
        LocalDataArchiveService.removePreRestoreCopies(of: root)
        XCTAssertTrue(LocalDataArchiveService.preRestoreCopies(of: root).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("Unrelated.pre-restore-1").path
            )
        )
    }

    // MARK: - 脱敏器

    func testSecretRedactorMasksCommonCredentialShapes() {
        let cases: [(String, String)] = [
            ("curl -H 'Authorization: Bearer sk_live_abcdefghijklmnop' https://api.test", "sk_live_abcdefghijklmnop"),
            ("mysql -uroot -pSuperSecret123 db", "SuperSecret123"),
            ("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"),
            ("psql --password=hunter2hunter2", "hunter2hunter2"),
            ("token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ("open https://user:pw@host.test/path?access_token=abc123#frag", "pw@")
        ]
        for (input, secret) in cases {
            let redacted = SecretRedactor.redact(input)
            XCTAssertFalse(redacted.contains(secret), "未遮住：\(input) → \(redacted)")
        }
        XCTAssertEqual(SecretRedactor.redact("swift build -c release"), "swift build -c release")
        XCTAssertEqual(SecretRedactor.redact("git commit -m 'fix build'"), "git commit -m 'fix build'")
    }

    func testSecretRedactorStripsSensitiveURLComponents() throws {
        let url = try XCTUnwrap(URL(string: "https://u:p@example.test/a?token=abc&page=2#section"))
        let stripped = SecretRedactor.stripSensitiveComponents(from: url)
        XCTAssertEqual(stripped.absoluteString, "https://example.test/a?page=2")
        let plain = try XCTUnwrap(URL(string: "https://example.test/docs?page=3"))
        XCTAssertEqual(SecretRedactor.stripSensitiveComponents(from: plain), plain)
    }

    // MARK: - 辅助

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorSecurityTests-\(UUID().uuidString).json")
    }

    private func makeWorkspace(fileURL: URL? = nil) -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(fileURL: fileURL ?? temporaryFileURL()))
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-anchor-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
}
