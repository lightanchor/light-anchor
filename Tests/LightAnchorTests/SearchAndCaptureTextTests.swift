import Foundation
import XCTest
@testable import LightAnchor

/// 搜索打分、截图 OCR 字段与资料活化。
@MainActor
final class SearchAndCaptureTextTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 打分

    func testPrefixBeatsContainsAndTitleBeatsExtractedText() throws {
        typealias Field = WorkspaceSearchScoring.Field
        let now = base
        let prefixScore = try XCTUnwrap(WorkspaceSearchScoring.score(
            query: "swift",
            fields: [Field("swift test 备忘", weight: WorkspaceSearchScoring.titleWeight)],
            recency: now, now: now
        ))
        let containsScore = try XCTUnwrap(WorkspaceSearchScoring.score(
            query: "swift",
            fields: [Field("今天跑 swift test", weight: WorkspaceSearchScoring.titleWeight)],
            recency: now, now: now
        ))
        XCTAssertGreaterThan(prefixScore, containsScore)

        let titleHit = try XCTUnwrap(WorkspaceSearchScoring.score(
            query: "构建",
            fields: [Field("构建脚本", weight: WorkspaceSearchScoring.titleWeight)],
            recency: now, now: now
        ))
        let extractedHit = try XCTUnwrap(WorkspaceSearchScoring.score(
            query: "构建",
            fields: [Field("构建脚本", weight: WorkspaceSearchScoring.extractedWeight)],
            recency: now, now: now
        ))
        XCTAssertGreaterThan(titleHit, extractedHit)

        XCTAssertNil(WorkspaceSearchScoring.score(
            query: "毫无关系",
            fields: [Field("构建脚本", weight: 3)],
            recency: now, now: now
        ))
    }

    func testFresherResultWinsTies() throws {
        typealias Field = WorkspaceSearchScoring.Field
        let now = base
        let fresh = try XCTUnwrap(WorkspaceSearchScoring.score(
            query: "报告",
            fields: [Field("报告草稿", weight: 3)],
            recency: now.addingTimeInterval(-3600), now: now
        ))
        let stale = try XCTUnwrap(WorkspaceSearchScoring.score(
            query: "报告",
            fields: [Field("报告草稿", weight: 3)],
            recency: now.addingTimeInterval(-120 * 24 * 3600), now: now
        ))
        XCTAssertGreaterThan(fresh, stale)
    }

    func testSceneSearchFindsTerminalCommandAndReturnCue() throws {
        let scene = SceneSnapshot(
            items: [
                SceneItem(
                    kind: .terminal,
                    title: "light-anchor",
                    address: "file:///tmp/light-anchor",
                    sourceApplication: "Terminal",
                    detail: "swift test --filter WorkHistoryTests"
                )
            ],
            returnCue: "继续修复时间线搜索",
            capturedAt: base
        )

        let commandMatch = try XCTUnwrap(
            WorkspaceSceneSearch.match(query: "WorkHistoryTests", scene: scene, now: base)
        )
        XCTAssertEqual(commandMatch.title, "light-anchor")
        XCTAssertEqual(commandMatch.matchKind, "终端")

        let cueMatch = try XCTUnwrap(
            WorkspaceSceneSearch.match(query: "时间线", scene: scene, now: base)
        )
        XCTAssertEqual(cueMatch.title, "继续修复时间线搜索")
        XCTAssertEqual(cueMatch.matchKind, "回来先做")
    }

    func testSceneSearchDoesNotMatchUnstoredTargetText() {
        let scene = SceneSnapshot(
            items: [SceneItem(kind: .file, title: "notes.md", address: "file:///tmp/notes.md")],
            capturedAt: base
        )

        XCTAssertNil(WorkspaceSceneSearch.match(query: "目标名字", scene: scene, now: base))
    }

    func testHistoryQuestionIntentUnderstandsRecentSourceKinds() {
        XCTAssertEqual(WorkspaceHistoryQueryIntent.infer(from: "我刚才在做什么？"), .recent)
        XCTAssertEqual(WorkspaceHistoryQueryIntent.infer(from: "之前看的文档在哪？"), .document)
        XCTAssertEqual(WorkspaceHistoryQueryIntent.infer(from: "上次打开的网页"), .webpage)
        XCTAssertEqual(WorkspaceHistoryQueryIntent.infer(from: "中断前跑的 terminal command"), .terminal)
        XCTAssertNil(WorkspaceHistoryQueryIntent.infer(from: "修复登录页"))
    }

    // MARK: - 截图文字

    func testExtractedTextRoundTripsAndMarksAttempt() throws {
        let storeURL = temporaryEventsDirectoryURL()
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: storeURL))
        let capture = try XCTUnwrap(workspace.captureText("截图占位", now: base))

        XCTAssertTrue(workspace.setCaptureExtractedText(
            capture.id,
            text: "识别出的文字",
            now: base.addingTimeInterval(5)
        ))
        let updated = try XCTUnwrap(workspace.snapshot.captures[capture.id])
        XCTAssertEqual(updated.extractedText, "识别出的文字")
        XCTAssertNotNil(updated.textExtractedAt)

        // 识别失败也要记下尝试时间，回填不再反复重试。
        XCTAssertTrue(workspace.setCaptureExtractedText(capture.id, text: nil, now: base.addingTimeInterval(9)))
        XCTAssertEqual(workspace.snapshot.captures[capture.id]?.extractedText, "")
        XCTAssertNotNil(workspace.snapshot.captures[capture.id]?.textExtractedAt)

        let reloaded = AttentionWorkspace(store: LocalEventStore(directoryURL: storeURL))
        XCTAssertNotNil(reloaded.snapshot.captures[capture.id]?.textExtractedAt)
    }

    // MARK: - 资料活化

    func testReferenceAndArchivedCanReturnToInbox() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
        let reference = try XCTUnwrap(workspace.captureText("资料", now: base))
        let archived = try XCTUnwrap(workspace.captureText("旧内容", now: base))
        XCTAssertTrue(workspace.saveCaptureAsReference(reference.id, now: base))
        XCTAssertTrue(workspace.archiveCapture(archived.id, now: base))

        XCTAssertTrue(workspace.moveCaptureToInbox(reference.id, now: base.addingTimeInterval(60)))
        XCTAssertTrue(workspace.moveCaptureToInbox(archived.id, now: base.addingTimeInterval(60)))
        XCTAssertEqual(workspace.snapshot.captures[reference.id]?.status, .inbox)
        XCTAssertEqual(workspace.snapshot.captures[archived.id]?.status, .inbox)

        XCTAssertFalse(
            workspace.moveCaptureToInbox(reference.id, now: base.addingTimeInterval(120)),
            "已经在收件箱的不再重复转移"
        )
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchCaptureTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }
}
