import Foundation
import XCTest
@testable import LightAnchor

/// 快照说明的提炼：历史列表靠这一句话可读，「快照、快照、快照」挑不出
/// 想回去的那一刻。经由真实 workspace 操作验证批次 → 说明 → git subject。
@MainActor
final class SnapshotNoteTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotNoteTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// 捕捉 workspace 通知里带出的 note（selector 式观察，通知在主线程同步投递）。
    @MainActor
    private final class NoteRecorder: NSObject {
        private(set) var notes: [String] = []

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(eventsChanged),
                name: .lightAnchorEventsChanged,
                object: nil
            )
        }

        @objc private func eventsChanged(_ notification: Notification) {
            notes.append((notification.userInfo?["note"] as? SnapshotNote)?.subject ?? "")
        }
    }

    func testSwitchingWorkYieldsAReadableNote() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true)),
            contextCapture: { _, _ in ContextCapsule() }
        )
        let recorder = NoteRecorder()

        let first = try XCTUnwrap(workspace.createTarget(name: "整理访谈材料"))
        XCTAssertEqual(recorder.notes.last, "记下：整理访谈材料")

        _ = try XCTUnwrap(workspace.startEpisode(targetID: first.id))
        XCTAssertEqual(recorder.notes.last, "开始：整理访谈材料")

        let second = try XCTUnwrap(workspace.createTarget(name: "回复合同问题"))
        // 换一件事：旧段 paused + 新段 active 混在一批，工作段迁移占主导。
        _ = try XCTUnwrap(workspace.startEpisode(targetID: second.id))
        XCTAssertEqual(recorder.notes.last, "换到：回复合同问题")
    }

    func testCapturesAndLongNamesClip() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true)),
            contextCapture: { _, _ in ContextCapsule() }
        )
        let recorder = NoteRecorder()

        _ = workspace.captureText("一个想法")
        XCTAssertEqual(recorder.notes.last, "捕获一条")

        let longName = String(repeating: "很长的名字", count: 10)
        _ = workspace.createTarget(name: longName)
        let note = try XCTUnwrap(recorder.notes.last)
        XCTAssertTrue(note.hasPrefix("记下："))
        XCTAssertLessThanOrEqual(note.count, 32, "说明要短，超长名字截断")
        XCTAssertTrue(note.hasSuffix("…"))
    }

    /// 端到端：note 一路流到 git 的 commit subject，历史列表直接可读。
    func testNoteBecomesTheSnapshotSubject() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: defaultsName) }

        let service = GitSnapshotService(rootURL: root, userDefaults: defaults)
        let controller = SnapshotController(service: service, debounce: .milliseconds(50))
        controller.start()
        defer { controller.stop() }

        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true)),
            contextCapture: { _, _ in ContextCapsule() }
        )
        XCTAssertNotNil(workspace.createTarget(name: "写周报"))

        var subjects: [String] = []
        for _ in 0..<100 {
            subjects = ((try? service.history()) ?? []).map(\.subject)
            if subjects.contains("记下：写周报") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(subjects.contains("记下：写周报"), "历史里应有可读说明，实际：\(subjects)")
    }

    func testEpisodeTransitionsAndContextUpdatesHaveDifferentNotes() {
        let target = AttentionTarget(name: "写周报")
        let active = AttentionEpisode(targetID: target.id)
        let before = AttentionSnapshot.replay([.targetChanged(target), .episodeChanged(active)])
        var updated = active
        updated.context.note = "补录现场"
        let context = SnapshotNote.summarize([.episodeChanged(updated)], before: before)
        XCTAssertEqual(context.subject, "更新现场与记录：写周报")
        XCTAssertTrue(context.isBackground)

        var paused = active
        paused.state = .paused
        XCTAssertEqual(SnapshotNote.summarize([.episodeChanged(paused)], before: before).subject, "放下：写周报")
        let pausedSnapshot = AttentionSnapshot.replay([.targetChanged(target), .episodeChanged(paused)])
        XCTAssertEqual(SnapshotNote.summarize([.episodeChanged(active)], before: pausedSnapshot).subject, "继续：写周报")

        var ended = active
        ended.state = .ended
        ended.endedReason = .completed
        XCTAssertEqual(SnapshotNote.summarize([.episodeChanged(ended)], before: before).subject, "做完：写周报")
        ended.endedReason = .abandoned
        XCTAssertEqual(SnapshotNote.summarize([.episodeChanged(ended)], before: before).subject, "不做了：写周报")
    }

    func testWaitingWinsOverPausingAndUsesStatusNotCompletionDate() {
        let target = AttentionTarget(name: "合同")
        let active = AttentionEpisode(targetID: target.id)
        var paused = active
        paused.state = .paused
        var waiting = WaitingItem(episodeID: active.id, description: "客户确认")
        let before = AttentionSnapshot.replay([.targetChanged(target), .episodeChanged(active)])
        XCTAssertEqual(SnapshotNote.summarize([
            .episodeChanged(paused), .waitingChanged(waiting)
        ], before: before).subject, "等着：客户确认")

        let waitingSnapshot = AttentionSnapshot.replay([.waitingChanged(waiting)])
        waiting.status = .ready
        XCTAssertNil(waiting.completedAt)
        XCTAssertEqual(SnapshotNote.summarize([.waitingChanged(waiting)], before: waitingSnapshot).subject, "结果到了：客户确认")
        waiting.status = .cancelled
        XCTAssertEqual(SnapshotNote.summarize([.waitingChanged(waiting)], before: waitingSnapshot).subject, "不再等：客户确认")
        waiting.status = .resolved
        XCTAssertEqual(SnapshotNote.summarize([.waitingChanged(waiting)], before: waitingSnapshot).subject, "处理了等待：客户确认")
    }

    func testCaptureCountExcludesExistingItemsAndDuplicateEvents() {
        let old = CaptureItem(body: "已有条目")
        let first = CaptureItem(body: "新条目一")
        let second = CaptureItem(body: "新条目二")
        let before = AttentionSnapshot.replay([.captureChanged(old)])
        let note = SnapshotNote.summarize([
            .captureChanged(old), .captureChanged(first), .captureChanged(first), .captureChanged(second)
        ], before: before)
        XCTAssertEqual(note.subject, "捕获 2 条")
        XCTAssertFalse(note.isBackground)
        let enrichment = SnapshotNote.summarize([.captureChanged(old)], before: before)
        XCTAssertEqual(enrichment.subject, "补全捕获内容")
        XCTAssertTrue(enrichment.isBackground)
    }

    func testNamesAreSingleLineAndResolveFromTheBatch() {
        let target = AttentionTarget(name: "写周报\n\t复盘  工作")
        let episode = AttentionEpisode(targetID: target.id)
        let note = SnapshotNote.summarize([
            .targetChanged(target), .episodeChanged(episode)
        ], before: AttentionSnapshot())
        XCTAssertEqual(note.subject, "开始：写周报 复盘 工作")
        let orphan = AttentionEpisode(targetID: UUID())
        XCTAssertEqual(SnapshotNote.summarize([.episodeChanged(orphan)], before: AttentionSnapshot()).subject, "开始：未命名的工作")
    }

    func testBurstPreservesActionsDeduplicatesAndBoundsSummary() {
        let action = SnapshotNote(subject: "换到：写周报")
        let capture = SnapshotNote(subject: "捕获一条")
        let background = SnapshotNote(subject: "存下现场", isBackground: true)
        XCTAssertEqual(SnapshotNote.combined([action, capture, action, background]), "换到：写周报；捕获一条")
        XCTAssertEqual(SnapshotNote.combined([background, background]), "存下现场")
        let many = (1...8).map { SnapshotNote(subject: "记下：工作\($0)") }
        XCTAssertEqual(SnapshotNote.combined(many), "记下：工作1；记下：工作2；记下：工作3；另 5 项改动")
        XCTAssertEqual(SnapshotNote.combined([]), "保存工作区变化")
        let firstCapture = SnapshotNote.summarize([.captureChanged(CaptureItem(body: "一"))], before: AttentionSnapshot())
        let secondCapture = SnapshotNote.summarize([.captureChanged(CaptureItem(body: "二"))], before: AttentionSnapshot())
        XCTAssertEqual(SnapshotNote.combined([firstCapture, secondCapture, background]), "捕获 2 条")
    }

    func testDebouncedHistoryKeepsActionsWhenBackgroundContextArrives() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: defaultsName) }
        let service = GitSnapshotService(rootURL: root, userDefaults: defaults)
        let controller = SnapshotController(service: service, debounce: .milliseconds(50))
        controller.start()
        defer { controller.stop() }
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true)),
            contextCapture: { _, _ in ContextCapsule() }
        )
        let target = try XCTUnwrap(workspace.createTarget(name: "写周报"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        XCTAssertTrue(workspace.updateContext(for: episode.id, context: ContextCapsule()))
        let expected = "记下：写周报；开始：写周报"
        var subjects: [String] = []
        for _ in 0..<100 {
            subjects = ((try? service.history()) ?? []).map(\.subject)
            if subjects.contains(expected) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(subjects.contains(expected), "实际历史：\(subjects)")
    }
}
