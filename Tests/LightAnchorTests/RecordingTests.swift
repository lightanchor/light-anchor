import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class RecordingTests: XCTestCase {
    // MARK: - 辅助

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorRecordingTests-\(UUID().uuidString).json")
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorRecordingTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeWorkspace(
        contextCapture: ((IntelligencePreferences, SceneCapturePreferences) -> ContextCapsule)? = nil
    ) -> AttentionWorkspace {
        AttentionWorkspace(
            store: LocalEventStore(fileURL: temporaryFileURL()),
            recordingTraceStore: RecordingTraceStore(directoryURL: temporaryDirectoryURL()),
            contextCapture: contextCapture ?? { _, _ in ContextCapsule() }
        )
    }

    // MARK: - 数据模型

    func testSlugKeepsAlphanumericsAndFoldsTheRest() {
        XCTAssertEqual(RecordingSession.slug(from: "Fix the Build!! (v2)"), "fix-the-build-v2")
        XCTAssertEqual(RecordingSession.slug(from: "修好 签名 校验"), "修好-签名-校验")
        XCTAssertEqual(RecordingSession.slug(from: "!!!"), "")
    }

    func testExportFileNames() {
        XCTAssertEqual(
            RecordingStyle.guide.exportFileName(for: "Fix the build"),
            "fix-the-build.md"
        )
        XCTAssertEqual(RecordingStyle.guide.exportFileName(for: "!!!"), "record.md")
        XCTAssertEqual(RecordingStyle.skill.exportFileName(for: "任意标题"), "SKILL.md")
    }

    // MARK: - trace 仓库

    func testTraceStoreRoundTripsEntries() throws {
        let store = RecordingTraceStore(directoryURL: temporaryDirectoryURL())
        let sessionID = UUID()
        let entries = [
            RecordingEntry(kind: .application, title: "VS Code", detail: "build.sh"),
            RecordingEntry(kind: .command, title: "swift test", detail: "light-anchor")
        ]
        try store.save(entries, for: sessionID)
        XCTAssertEqual(store.load(for: sessionID), entries)
        store.remove(for: sessionID)
        XCTAssertTrue(store.load(for: sessionID).isEmpty)
    }

    // MARK: - 启发式成稿（确定性拼装）

    func testHeuristicComposeGuideListsFacts() async throws {
        let engine = HeuristicIntelligenceEngine()
        let markdown = await engine.composeRecordMarkdown(RecordComposeInput(
            title: "修构建",
            style: .guide,
            factLines: ["09:00 [命令] swift build", "09:02 [文件] build.sh"]
        ))
        XCTAssertTrue(markdown.hasPrefix("# 修构建"))
        XCTAssertTrue(markdown.contains("swift build"))
    }

    func testHeuristicComposeSkillEmitsFrontmatter() async throws {
        let engine = HeuristicIntelligenceEngine()
        let markdown = await engine.composeRecordMarkdown(RecordComposeInput(
            title: "Fix the build",
            style: .skill,
            factLines: ["09:00 [命令] swift build"]
        ))
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("name: fix-the-build"))
        XCTAssertTrue(markdown.contains("description: Fix the build"))
        XCTAssertTrue(markdown.contains("swift build"))
    }

    // MARK: - 主动录制

    func testManualRecordingCapturesFactsAndStops() throws {
        let workspace = makeWorkspace(contextCapture: { _, _ in
            ContextCapsule(
                applications: ["Xcode"],
                windows: ["RecordingKit.swift"],
                files: [URL(fileURLWithPath: "/tmp/RecordingKit.swift")],
                terminalWorkingDirectories: [URL(fileURLWithPath: "/tmp")],
                terminalCommands: ["swift build"]
            )
        })
        let session = try XCTUnwrap(workspace.startManualRecording(title: "录一段"))
        XCTAssertEqual(workspace.activeRecordingSession?.id, session.id)

        // 开始时的首采样：前台应用、文件、命令各一条。
        let entries = workspace.recordingEntries(for: session.id)
        XCTAssertEqual(
            Set(entries.map(\.kind)),
            [.application, .file, .command]
        )

        // 期间的捕获也进 trace。
        _ = workspace.captureText("想法一条")
        XCTAssertTrue(
            workspace.recordingEntries(for: session.id).contains { $0.kind == .capture }
        )

        let stopped = try XCTUnwrap(workspace.stopRecording())
        XCTAssertEqual(stopped.status, .finished)
        XCTAssertNotNil(stopped.endedAt)
        XCTAssertEqual(stopped.entryCount, workspace.recordingEntries(for: session.id).count)
        XCTAssertNil(workspace.activeRecordingSession)
    }

    func testDeleteRemovesSessionAndTrace() throws {
        let workspace = makeWorkspace(contextCapture: { _, _ in
            ContextCapsule(applications: ["Safari"])
        })
        let session = try XCTUnwrap(workspace.startManualRecording())
        XCTAssertFalse(workspace.recordingEntries(for: session.id).isEmpty)
        XCTAssertTrue(workspace.deleteRecordingSession(session.id))
        XCTAssertNil(workspace.snapshot.recordingSessions[session.id])
        XCTAssertTrue(workspace.recordingEntries(for: session.id).isEmpty)
        XCTAssertNil(workspace.activeRecordingSession)
    }

    // MARK: - 跟随工作（单次开启）

    func testEpisodeLifecycleDrivesTheRecording() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        let session = try XCTUnwrap(workspace.startRecordingCurrentEpisode())
        XCTAssertTrue(session.autoFollowed)
        XCTAssertEqual(session.episodeID, episode.id)
        XCTAssertEqual(session.title, "修签名校验")

        // 放下：录制暂停。
        XCTAssertTrue(workspace.pauseEpisode(episode.id))
        XCTAssertEqual(workspace.activeRecordingSession?.status, .paused)

        // 回来：继续录。
        XCTAssertTrue(workspace.resumeEpisode(episode.id))
        XCTAssertEqual(workspace.activeRecordingSession?.status, .recording)

        // 结束：收尾归档，trace 里有完整的生命周期脚印。
        XCTAssertTrue(workspace.endEpisode(episode.id))
        XCTAssertNil(workspace.activeRecordingSession)
        let finished = try XCTUnwrap(workspace.snapshot.recordingSessions[session.id])
        XCTAssertEqual(finished.status, .finished)
        let episodeEntries = workspace.recordingEntries(for: session.id)
            .filter { $0.kind == .episode }
        XCTAssertEqual(episodeEntries.count, 4)
    }

    func testWaitingPausesAndResumesTheRecording() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "等 CI"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let session = try XCTUnwrap(workspace.startRecordingCurrentEpisode())

        let waiting = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "等 CI 跑完"
        ))
        XCTAssertEqual(workspace.activeRecordingSession?.status, .paused)

        XCTAssertTrue(workspace.completeWaiting(waiting.id, evidence: "CI 绿了"))
        XCTAssertTrue(workspace.resumeWaitingEpisode(waiting.id))
        XCTAssertEqual(workspace.activeRecordingSession?.status, .recording)

        let waitingEntries = workspace.recordingEntries(for: session.id)
            .filter { $0.kind == .waiting }
        XCTAssertEqual(waitingEntries.count, 2)
        XCTAssertTrue(waitingEntries.contains { $0.detail == "CI 绿了" })
    }

    func testSwitchingTargetsFinalizesTheFollowedRecording() throws {
        let workspace = makeWorkspace()
        let first = try XCTUnwrap(workspace.createTarget(name: "第一件"))
        let second = try XCTUnwrap(workspace.createTarget(name: "第二件"))
        _ = try XCTUnwrap(workspace.startEpisode(targetID: first.id))
        let session = try XCTUnwrap(workspace.startRecordingCurrentEpisode())

        // 切到别件事：跟随的录制就地收尾，不跨事续录。
        _ = try XCTUnwrap(workspace.startEpisode(targetID: second.id))
        XCTAssertNil(workspace.activeRecordingSession)
        XCTAssertEqual(workspace.snapshot.recordingSessions[session.id]?.status, .finished)
    }

    // MARK: - 采样差分

    func testCoordinatorDedupesAndDiffsSamples() throws {
        let workspace = makeWorkspace(contextCapture: { _, _ in
            ContextCapsule(applications: ["Xcode"], windows: ["A.swift"])
        })
        let session = try XCTUnwrap(workspace.startManualRecording())
        let baseline = workspace.recordingEntries(for: session.id).count

        // 期间的两条相同备注：相邻去重只留一条。
        workspace.noteRecordingFactForTesting(kind: .note, title: "同一件事")
        workspace.noteRecordingFactForTesting(kind: .note, title: "同一件事")
        let entries = workspace.recordingEntries(for: session.id)
        XCTAssertEqual(entries.count - baseline, 1)
    }
}
