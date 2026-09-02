import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class SceneSnapshotTests: XCTestCase {

    // MARK: - 辅助

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorSceneTests-\(UUID().uuidString).json")
    }

    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(fileURL: temporaryFileURL()))
    }

    private func makeCapsule() -> ContextCapsule {
        let fileURL = URL(fileURLWithPath: "/tmp/light-anchor-plan.md")
        let linkURL = URL(string: "https://developer.apple.com/documentation/foundationmodels")!
        let termURL = URL(fileURLWithPath: "/tmp/light-anchor", isDirectory: true)
        return ContextCapsule(
            applications: ["Xcode", "Safari", "Terminal"],
            applicationBundleIdentifiers: ["com.apple.dt.Xcode", "com.apple.Safari", "com.apple.Terminal"],
            windows: ["light-anchor-plan.md", "FoundationModels"],
            windowFacts: [
                ContextWindowFact(
                    applicationBundleIdentifier: "com.apple.dt.Xcode",
                    title: "light-anchor-plan.md",
                    role: "AXWindow",
                    documentURL: fileURL,
                    isMain: true,
                    isFocused: true
                ),
                ContextWindowFact(
                    applicationBundleIdentifier: "com.apple.Safari",
                    title: "FoundationModels - Apple Developer",
                    role: "AXWindow",
                    documentURL: linkURL
                )
            ],
            files: [fileURL],
            links: [linkURL],
            terminalWorkingDirectories: [termURL]
        )
    }

    // MARK: - 数据模型

    func testSceneSnapshotRestorableItemsRespectFilterMode() {
        let relevant = SceneItem(kind: .file, title: "plan.md", address: "file:///tmp/plan.md", isRelevant: true)
        let tucked = SceneItem(kind: .application, title: "Music", address: "com.apple.Music", isRelevant: false)

        var aiSnapshot = SceneSnapshot(items: [relevant, tucked], filterMode: .aiFiltered)
        XCTAssertEqual(aiSnapshot.restorableItems, [relevant])
        XCTAssertEqual(aiSnapshot.tuckedAwayCount, 1)
        XCTAssertEqual(aiSnapshot.items(of: .file), [relevant])
        XCTAssertEqual(aiSnapshot.items(of: .terminal), [])

        aiSnapshot.filterMode = .saveAll
        XCTAssertEqual(aiSnapshot.restorableItems.count, 2)
        XCTAssertEqual(aiSnapshot.tuckedAwayCount, 0)
    }

    func testSceneItemTrimsWhitespace() {
        let item = SceneItem(kind: .file, title: "  plan.md  ", address: " file:///tmp/plan.md ")
        XCTAssertEqual(item.title, "plan.md")
        XCTAssertEqual(item.address, "file:///tmp/plan.md")
    }

    // MARK: - 事件流

    func testSceneSnapshotEventRoundTripsThroughStore() throws {
        let fileURL = temporaryFileURL()
        let store = LocalEventStore(fileURL: fileURL)
        let workspace = AttentionWorkspace(store: store)

        let target = workspace.createTarget(name: "写方案")
        let snapshot = SceneSnapshot(
            targetID: target?.id,
            items: [
                SceneItem(kind: .file, title: "plan.md", address: "file:///tmp/plan.md"),
                SceneItem(kind: .application, title: "Music", address: "com.apple.Music", isRelevant: false)
            ],
            filterMode: .aiFiltered,
            returnCue: "继续写路线证据矩阵"
        )
        XCTAssertTrue(workspace.commitSceneSnapshot(snapshot))

        let reloaded = AttentionWorkspace(store: store)
        let restored = reloaded.snapshot.sceneSnapshots[snapshot.id]
        XCTAssertEqual(restored?.items.count, 2)
        XCTAssertEqual(restored?.returnCue, "继续写路线证据矩阵")
        XCTAssertEqual(restored?.restorableItems.count, 1)
    }

    func testLatestSceneSnapshotPicksNewestPerTarget() {
        let workspace = makeWorkspace()
        guard let targetA = workspace.createTarget(name: "目标 A"),
              let targetB = workspace.createTarget(name: "目标 B") else {
            XCTFail("目标创建失败")
            return
        }

        let older = SceneSnapshot(targetID: targetA.id, capturedAt: Date(timeIntervalSinceNow: -100))
        let newer = SceneSnapshot(targetID: targetA.id, capturedAt: Date())
        let other = SceneSnapshot(targetID: targetB.id, capturedAt: Date(timeIntervalSinceNow: 100))

        for snap in [older, newer, other] {
            XCTAssertTrue(workspace.commitSceneSnapshot(snap))
        }

        XCTAssertEqual(workspace.snapshot.latestSceneSnapshot(for: targetA.id)?.id, newer.id)
        XCTAssertEqual(workspace.snapshot.latestSceneSnapshot(for: targetB.id)?.id, other.id)
    }

    func testUpdateSceneFilterModePersistsPerTarget() {
        let fileURL = temporaryFileURL()
        let store = LocalEventStore(fileURL: fileURL)
        let workspace = AttentionWorkspace(store: store)
        guard let target = workspace.createTarget(name: "写作") else {
            XCTFail("目标创建失败")
            return
        }

        XCTAssertTrue(workspace.updateSceneFilterMode(for: target.id, mode: .saveAll))

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.targets[target.id]?.sceneFilterMode, .saveAll)
    }

    func testToggleSceneItemRelevanceMarksManualSource() {
        let workspace = makeWorkspace()
        let item = SceneItem(kind: .application, title: "Music", address: "com.apple.Music", isRelevant: false)
        let snapshot = SceneSnapshot(items: [item], filterMode: .aiFiltered)
        XCTAssertTrue(workspace.commitSceneSnapshot(snapshot))

        XCTAssertTrue(workspace.toggleSceneItemRelevance(snapshot.id, itemID: item.id))

        let updated = workspace.snapshot.sceneSnapshots[snapshot.id]
        XCTAssertEqual(updated?.items.first?.isRelevant, true)
    }

    func testUpdateSceneReturnCue() {
        let workspace = makeWorkspace()
        let snapshot = SceneSnapshot(items: [], returnCue: "旧线索")
        XCTAssertTrue(workspace.commitSceneSnapshot(snapshot))

        XCTAssertTrue(workspace.updateSceneReturnCue(snapshot.id, returnCue: "把验签测试跑完"))
        XCTAssertEqual(workspace.snapshot.sceneSnapshots[snapshot.id]?.returnCue, "把验签测试跑完")
    }

    // MARK: - 自动捕获钩子

    func testPauseEpisodeTriggersSceneAutoCapture() async throws {
        let workspace = makeWorkspace()
        workspace.updateIntelligencePreferences({
            var prefs = IntelligencePreferences.default
            prefs.engine = .onDevice
            return prefs
        }())
        guard let target = workspace.createTarget(name: "写代码") else {
            XCTFail("目标创建失败")
            return
        }
        guard let episode = workspace.startEpisode(targetID: target.id, context: makeCapsule()) else {
            XCTFail("episode 创建失败")
            return
        }

        XCTAssertTrue(workspace.pauseEpisode(episode.id))

        // 自动捕获是异步 Task，等待事件落库
        let deadline = Date().addingTimeInterval(5)
        var snapshot: SceneSnapshot?
        while Date() < deadline {
            snapshot = workspace.snapshot.latestSceneSnapshot(for: target.id)
            if snapshot != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let captured = try XCTUnwrap(snapshot, "暂停后应自动捕获现场")
        XCTAssertFalse(captured.items.isEmpty)
        XCTAssertEqual(captured.targetID, target.id)
    }

    func testBeginWaitingTriggersSceneAutoCapture() async throws {
        let workspace = makeWorkspace()
        guard let target = workspace.createTarget(name: "构建项目"),
              let episode = workspace.startEpisode(targetID: target.id, context: makeCapsule()) else {
            XCTFail("准备失败")
            return
        }

        let waiting = workspace.beginWaiting(
            episodeID: episode.id,
            description: "等 xcodebuild"
        )
        XCTAssertNotNil(waiting)

        let deadline = Date().addingTimeInterval(5)
        var snapshot: SceneSnapshot?
        while Date() < deadline {
            snapshot = workspace.snapshot.latestSceneSnapshot(for: target.id)
            if snapshot != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(snapshot, "等待开始时应自动捕获现场")
    }

    func testTargetTransitionStoresFreshBoundaryContextBeforeBuildingScene() throws {
        let boundaryCapsule = ContextCapsule(
            applications: ["Boundary Editor"],
            applicationBundleIdentifiers: ["com.example.boundary-editor"],
            files: [URL(fileURLWithPath: "/tmp/fresh-boundary.md")]
        )
        let boundaryTime = Date(timeIntervalSince1970: 1_700_000_000)
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: temporaryFileURL()),
            sceneCapturePreferences: SceneCapturePreferences(),
            contextCapture: { _, _ in boundaryCapsule }
        )
        guard let firstTarget = workspace.createTarget(name: "第一项"),
              let secondTarget = workspace.createTarget(name: "第二项"),
              let firstEpisode = workspace.startEpisode(
                targetID: firstTarget.id,
                context: ContextCapsule(
                    applications: ["Old Editor"],
                    capturedAt: boundaryTime.addingTimeInterval(-60)
                ),
                now: boundaryTime.addingTimeInterval(-60)
              )
        else {
            XCTFail("准备失败")
            return
        }

        XCTAssertNotNil(workspace.startEpisode(
            targetID: secondTarget.id,
            now: boundaryTime
        ))

        let paused = try XCTUnwrap(workspace.snapshot.episodes[firstEpisode.id])
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.context.files, boundaryCapsule.files)
        XCTAssertEqual(paused.context.applications, boundaryCapsule.applications)
    }

    func testPausedAutomaticCaptureKeepsExistingContext() throws {
        let existing = ContextCapsule(applications: ["Existing Editor"])
        let observed = ContextCapsule(applications: ["Should Not Be Stored"])
        let workspace = AttentionWorkspace(
            store: LocalEventStore(fileURL: temporaryFileURL()),
            sceneCapturePreferences: SceneCapturePreferences(isAutomaticCapturePaused: true),
            contextCapture: { _, _ in observed }
        )
        guard let target = workspace.createTarget(name: "私密工作"),
              let episode = workspace.startEpisode(targetID: target.id, context: existing)
        else {
            XCTFail("准备失败")
            return
        }

        XCTAssertTrue(workspace.pauseEpisode(episode.id))

        let paused = try XCTUnwrap(workspace.snapshot.episodes[episode.id])
        XCTAssertEqual(paused.context.applications, existing.applications)
        XCTAssertNil(workspace.snapshot.latestSceneSnapshot(for: target.id))
    }

    func testClearSceneHistoryScrubsFactsButKeepsFocusAndWaitingState() throws {
        let fileURL = temporaryFileURL()
        let store = LocalEventStore(fileURL: fileURL)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ContextCapsule(
            applications: ["Xcode"],
            applicationBundleIdentifiers: ["com.apple.dt.Xcode"],
            files: [URL(fileURLWithPath: "/tmp/private.swift")],
            note: "用户备注",
            capturedAt: startedAt
        )
        let workspace = AttentionWorkspace(
            store: store,
            sceneCapturePreferences: SceneCapturePreferences(isAutomaticCapturePaused: true)
        )
        let target = try XCTUnwrap(workspace.createTarget(name: "清理测试", now: startedAt))
        let episode = try XCTUnwrap(workspace.startEpisode(
            targetID: target.id,
            context: context,
            now: startedAt
        ))
        XCTAssertTrue(workspace.pauseEpisode(
            episode.id,
            now: startedAt.addingTimeInterval(10 * 60)
        ))
        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "等待确认",
            now: startedAt.addingTimeInterval(11 * 60)
        ))
        let scene = SceneSnapshot(
            targetID: target.id,
            episodeID: episode.id,
            items: [SceneItem(kind: .file, title: "private.swift", address: "file:///tmp/private.swift")],
            capturedAt: startedAt.addingTimeInterval(12 * 60)
        )
        XCTAssertTrue(workspace.commitSceneSnapshot(scene, now: scene.capturedAt))

        let result = try XCTUnwrap(workspace.clearSceneHistory(
            capturedSince: startedAt.addingTimeInterval(-1)
        ))

        XCTAssertEqual(result.sceneSnapshotCount, 1)
        XCTAssertEqual(result.episodeCount, 1)
        XCTAssertEqual(result.waitingCount, 1)
        XCTAssertTrue(workspace.snapshot.sceneSnapshots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(workspace.snapshot.episodes[episode.id]).context.hasSceneContent)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.context.note, "用户备注")
        XCTAssertFalse(try XCTUnwrap(workspace.snapshot.waitingItems[waiting.id]).originalContext.hasSceneContent)
        XCTAssertEqual(
            workspace.snapshot.focusDuration(of: episode.id, now: startedAt.addingTimeInterval(20 * 60)),
            10 * 60,
            accuracy: 0.001
        )

        let reloaded = AttentionWorkspace(store: store)
        XCTAssertTrue(reloaded.snapshot.sceneSnapshots.isEmpty)
        XCTAssertEqual(reloaded.snapshot.episodes[episode.id]?.context.note, "用户备注")
        XCTAssertEqual(reloaded.snapshot.waitingItems[waiting.id]?.status, .waiting)
    }

    // MARK: - 现场快照构建器

    func testSceneSnapshotBuilderBuildsAllKinds() async {
        let capsule = makeCapsule()
        let snapshot = await SceneSnapshotBuilder.buildSnapshot(
            from: capsule,
            targetID: nil,
            targetName: "写代码",
            targetNote: "",
            filterMode: .saveAll,
            engine: HeuristicIntelligenceEngine(),
            generateReturnCue: false
        )

        XCTAssertEqual(snapshot.items(of: .file).count, 1)
        XCTAssertEqual(snapshot.items(of: .link).count, 1)
        XCTAssertEqual(snapshot.items(of: .terminal).count, 1)
        // windowFacts 去重后 Xcode + Safari 两个应用
        XCTAssertEqual(snapshot.items(of: .application).count, 2)

        let file = snapshot.items(of: .file).first
        XCTAssertEqual(file?.title, "light-anchor-plan.md")
        XCTAssertEqual(file?.sourceApplication, "Xcode")

        let link = snapshot.items(of: .link).first
        XCTAssertEqual(link?.title, "FoundationModels - Apple Developer")

        XCTAssertTrue(snapshot.items.allSatisfy(\.isRelevant))
    }

    func testSceneSnapshotBuilderKeepsAllWhenEngineDeclinesToJudge() async {
        let capsule = ContextCapsule(
            applications: ["Xcode", "Music"],
            applicationBundleIdentifiers: ["com.apple.dt.Xcode", "com.apple.Music"],
            windows: [],
            windowFacts: [
                ContextWindowFact(
                    applicationBundleIdentifier: "com.apple.dt.Xcode",
                    title: "main.swift", role: "AXWindow"
                ),
                ContextWindowFact(
                    applicationBundleIdentifier: "com.apple.Music",
                    title: "Music", role: "AXWindow"
                )
            ]
        )
        let snapshot = await SceneSnapshotBuilder.buildSnapshot(
            from: capsule,
            targetID: nil,
            targetName: "写代码",
            targetNote: "完成 swift 构建",
            filterMode: .aiFiltered,
            engine: HeuristicIntelligenceEngine(),
            generateReturnCue: false
        )

        // 启发式不猜相关性：aiFiltered 下无判断可用时全部保留，来源如实标 all。
        XCTAssertTrue(snapshot.items.allSatisfy(\.isRelevant))
        XCTAssertEqual(snapshot.tuckedAwayCount, 0)
    }

    // MARK: - 失效检查

    func testStalenessCheckerDetectsMissingFile() {
        let missing = SceneItem(
            kind: .file,
            title: "gone.md",
            address: "file:///tmp/light-anchor-definitely-missing-\(UUID().uuidString).md"
        )
        let result = SceneStalenessChecker.check(missing)
        guard case .missing = result else {
            XCTFail("不存在的文件应标记为 missing，得到 \(result)")
            return
        }
    }

    func testStalenessCheckerAcceptsExistingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-anchor-stale-\(UUID().uuidString).md")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = SceneItem(kind: .file, title: url.lastPathComponent, address: url.absoluteString)
        XCTAssertEqual(SceneStalenessChecker.check(item), .fresh)
    }

    func testStalenessCheckerRejectsInvalidLink() {
        let item = SceneItem(kind: .link, title: "bad", address: "not-a-url")
        guard case .missing = SceneStalenessChecker.check(item) else {
            XCTFail("无效链接应标记为 missing")
            return
        }
    }

    func testStalenessCheckerAcceptsValidLink() {
        let item = SceneItem(kind: .link, title: "Apple", address: "https://developer.apple.com")
        XCTAssertEqual(SceneStalenessChecker.check(item), .fresh)
    }

    func testStalenessCheckerRejectsUninstalledApp() {
        let item = SceneItem(
            kind: .application,
            title: "不存在",
            address: "com.lightanchor.definitely-not-installed-\(UUID().uuidString)"
        )
        guard case .missing = SceneStalenessChecker.check(item) else {
            XCTFail("未安装应用应标记为 missing")
            return
        }
    }

    // MARK: - 偏好

    func testIntelligencePreferencesRoundTrip() {
        let defaults = UserDefaults(suiteName: "LightAnchorSceneTests-\(UUID().uuidString)")!
        var prefs = IntelligencePreferences.default
        prefs.engine = .cloud
        prefs.activeCloudProfile.model = "test-model"
        prefs.inboxAutoOrganize = true
        prefs.save(to: defaults)

        let loaded = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(loaded.engine, .cloud)
        XCTAssertEqual(loaded.activeCloudProfile.model, "test-model")
        XCTAssertEqual(loaded.activeCloudProfileID, prefs.activeCloudProfileID)
        XCTAssertTrue(loaded.inboxAutoOrganize)
        // 未显式设置的字段保持默认
        XCTAssertTrue(loaded.saveTerminalCommands)
        XCTAssertFalse(loaded.saveWindowScreenshot)
    }

    /// 没有云端字段的偏好（全新安装）也要有一套方案可指。
    func testDecodeWithoutAnyCloudFieldsStillHasOneProfile() throws {
        let json = """
        {"engine": "onDevice"}
        """

        let prefs = try JSONDecoder().decode(IntelligencePreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.cloudProfiles.count, 1)
        XCTAssertEqual(prefs.activeCloudProfile.provider, .openAI)
        XCTAssertTrue(prefs.activeCloudProfile.apiKey.isEmpty)
    }

    /// 新建第二套方案不能碰第一套——上一版必须先改坏当前字段才能「存为新方案」。
    func testAddingAProfileLeavesTheOthersUntouched() {
        var prefs = IntelligencePreferences.default
        prefs.activeCloudProfile.apiKey = "sk-a"
        prefs.activeCloudProfile.model = "model-a"
        let firstID = prefs.activeCloudProfileID

        prefs.addCloudProfile(provider: .anthropic)
        XCTAssertEqual(prefs.cloudProfiles.count, 2)
        XCTAssertNotEqual(prefs.activeCloudProfileID, firstID)
        XCTAssertEqual(prefs.activeCloudProfile.provider, .anthropic)
        XCTAssertEqual(prefs.activeCloudProfile.apiProtocol, .anthropicMessages)
        XCTAssertTrue(prefs.activeCloudProfile.apiKey.isEmpty)

        let first = prefs.cloudProfiles[0]
        XCTAssertEqual(first.apiKey, "sk-a")
        XCTAssertEqual(first.model, "model-a")

        // 切回去，两套各自完好。
        prefs.selectCloudProfile(id: firstID)
        XCTAssertEqual(prefs.activeCloudProfile.apiKey, "sk-a")
        XCTAssertEqual(prefs.activeCloudProfile.model, "model-a")
    }

    func testDuplicatingAProfileKeepsCredentialsAndDeduplicatesName() {
        var prefs = IntelligencePreferences.default
        prefs.activeCloudProfile.apiKey = "sk-a"
        let original = prefs.activeCloudProfile

        prefs.duplicateActiveCloudProfile()
        XCTAssertEqual(prefs.cloudProfiles.count, 2)
        XCTAssertEqual(prefs.activeCloudProfile.apiKey, "sk-a")
        XCTAssertNotEqual(prefs.activeCloudProfile.id, original.id)
        XCTAssertNotEqual(prefs.activeCloudProfile.name, original.name)
    }

    /// 最后一套方案不给删：云端引擎必须始终有一套配置可指。
    func testRemovingProfilesKeepsAtLeastOneAndReselects() {
        var prefs = IntelligencePreferences.default
        let firstID = prefs.activeCloudProfileID
        prefs.addCloudProfile(provider: .anthropic)
        let secondID = prefs.activeCloudProfileID

        prefs.removeCloudProfile(id: secondID)
        XCTAssertEqual(prefs.cloudProfiles.count, 1)
        XCTAssertEqual(prefs.activeCloudProfileID, firstID)

        prefs.removeCloudProfile(id: firstID)
        XCTAssertEqual(prefs.cloudProfiles.count, 1, "最后一套方案被删掉了")
        XCTAssertEqual(prefs.activeCloudProfileID, firstID)
    }

    func testNewProfileNamesDeduplicate() {
        var prefs = IntelligencePreferences.default
        let first = prefs.activeCloudProfile.name
        prefs.addCloudProfile(provider: .openAI)
        XCTAssertNotEqual(prefs.activeCloudProfile.name, first)
    }
}
