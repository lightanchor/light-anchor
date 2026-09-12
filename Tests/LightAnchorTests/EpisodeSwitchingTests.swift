import Foundation
import XCTest
@testable import LightAnchor

/// 事件之间的切换语义：回到一件事是「接着做那一段」，不是新开一段。
@MainActor
final class EpisodeSwitchingTests: XCTestCase {
    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
    }

    /// 放下 A → 做 B → 回到 A：A 仍是同一段，段数不虚增。
    func testReturningToASetAsideTargetResumesTheSameEpisode() throws {
        let workspace = makeWorkspace()
        let a = try XCTUnwrap(workspace.createTarget(name: "A"))
        let b = try XCTUnwrap(workspace.createTarget(name: "B"))
        let first = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        XCTAssertTrue(workspace.pauseEpisode(first.id))
        _ = try XCTUnwrap(workspace.startEpisode(targetID: b.id))

        let back = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        XCTAssertEqual(back.id, first.id, "回到一件事应接着做原来那一段")
        XCTAssertEqual(back.state, .active)
        XCTAssertEqual(
            workspace.snapshot.episodes.values.filter { $0.targetID == a.id }.count,
            1,
            "回到一件事不该新开一段"
        )
        XCTAssertEqual(workspace.currentEpisode?.id, first.id)
    }

    /// 接着做时，那一段原有的现场与「回来先看」必须留着——这正是回场要用的。
    func testResumingKeepsTheStoredContextAndReturnCue() throws {
        let workspace = makeWorkspace()
        let a = try XCTUnwrap(workspace.createTarget(name: "A"))
        let b = try XCTUnwrap(workspace.createTarget(name: "B"))
        let first = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        XCTAssertTrue(
            workspace.updateContext(
                for: first.id,
                context: ContextCapsule(files: [URL(fileURLWithPath: "/tmp/draft.md")]),
                returnCue: "改第二段"
            )
        )
        XCTAssertTrue(workspace.pauseEpisode(first.id))
        _ = try XCTUnwrap(workspace.startEpisode(targetID: b.id))

        let back = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        XCTAssertEqual(back.returnCue, "改第二段")
        XCTAssertEqual(back.context.files, [URL(fileURLWithPath: "/tmp/draft.md")])
    }

    /// 从稍后拿一条起一件事，走的是另一条入口（`createTargetFromCapture`），
    /// 但不变量是同一条：手上那件先固定现场再放下。
    /// 「换一件事」面板把这条路变成了高频动作，它以前漏了两件事——
    /// 不固定现场，且 `.returning`（刚回场、还没接着做）不算「手上那件」，
    /// 会留下一段既不是当前工作、也没被放下的孤儿。
    func testStartingFromACaptureAlsoSetsTheCurrentOneAsideWithItsScene() throws {
        let boundary = ContextCapsule(
            applications: ["Boundary Editor"],
            files: [URL(fileURLWithPath: "/tmp/boundary-from-capture.md")]
        )
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()),
            contextCapture: { _, _ in boundary }
        )
        let held = try XCTUnwrap(workspace.createTarget(name: "手上这件"))
        let heldEpisode = try XCTUnwrap(workspace.startEpisode(
            targetID: held.id,
            context: ContextCapsule(applications: ["Old Editor"], capturedAt: Date(timeIntervalSince1970: 1))
        ))
        let capture = try XCTUnwrap(workspace.captureText("从稍后拿的这条"))

        let started = try XCTUnwrap(workspace.createTargetFromCapture(capture.id))

        let setAside = try XCTUnwrap(workspace.snapshot.episodes[heldEpisode.id])
        XCTAssertEqual(setAside.state, .paused, "手上那件必须被放下")
        XCTAssertEqual(setAside.context.files, boundary.files, "放下之前先固定现场")
        XCTAssertEqual(workspace.currentEpisode?.targetID, started.id)
        XCTAssertTrue(
            workspace.snapshot.setAsideEpisodes.contains { $0.id == heldEpisode.id },
            "放下的事要出现在稍后页那一组，而不是凭空消失"
        )
    }

    /// 换到另一件事时，手上那件照旧被放下（这条不能因为「接着做」而丢）。
    func testSwitchingToAnotherTargetSetsTheCurrentOneAside() throws {
        let workspace = makeWorkspace()
        let a = try XCTUnwrap(workspace.createTarget(name: "A"))
        let b = try XCTUnwrap(workspace.createTarget(name: "B"))
        let first = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        let second = try XCTUnwrap(workspace.startEpisode(targetID: b.id))

        XCTAssertEqual(workspace.snapshot.episodes[first.id]?.state, .paused)
        XCTAssertEqual(workspace.currentEpisode?.id, second.id)
        XCTAssertNotEqual(first.id, second.id, "不同的事各自成段")
    }

    /// 做完一件事之后再做同一件事：那才是新的一段。
    func testStartingAFinishedTargetOpensANewEpisode() throws {
        let workspace = makeWorkspace()
        let a = try XCTUnwrap(workspace.createTarget(name: "A"))
        let first = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        XCTAssertTrue(workspace.endEpisode(first.id))

        let again = try XCTUnwrap(workspace.startEpisode(targetID: a.id))
        XCTAssertNotEqual(again.id, first.id, "已完成的一段不该被复活")
        XCTAssertEqual(
            workspace.snapshot.episodes.values.filter { $0.targetID == a.id }.count,
            2
        )
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("episode-switching-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }
}
