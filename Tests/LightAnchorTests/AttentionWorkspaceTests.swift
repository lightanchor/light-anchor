import Foundation
import CryptoKit
import XCTest
@testable import LightAnchor

@MainActor
final class AttentionWorkspaceTests: XCTestCase {
    func testLocalDataArchiveRestoresDataAndExcludesRuntimeFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("LightAnchorData", isDirectory: true)
        let archive = directory.appendingPathComponent("backup.zip")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 恢复前会校验事件日志能否解码，夹具用一份真实的空日志。
        try LocalEventStore(fileURL: root.appendingPathComponent("events.json")).save(events: [])
        let original = try Data(contentsOf: root.appendingPathComponent("events.json"))
        try Data("runtime".utf8).write(to: root.appendingPathComponent("launch-marker.json"))
        try Data("lock".utf8).write(to: root.appendingPathComponent("writer.lock"))

        // 偏好也进备份，用独立域，别把跑测试这台机器的真实偏好卷进临时 zip。
        let defaultsName = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: defaultsName) }
        let service = LocalDataArchiveService(rootURL: root, defaults: defaults)
        try service.createArchive(at: archive)
        try Data("changed".utf8).write(to: root.appendingPathComponent("events.json"))
        try service.restoreArchive(from: archive)

        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("events.json")),
            original
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launch-marker.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("writer.lock").path))
    }

    func testCaptureStaysInTheInboxAndSurvivesReload() throws {
        let fileURL = temporaryFileURL()
        let store = LocalEventStore(fileURL: fileURL)
        let workspace = AttentionWorkspace(store: store)

        let capture = workspace.captureText(
            "记录一个还不想打断当前工作的想法",
            sourceApplication: "Xcode"
        )

        XCTAssertNotNil(capture)
        XCTAssertEqual(workspace.snapshot.inbox.count, 1)
        XCTAssertEqual(workspace.snapshot.inbox.first?.sourceApplication, "Xcode")

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.inbox, workspace.snapshot.inbox)
    }

    func testCaptureCanBecomeReferenceMaterialAndSurvivesReload() throws {
        let store = LocalEventStore(fileURL: temporaryFileURL())
        let workspace = AttentionWorkspace(store: store)
        let capture = try XCTUnwrap(workspace.captureText("以后查阅的资料"))

        XCTAssertTrue(workspace.saveCaptureAsReference(capture.id))
        XCTAssertTrue(workspace.snapshot.inbox.isEmpty)
        XCTAssertEqual(workspace.snapshot.referenceCaptures.first?.id, capture.id)

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.referenceCaptures.first?.status, .reference)
        XCTAssertEqual(reloaded.snapshot.referenceCaptures.first?.body, "以后查阅的资料")
    }

    func testCreatingTargetFromCaptureCommitsTargetEpisodeAndAttachmentTogether() throws {
        let store = LocalEventStore(fileURL: temporaryFileURL())
        let workspace = AttentionWorkspace(store: store)
        let capture = try XCTUnwrap(workspace.captureText("从这里开始整理"))

        let target = try XCTUnwrap(
            workspace.createTargetFromCapture(
                capture.id,
                name: "整理材料",
                note: "先处理捕获内容"
            )
        )
        let episode = try XCTUnwrap(workspace.currentEpisode)

        XCTAssertEqual(episode.targetID, target.id)
        XCTAssertEqual(workspace.snapshot.captures[capture.id]?.status, .attached)
        XCTAssertEqual(workspace.snapshot.captures[capture.id]?.attachedEpisodeID, episode.id)
        XCTAssertTrue(workspace.snapshot.inbox.isEmpty)

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.currentEpisode?.targetID, target.id)
        XCTAssertEqual(reloaded.snapshot.captures[capture.id]?.status, .attached)
        XCTAssertEqual(reloaded.snapshot.captures[capture.id]?.attachedEpisodeID, episode.id)
    }

    func testTurningCaptureIntoWaitingArchivesItInTheSameCommit() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "等待捕获"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let capture = try XCTUnwrap(workspace.captureText("等待外部结果"))

        let waiting = try XCTUnwrap(
            workspace.beginWaitingFromCapture(
                capture.id,
                episodeID: episode.id,
                kind: .export,
                completionCondition: "导出文件出现",
                restorePolicy: .nextTransition
            )
        )

        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .waiting)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .waiting)
        XCTAssertEqual(workspace.snapshot.captures[capture.id]?.status, .archived)
        XCTAssertTrue(workspace.snapshot.inbox.isEmpty)
    }

    func testConfiguredInboxArchiveOnlyArchivesStaleInboxCaptures() throws {
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: AttentionWorkspace.inboxAutoArchiveEnabledKey)
        let oldDays = defaults.object(forKey: AttentionWorkspace.inboxAutoArchiveDaysKey)
        defer {
            if let oldEnabled {
                defaults.set(oldEnabled, forKey: AttentionWorkspace.inboxAutoArchiveEnabledKey)
            } else {
                defaults.removeObject(forKey: AttentionWorkspace.inboxAutoArchiveEnabledKey)
            }
            if let oldDays {
                defaults.set(oldDays, forKey: AttentionWorkspace.inboxAutoArchiveDaysKey)
            } else {
                defaults.removeObject(forKey: AttentionWorkspace.inboxAutoArchiveDaysKey)
            }
        }

        defaults.set(true, forKey: AttentionWorkspace.inboxAutoArchiveEnabledKey)
        defaults.set(7.0, forKey: AttentionWorkspace.inboxAutoArchiveDaysKey)

        let now = Date(timeIntervalSince1970: 10_000)
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let stale = try XCTUnwrap(
            workspace.captureText("过期捕获", now: now.addingTimeInterval(-8 * 24 * 60 * 60))
        )
        let fresh = try XCTUnwrap(
            workspace.captureText("新捕获", now: now.addingTimeInterval(-2 * 24 * 60 * 60))
        )
        let reference = try XCTUnwrap(
            workspace.captureText("过期参考", now: now.addingTimeInterval(-9 * 24 * 60 * 60))
        )
        XCTAssertTrue(workspace.saveCaptureAsReference(reference.id, now: now))

        XCTAssertEqual(workspace.archiveConfiguredInbox(now: now), 1)
        XCTAssertEqual(workspace.snapshot.captures[stale.id]?.status, .archived)
        XCTAssertEqual(workspace.snapshot.captures[fresh.id]?.status, .inbox)
        XCTAssertEqual(workspace.snapshot.captures[reference.id]?.status, .reference)
    }

    func testEpisodeLifecycleKeepsTheContextCapsule() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "整理研究材料"))
        let context = ContextCapsule(
            applications: ["Xcode"],
            windows: ["Research.swift"],
            note: "从结果段落开始"
        )

        let episode = try XCTUnwrap(
            workspace.startEpisode(
                targetID: target.id,
                context: context,
                returnCue: "先核对第三个引用"
            )
        )
        XCTAssertEqual(workspace.currentEpisode?.state, .active)

        XCTAssertTrue(workspace.pauseEpisode(episode.id))
        // 放下 = 离开「现在」；那一段和它的现场原样留着。
        XCTAssertNil(workspace.currentEpisode)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .paused)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.context, context)
        XCTAssertTrue(workspace.resumeEpisode(episode.id))
        XCTAssertEqual(workspace.currentEpisode?.state, .active)
        XCTAssertTrue(workspace.endEpisode(episode.id))
        XCTAssertNil(workspace.currentEpisode)
    }

    func testWaitingCompletesWithoutStealingTheCurrentEpisode() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "等待构建结果"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(
            workspace.beginWaiting(
                episodeID: episode.id,
                kind: .build,
                description: "等待测试构建完成",
                completionCondition: "进程退出且测试通过",
                restorePolicy: .notify
            )
        )

        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .waiting)
        XCTAssertTrue(workspace.completeWaiting(waiting.id, evidence: "测试进程已退出"))
        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .ready)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .waiting)

        XCTAssertTrue(workspace.resumeWaitingEpisode(waiting.id))
        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .resolved)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .active)
    }

    func testEndingATargetClosesTheWaitsItLeftBehind() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "等待两个结果"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let stillWaiting = try XCTUnwrap(
            workspace.beginWaiting(
                episodeID: episode.id,
                kind: .build,
                description: "等待构建完成",
                completionCondition: "",
                restorePolicy: .notify
            )
        )
        let alreadyReady = try XCTUnwrap(
            workspace.beginWaiting(
                episodeID: episode.id,
                kind: .download,
                description: "等待下载完成",
                completionCondition: "",
                restorePolicy: .notify
            )
        )
        XCTAssertTrue(workspace.completeWaiting(alreadyReady.id, evidence: "文件已下载"))

        XCTAssertTrue(workspace.endEpisode(episode.id))

        XCTAssertEqual(workspace.snapshot.waitingItems[stillWaiting.id]?.status, .cancelled)
        XCTAssertEqual(workspace.snapshot.waitingItems[alreadyReady.id]?.status, .resolved)
        XCTAssertTrue(workspace.snapshot.activeWaitingItems.isEmpty)
        XCTAssertTrue(workspace.snapshot.readyWaitingItems.isEmpty)
    }

    func testAbandoningATargetClosesTheWaitsItLeftBehind() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "放弃这件事"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(
            workspace.beginWaiting(
                episodeID: episode.id,
                kind: .reply,
                description: "等待回复",
                completionCondition: "",
                restorePolicy: .manual
            )
        )

        XCTAssertTrue(workspace.abandonEpisode(episode.id))

        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .cancelled)
        XCTAssertTrue(workspace.snapshot.activeWaitingItems.isEmpty)
    }

    func testUnreadableEventLogIsNotOverwrittenByLaterWrites() throws {
        let fileURL = temporaryFileURL()
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        XCTAssertNotNil(workspace.createTarget(name: "已经保存的工作"))

        let corrupted = "{ not a valid event document"
        try Data(corrupted.utf8).write(to: fileURL)
        let reopened = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        XCTAssertTrue(reopened.snapshot.targets.isEmpty)
        XCTAssertNotNil(reopened.lastError)

        XCTAssertNil(reopened.createTarget(name: "不应该写进去的工作"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), corrupted)
    }

    func testDeletingCaptureIsRefusedAfterAFailedReload() throws {
        let fileURL = temporaryFileURL()
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        let linkURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let capture = try XCTUnwrap(workspace.captureLink(linkURL, title: "一篇文章"))

        // A failed reload used to leave the previous snapshot in memory, and
        // deleting bypasses `commit`, so the next delete rewrote the file from
        // that stale history and destroyed whatever had just been restored.
        let corrupted = "{ not a valid event document"
        try Data(corrupted.utf8).write(to: fileURL)
        XCTAssertFalse(workspace.reloadFromDisk())

        XCTAssertFalse(workspace.deleteCapture(capture.id))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), corrupted)
    }

    /// 完成手上这件后「现在」落到干净状态：放下的事不自动顶上来，
    /// 下一件由用户挑，不由它蹦（2026-08-24 结构重组定的语义）。
    func testEndingCurrentEpisodeLandsCleanInsteadOfPromotingPausedWork() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let firstTarget = try XCTUnwrap(workspace.createTarget(name: "第一段工作"))
        let secondTarget = try XCTUnwrap(workspace.createTarget(name: "第二段工作"))
        let firstEpisode = try XCTUnwrap(
            workspace.startEpisode(
                targetID: firstTarget.id,
                now: Date(timeIntervalSince1970: 100)
            )
        )
        let secondEpisode = try XCTUnwrap(
            workspace.startEpisode(
                targetID: secondTarget.id,
                now: Date(timeIntervalSince1970: 200)
            )
        )

        XCTAssertEqual(workspace.snapshot.episodes[firstEpisode.id]?.state, .paused)
        XCTAssertTrue(workspace.endEpisode(secondEpisode.id, now: Date(timeIntervalSince1970: 300)))
        XCTAssertNil(workspace.currentEpisode, "完成后不自动接上放下的那件")
        XCTAssertEqual(
            workspace.snapshot.episodes[firstEpisode.id]?.state, .paused,
            "放下的那件还在，等用户自己挑"
        )
    }

    func testReplayProducesTheSameProjectionAsTheLiveWorkspace() throws {
        let fileURL = temporaryFileURL()
        let store = LocalEventStore(fileURL: fileURL)
        let workspace = AttentionWorkspace(store: store)
        let target = try XCTUnwrap(workspace.createTarget(name: "验证事件回放"))
        _ = workspace.startEpisode(targetID: target.id)
        _ = workspace.captureText("保留一个上下文线索")

        let events = try store.load()
        XCTAssertEqual(AttentionSnapshot.replay(events), workspace.snapshot)
    }

    func testCaptureKindsAndScreenshotAssetHaveIndependentLifecycle() throws {
        let assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorAssets")
            .appendingPathComponent(UUID().uuidString)
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: temporaryFileURL()),
            assetStore: LocalAssetStore(directoryURL: assetDirectory)
        )

        let linkURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let link = try XCTUnwrap(workspace.captureLink(linkURL, title: "一篇文章"))
        let fileURL = URL(fileURLWithPath: "/tmp/reference.pdf")
        let file = try XCTUnwrap(workspace.captureFileReference(fileURL))
        let screenshot = try XCTUnwrap(
            workspace.captureScreenshot(data: Data([0x89, 0x50, 0x4E, 0x47]), note: "区域说明")
        )

        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.sourceURL, linkURL)
        XCTAssertEqual(file.kind, .fileReference)
        XCTAssertEqual(file.sourceURL, fileURL)
        XCTAssertEqual(screenshot.kind, .screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(screenshot.assetURL).path))

        XCTAssertTrue(workspace.deleteCapture(screenshot.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(screenshot.assetURL).path))
        XCTAssertEqual(workspace.snapshot.inbox.count, 2)
    }

    func testLocalSemanticAnalyzerProducesExplainableDispositionAndSummary() throws {
        let waiting = CaptureItem(
            kind: .text,
            body: "等待构建完成后再回复评审意见",
            title: "构建结果"
        )
        let waitingSuggestion = LocalSemanticAnalyzer().analyze(waiting)
        XCTAssertEqual(waitingSuggestion.disposition, .waiting)
        XCTAssertTrue(waitingSuggestion.labels.contains("等待线索"))
        XCTAssertTrue(waitingSuggestion.summary.hasPrefix("等待条件："))
        XCTAssertTrue(waitingSuggestion.evidence.contains("构建"))

        let reference = CaptureItem(
            kind: .link,
            body: "https://example.com/design",
            title: "阅读参考文档",
            sourceURL: URL(string: "https://example.com/design")
        )
        let referenceSuggestion = LocalSemanticAnalyzer().analyze(reference)
        XCTAssertEqual(referenceSuggestion.disposition, .reference)
        XCTAssertTrue(referenceSuggestion.summary.hasPrefix("资料线索："))
        XCTAssertTrue(referenceSuggestion.evidence.contains("链接来源"))

        let action = CaptureItem(kind: .text, body: "记得整理下一步和检查清单")
        let actionSuggestion = LocalSemanticAnalyzer().analyze(action)
        XCTAssertEqual(actionSuggestion.disposition, .action)
        XCTAssertTrue(actionSuggestion.summary.hasPrefix("下一步："))
    }

    func testCommandWaitingDetectorReturnsEvidenceAndRejectsFailure() async throws {
        let success = try await CommandWaitingDetector().wait(
            for: WaitingMonitorConfiguration(kind: .command, command: "printf evidence")
        )
        XCTAssertEqual(success, "evidence")

        do {
            _ = try await CommandWaitingDetector().wait(
                for: WaitingMonitorConfiguration(kind: .command, command: "printf failure >&2; exit 7")
            )
            XCTFail("失败命令不应被视为完成")
        } catch let error as WaitingDetectionError {
            guard case .commandFailed(let message) = error else {
                return XCTFail("应返回命令失败原因")
            }
            XCTAssertEqual(message, "failure")
        }
    }

    func testCommandWaitingDetectorHandlesOutputLargerThanThePipeBuffer() async throws {
        // Anything past the ~64 KiB pipe buffer used to deadlock, because the
        // output was only read after the process had been waited on.
        let evidence = try await CommandWaitingDetector().wait(
            for: WaitingMonitorConfiguration(
                kind: .command,
                command: "for i in $(seq 1 20000); do echo 0123456789; done"
            )
        )
        XCTAssertEqual(evidence.count, 20000 * 11 - 1)
    }

    func testSynchronousProcessExecutionHandlesOutputLargerThanThePipeBuffer() throws {
        // Context capture runs `ps` on the main thread, which already emits about
        // 63 KB against a 64 KB pipe buffer. Reading only after `waitUntilExit`
        // froze the whole app as soon as the output crossed that line.
        let output = try XCTUnwrap(
            ProcessExecutionSupport.runSynchronously(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "for i in $(seq 1 20000); do echo 0123456789; done"]
            )
        )
        XCTAssertEqual(output.count, 20000 * 11 - 1)
    }

    func testEnvironmentCanBeUpdatedAndReplayed() throws {
        let store = LocalEventStore(fileURL: temporaryFileURL())
        let workspace = AttentionWorkspace(store: store)
        let environment = try XCTUnwrap(workspace.createEnvironment(
            name: "写作环境",
            actions: [EnvironmentAction(kind: .openApplication, value: "com.apple.TextEdit")]
        ))

        XCTAssertTrue(workspace.updateEnvironment(
            environment.id,
            name: "深度写作",
            actions: [
                EnvironmentAction(kind: .openApplication, value: "com.apple.TextEdit"),
                EnvironmentAction(kind: .runCommand, value: "printf ready", isEnabled: false)
            ],
            allowedApplicationBundleIdentifiers: ["com.apple.TextEdit"]
        ))

        let updated = try XCTUnwrap(workspace.snapshot.environments[environment.id])
        XCTAssertEqual(updated.name, "深度写作")
        XCTAssertEqual(updated.actions.count, 2)
        XCTAssertEqual(updated.allowedApplicationBundleIdentifiers, ["com.apple.TextEdit"])

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.environments[environment.id], updated)
    }

    func testContextEditsAndAbandonmentRemainReachableAndPersisted() throws {
        let fileURL = temporaryFileURL()
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        let target = try XCTUnwrap(workspace.createTarget(name: "整理旧项目"))
        let episode = try XCTUnwrap(
            workspace.startEpisode(
                targetID: target.id,
                context: ContextCapsule(applications: ["TextEdit"], note: "原上下文"),
                returnCue: "先看第三段"
            )
        )

        var updatedContext = episode.context
        updatedContext.note = "改过的上下文备注"
        XCTAssertTrue(
            workspace.updateContext(
                for: episode.id,
                context: updatedContext,
                returnCue: "先核对引用"
            )
        )
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.context.note, "改过的上下文备注")
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.returnCue, "先核对引用")

        XCTAssertTrue(workspace.abandonEpisode(episode.id))
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .ended)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.endedReason, .abandoned)

        let reloaded = AttentionWorkspace(store: LocalEventStore(fileURL: fileURL))
        XCTAssertEqual(reloaded.snapshot.episodes[episode.id]?.endedReason, .abandoned)
        XCTAssertEqual(reloaded.snapshot.episodes[episode.id]?.context.note, "改过的上下文备注")
    }

    func testCommandWaitingCancellationReturnsPromptly() async throws {
        let task = Task {
            try await CommandWaitingDetector().wait(
                for: WaitingMonitorConfiguration(kind: .command, command: "sleep 5")
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("已取消的命令不应报告完成")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        } catch {
            XCTFail("应返回取消错误，实际为：\(error)")
        }
    }

    func testRepeatedMaintenanceDoesNotRestartAnActiveWaitingMonitor() async throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "持续等待"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(
            workspace.beginWaiting(
                episodeID: episode.id,
                kind: .build,
                description: "等待长任务",
                monitor: WaitingMonitorConfiguration(kind: .command, command: "sleep 1")
            )
        )

        for _ in 0..<15 {
            workspace.startActiveWaitingMonitors()
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(workspace.snapshot.waitingItems[waiting.id]?.status, .ready)
    }

    func testEnvironmentCommandRunsOffTheSynchronousPath() async throws {
        let profile = EnvironmentProfile(
            name: "测试环境",
            actions: [EnvironmentAction(kind: .runCommand, value: "printf environment")]
        )
        let results = await EnvironmentActionRunner().execute(profile)
        XCTAssertEqual(results.first?.status, .succeeded)
        XCTAssertEqual(results.first?.message, "environment")
    }

    func testEnvironmentAllowedApplicationsSkipUnlistedApplicationActions() async throws {
        let profile = EnvironmentProfile(
            name: "受限环境",
            actions: [EnvironmentAction(kind: .openApplication, value: "com.example.NotAllowed")],
            allowedApplicationBundleIdentifiers: ["com.apple.TextEdit"]
        )

        let results = await EnvironmentActionRunner().execute(profile)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(result.message.contains("允许列表"))
    }

    func testExternalEventStoreAndURLParserShareTheSameCompletionContract() throws {
        let inboxURL = temporaryFileURL().deletingPathExtension().appendingPathExtension("jsonl")
        let store = ExternalEventStore(fileURL: inboxURL)
        let event = ExternalEvent(
            source: .terminal,
            kind: .completed,
            correlationID: "build-42",
            title: "Terminal build",
            detail: "Tests passed",
            occurredAt: Date(timeIntervalSince1970: 100)
        )
        try store.publish(event)

        XCTAssertEqual(try store.matching(correlationID: "build-42"), [event])
        let url = URL(string: "lightanchor://event?source=terminal&kind=completed&correlation=build-42&title=Terminal%20build")
        XCTAssertEqual(
            ExternalEventURLParser().event(from: try XCTUnwrap(url), now: event.occurredAt)?.correlationID,
            event.correlationID
        )
    }

    func testIncomingURLWaitingParserAcceptsDownloadAndExportOnly() throws {
        let downloadURL = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=download&source=download&correlation=download-42&title=浏览器下载"
        ))
        let request = try XCTUnwrap(IncomingURLWaitingRequestParser().request(from: downloadURL))
        XCTAssertEqual(request.kind, .download)
        XCTAssertEqual(request.source, .download)
        XCTAssertEqual(request.correlationID, "download-42")
        XCTAssertEqual(request.title, "浏览器下载")

        let exportURL = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=export&source=export&correlation=export-42"
        ))
        XCTAssertEqual(
            IncomingURLWaitingRequestParser().request(from: exportURL)?.title,
            "文件导出"
        )

        let missingCorrelation = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=download&source=download&title=缺少关联 ID"
        ))
        XCTAssertNil(IncomingURLWaitingRequestParser().request(from: missingCorrelation))

        let unsupportedSource = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=download&source=calendar&correlation=calendar-42"
        ))
        XCTAssertNil(IncomingURLWaitingRequestParser().request(from: unsupportedSource))

        let mismatchedSource = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=download&source=export&correlation=export-42"
        ))
        XCTAssertNil(IncomingURLWaitingRequestParser().request(from: mismatchedSource))

        let emptyTitle = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=export&source=export&correlation=export-43&title=%20"
        ))
        XCTAssertEqual(
            IncomingURLWaitingRequestParser().request(from: emptyTitle)?.title,
            "文件导出"
        )
    }

    func testIncomingURLWaitingCreatesAnExternalEventMonitorForTheCurrentEpisode() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let target = try XCTUnwrap(workspace.createTarget(name: "等待浏览器结果"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let url = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=download&source=download&correlation=download-99&title=等待报告下载&detail=下载完成后提醒"
        ))
        let request = try XCTUnwrap(IncomingURLWaitingRequestParser().request(from: url))
        let now = Date(timeIntervalSince1970: 10_000)

        let waiting = try XCTUnwrap(workspace.beginWaitingFromIncomingURL(request, now: now))
        XCTAssertEqual(waiting.episodeID, episode.id)
        XCTAssertEqual(waiting.kind, .download)
        XCTAssertEqual(waiting.restorePolicy, .notify)
        XCTAssertEqual(waiting.monitor?.kind, .event)
        XCTAssertEqual(waiting.monitor?.eventCorrelationID, "download-99")
        XCTAssertEqual(waiting.monitor?.eventSources, [.download])
        XCTAssertEqual(waiting.monitor?.eventAfter, now.addingTimeInterval(-60))
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .waiting)
    }

    func testIncomingURLWaitingExplainsWhenThereIsNoCurrentEpisode() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
        let url = try XCTUnwrap(URL(string:
            "lightanchor://wait?kind=download&source=download&correlation=download-100"
        ))
        let request = try XCTUnwrap(IncomingURLWaitingRequestParser().request(from: url))

        XCTAssertNil(workspace.beginWaitingFromIncomingURL(request))
        XCTAssertEqual(
            workspace.lastNotice,
            "没有正在进行的工作，无法等待外部结果。先开始一件事。"
        )
    }

    /// 收件箱是同一用户下任何进程都能追加的文件。一条坏行只丢那一条：
    /// 让整条通道失效会顺带取消用户正在等的下载/导出，代价比丢一条事件大得多。
    func testExternalEventStoreSkipsCorruptedRecordsAndKeepsTheRest() throws {
        let inboxURL = temporaryFileURL().deletingPathExtension().appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(
            at: inboxURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json\n".utf8).write(to: inboxURL, options: .atomic)
        XCTAssertEqual(try ExternalEventStore(fileURL: inboxURL).events(), [])

        try ExternalEventStore(fileURL: inboxURL).publish(ExternalEvent(
            source: .terminal,
            kind: .completed,
            correlationID: "blank-line",
            title: "任务完成",
            detail: "完成"
        ))
        let validData = try Data(contentsOf: inboxURL)
        try (validData + Data("\n{\"source\":\"jenkins\"}\n\n".utf8)).write(to: inboxURL, options: .atomic)
        XCTAssertEqual(
            try ExternalEventStore(fileURL: inboxURL).events().map(\.correlationID),
            ["blank-line"]
        )
    }

    func testExternalEventWaitingDetectorResolvesFromPublishedEvent() async throws {
        let inboxURL = temporaryFileURL().deletingPathExtension().appendingPathExtension("jsonl")
        let startedAt = Date()
        let monitor = WaitingMonitorConfiguration(
            kind: .event,
            eventInboxURL: inboxURL,
            eventCorrelationID: "export-42",
            eventSources: [.export],
            eventKinds: [.completed, .failed, .cancelled],
            eventAfter: startedAt
        )
        let task = Task.detached {
            try await ExternalEventWaitingDetector().wait(for: monitor)
        }
        try await Task.sleep(for: .milliseconds(80))
        try ExternalEventStore(fileURL: inboxURL).publish(ExternalEvent(
            source: .export,
            kind: .completed,
            correlationID: "export-42",
            title: "导出完成",
            detail: "文件已写入"
        ))

        let evidence = try await task.value
        XCTAssertTrue(evidence.contains("导出完成"))
        XCTAssertTrue(evidence.contains("文件已写入"))
    }

    func testExternalEventWaitingDetectorPreservesCancellationEvidence() async throws {
        let inboxURL = temporaryFileURL().deletingPathExtension().appendingPathExtension("jsonl")
        let monitor = WaitingMonitorConfiguration(
            kind: .event,
            eventInboxURL: inboxURL,
            eventCorrelationID: "download-17",
            eventSources: [.download],
            eventKinds: [.cancelled],
            eventAfter: Date()
        )
        let task = Task.detached { () -> String? in
            do {
                _ = try await ExternalEventWaitingDetector().wait(for: monitor)
                return nil
            } catch let error as WaitingDetectionError {
                return error.errorDescription
            } catch {
                return error.localizedDescription
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        try ExternalEventStore(fileURL: inboxURL).publish(ExternalEvent(
            source: .download,
            kind: .cancelled,
            correlationID: "download-17",
            title: "资料下载",
            detail: "用户停止下载"
        ))

        let taskMessage = await task.value
        let message = try XCTUnwrap(taskMessage)
        XCTAssertTrue(message.contains("资料下载"))
        XCTAssertTrue(message.contains("用户停止下载"))
        XCTAssertTrue(message.contains("外部任务已取消"))
    }

    func testExternalEventWaitingConfigurationSurvivesWorkspaceReload() throws {
        let store = LocalEventStore(fileURL: temporaryFileURL())
        let workspace = AttentionWorkspace(store: store)
        let target = try XCTUnwrap(workspace.createTarget(name: "等待外部构建"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let monitor = WaitingMonitorConfiguration(
            kind: .event,
            eventInboxURL: temporaryFileURL().deletingPathExtension().appendingPathExtension("jsonl"),
            eventCorrelationID: "ide-77",
            eventSources: [.ide]
        )
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            kind: .build,
            description: "等待 IDE 构建",
            monitor: monitor
        ))

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.waitingItems[waiting.id]?.monitor?.kind, .event)
        XCTAssertEqual(
            reloaded.snapshot.waitingItems[waiting.id]?.monitor?.eventCorrelationID,
            "ide-77"
        )
        XCTAssertNotNil(reloaded.snapshot.waitingItems[waiting.id]?.monitor?.eventAfter)
    }

    func testReleaseBoundariesRejectUnsafeOrInvalidInputs() throws {
        let manifest = ReleaseManifest(
            manifestVersion: LightAnchorSchema.releaseManifestVersion,
            product: "LightAnchor",
            version: "1.2.0",
            build: "12",
            eventSchemaVersion: LightAnchorSchema.eventDocumentVersion,
            binarySHA256: String(repeating: "a", count: 64),
            artifact: ReleaseArtifact(
                filename: "LightAnchor-1.2.0-12-macos.zip",
                url: "",
                sha256: String(repeating: "b", count: 64),
                size: 10
            ),
            minimumOS: "15.0",
            channel: "stable",
            signed: false,
            signature: nil
        )
        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try ReleaseManifestVerifier().decode(data), manifest)
        let client = ReleaseUpdateClient()
        XCTAssertTrue(client.isNewer(manifest, thanVersion: "1.1.0", build: "99"))
        XCTAssertFalse(client.isNewer(manifest, thanVersion: "1.2.0", build: "12"))
    }

    func testReleaseUpdateCheckerReadsCurrentBundleVersionAndBuild() throws {
        let directory = temporaryFileURL().deletingLastPathComponent()
            .appendingPathComponent("release-checker-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let infoURL = directory.appendingPathComponent("Info.plist")
        let info: NSDictionary = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "26"
        ]
        XCTAssertTrue(info.write(to: infoURL, atomically: true))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let checker = ReleaseUpdateChecker(bundle: bundle)

        XCTAssertEqual(checker.currentVersion, "1.2.3")
        XCTAssertEqual(checker.currentBuild, "26")
    }

    func testContextWindowFactsRoundTrip() throws {
        let context = ContextCapsule(
            applications: ["Xcode"],
            applicationBundleIdentifiers: ["com.apple.dt.Xcode"],
            windows: ["LightAnchor.swift"],
            windowFacts: [ContextWindowFact(
                applicationBundleIdentifier: "com.apple.dt.Xcode",
                title: "LightAnchor.swift",
                role: "AXWindow",
                documentURL: URL(fileURLWithPath: "/tmp/LightAnchor.swift"),
                isMain: true,
                isFocused: true,
                focusedElement: ContextElementFact(
                    role: "AXTextField",
                    identifier: "source-editor"
                )
            )]
        )
        let encodedContext = try JSONEncoder().encode(context)
        XCTAssertEqual(try JSONDecoder().decode(ContextCapsule.self, from: encodedContext), context)
    }

    func testContextRestoreReportSummarizesRecoveredDocumentsAndLimitations() {
        var report = ContextRestoreReport()
        report.restoredWindows = [
            ContextWindowFact(
                applicationBundleIdentifier: "com.apple.TextEdit",
                title: "notes.txt"
            )
        ]
        report.openedFiles = [URL(fileURLWithPath: "/tmp/notes.txt")]
        report.openedTerminalWorkingDirectories = [
            URL(fileURLWithPath: "/tmp/project")
        ]

        XCTAssertFalse(report.hasIssues)
        XCTAssertTrue(report.summary.contains("已恢复 1 个窗口"))
        XCTAssertTrue(report.summary.contains("已重新打开 1 个文件或链接"))
        XCTAssertTrue(report.summary.contains("已恢复 1 个终端工作目录"))

        report.limitations = ["无法恢复窗口内的输入焦点：notes.txt"]
        XCTAssertTrue(report.hasIssues)
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.summary.contains("输入焦点"))
    }

    /// 面板 id 用 macOS 13 起的 ExtensionKit 扩展标识，不再赌旧 id 的兼容映射。
    func testNotificationPermissionLinksToNotificationSettings() {
        XCTAssertEqual(
            PrivacyCapability.notifications.systemSettingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
    }

    func testPrivacyPermissionsLinkToTheirOwnSystemSettingsAnchor() {
        XCTAssertEqual(
            PrivacyCapability.accessibility.systemSettingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(
            PrivacyCapability.screenRecording.systemSettingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
    }

    func testConfiguredDataRootMapsEveryDefaultLocalStore() throws {
        let root = temporaryFileURL().deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment[LightAnchorStorage.dataRootEnvironmentKey] = root.path

        XCTAssertEqual(
            LightAnchorStorage.rootURL(environment: environment),
            root.standardizedFileURL
        )
        let configuredRoot = LightAnchorStorage.rootURL(environment: environment)
        XCTAssertEqual(
            configuredRoot.appendingPathComponent("events.json"),
            root.appendingPathComponent("events.json")
        )
        XCTAssertEqual(
            configuredRoot.appendingPathComponent("assets", isDirectory: true),
            root.appendingPathComponent("assets", isDirectory: true)
        )
        XCTAssertEqual(
            configuredRoot.appendingPathComponent("external-events.jsonl"),
            root.appendingPathComponent("external-events.jsonl")
        )
        XCTAssertEqual(
            configuredRoot.appendingPathComponent("plugins.json"),
            root.appendingPathComponent("plugins.json")
        )
        XCTAssertEqual(
            configuredRoot.appendingPathComponent("waiting-records.jsonl"),
            root.appendingPathComponent("waiting-records.jsonl")
        )
        XCTAssertEqual(
            configuredRoot.appendingPathComponent("diagnostics.log"),
            root.appendingPathComponent("diagnostics.log")
        )
    }

    func testLifecycleTrackerReportsPreviousUncleanRunAndCleansMarker() throws {
        let directory = temporaryFileURL().deletingLastPathComponent()
        let markerURL = directory.appendingPathComponent("launch-marker.json")
        let diagnosticsURL = directory.appendingPathComponent("diagnostics.log")
        let diagnostics = LocalDiagnostics(fileURL: diagnosticsURL)
        let firstRun = AppLifecycleTracker(
            markerURL: markerURL,
            diagnostics: diagnostics
        )
        let firstStart = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(firstRun.start(now: firstStart))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let secondRun = AppLifecycleTracker(
            markerURL: markerURL,
            diagnostics: diagnostics
        )
        XCTAssertTrue(secondRun.start(now: firstStart.addingTimeInterval(10)))

        let bundle = try JSONDecoder().decode(
            DiagnosticBundle.self,
            from: diagnostics.exportData()
        )
        XCTAssertTrue(bundle.events.contains { $0.operation == "lifecycle.previous-run" })

        secondRun.markCleanExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testReleaseScheduleAndDiagnosticExportKeepOperationalDataSeparate() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let schedule = ReleaseUpdateSchedule(
            enabled: true,
            manifestURL: URL(string: "https://updates.example.com/manifest.json"),
            publicKeyURL: URL(fileURLWithPath: "/tmp/update-key.pem"),
            lastCheckedAt: now.addingTimeInterval(-86_400),
            interval: 86_400
        )
        XCTAssertTrue(schedule.shouldCheck(now: now))
        XCTAssertFalse(schedule.shouldCheck(now: now.addingTimeInterval(-60)))

        let diagnosticsURL = temporaryFileURL()
        let diagnostics = LocalDiagnostics(fileURL: diagnosticsURL)
        diagnostics.record(
            operation: "test",
            message: "路径：\(NSHomeDirectory())/private-value Authorization: Bearer live-token https://example.com/path?access_token=secret#fragment xoxb-123"
        )
        let bundle = try JSONDecoder().decode(
            DiagnosticBundle.self,
            from: diagnostics.exportData()
        )
        XCTAssertEqual(bundle.events.count, 1)
        XCTAssertFalse(bundle.events[0].message.contains(NSHomeDirectory()))
        XCTAssertTrue(bundle.events[0].message.contains("<HOME>"))
        XCTAssertFalse(bundle.events[0].message.contains("live-token"))
        XCTAssertFalse(bundle.events[0].message.contains("access_token=secret"))
        XCTAssertFalse(bundle.events[0].message.contains("xoxb-123"))
        XCTAssertTrue(bundle.events[0].message.contains("https://example.com/path"))
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events.json")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct SharedCaptureFixture: Codable {
    let id: UUID
    let deviceID: String
    let kind: String
    let body: String
    let sourceURL: URL?
    let capturedAt: Date
    let returnCue: String
}

private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { }
    override func stopLoading() { }
}

// MARK: - 专注时长（暂停/等待不计时）

final class EpisodeFocusDurationTests: XCTestCase {
    private func episode(
        _ base: AttentionEpisode,
        state: AttentionEpisodeState,
        at date: Date
    ) -> AttentionEpisode {
        var updated = base
        updated.state = state
        updated.updatedAt = date
        if state == .ended { updated.endedAt = date }
        return updated
    }

    func testFocusDurationExcludesPausedAndWaitingSpans() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let target = AttentionTarget(name: "写周报")
        let base = AttentionEpisode(targetID: target.id, startedAt: start, updatedAt: start)

        let events: [AttentionEvent] = [
            .targetChanged(target, at: start),
            .episodeChanged(base, at: start),
            // 10 分钟后暂停，暂停 20 分钟，再恢复 5 分钟后放下等待。
            .episodeChanged(episode(base, state: .paused, at: start.addingTimeInterval(600)), at: start.addingTimeInterval(600)),
            .episodeChanged(episode(base, state: .active, at: start.addingTimeInterval(1800)), at: start.addingTimeInterval(1800)),
            .episodeChanged(episode(base, state: .waiting, at: start.addingTimeInterval(2100)), at: start.addingTimeInterval(2100))
        ]
        let snapshot = AttentionSnapshot.replay(events)

        // 专注 = 10 分钟 + 5 分钟；等待中的时段不再计入，现在多晚都一样。
        let now = start.addingTimeInterval(7200)
        XCTAssertEqual(snapshot.focusMinutes(of: base.id, now: now), 15)
    }

    func testActiveEpisodeKeepsCountingUntilNow() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let target = AttentionTarget(name: "整理访谈材料")
        let base = AttentionEpisode(targetID: target.id, startedAt: start, updatedAt: start)
        let snapshot = AttentionSnapshot.replay([
            .targetChanged(target, at: start),
            .episodeChanged(base, at: start)
        ])

        XCTAssertEqual(snapshot.focusMinutes(of: base.id, now: start.addingTimeInterval(2520)), 42)
    }

    func testEndedEpisodeFreezesFocusDuration() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let target = AttentionTarget(name: "回复合同意见")
        let base = AttentionEpisode(targetID: target.id, startedAt: start, updatedAt: start)
        let events: [AttentionEvent] = [
            .targetChanged(target, at: start),
            .episodeChanged(base, at: start),
            .episodeChanged(episode(base, state: .ended, at: start.addingTimeInterval(1200)), at: start.addingTimeInterval(1200))
        ]
        let snapshot = AttentionSnapshot.replay(events)

        XCTAssertEqual(snapshot.focusMinutes(of: base.id, now: start.addingTimeInterval(90_000)), 20)
    }
}

// MARK: - 捕获标签

final class CaptureTagTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-tags-\(UUID().uuidString).json")
    }

    func testNormalizationStripsHashTrimsAndDeduplicates() {
        XCTAssertEqual(
            CaptureItem.normalizedTags(["#开发", " 开发 ", "", "  ", "##工具", "工具", "生活"]),
            ["开发", "工具", "生活"]
        )
    }

    @MainActor
    func testSetCaptureTagsPersistsAndAggregates() throws {
        let store = LocalEventStore(fileURL: temporaryFileURL())
        let workspace = AttentionWorkspace(store: store)
        let first = try XCTUnwrap(workspace.captureText("整理接口文档"))
        let second = try XCTUnwrap(workspace.captureText("给周报配图"))

        XCTAssertTrue(workspace.setCaptureTags(first.id, tags: ["#开发", "工具"]))
        XCTAssertTrue(workspace.setCaptureTags(second.id, tags: ["生活"]))

        XCTAssertEqual(workspace.snapshot.captures[first.id]?.tags, ["开发", "工具"])
        XCTAssertEqual(workspace.snapshot.allCaptureTags, ["工具", "开发", "生活"].sorted {
            $0.localizedCompare($1) == .orderedAscending
        })

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.captures[first.id]?.tags, ["开发", "工具"])
    }
}
