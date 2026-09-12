import Foundation
import XCTest
@testable import LightAnchor

/// 「换一件事」邮票卡背后的工作区语义：放下方式、划掉的现场不带走、
/// 回来先看随放下写入、确认卡静默。（按条目恢复现场会真的打开链接，不在测试里跑。）
@MainActor
final class SwitchWorkFlowTests: XCTestCase {
    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-work-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    private let draft = URL(fileURLWithPath: "/tmp/draft.md")
    private let outline = URL(fileURLWithPath: "/tmp/outline.pages")
    private let page = URL(string: "https://example.com/notes")!

    /// 划掉的条目从上下文里剔除；命令与目录并列数组一起删；应用按 bundleID 删。
    func testRemovingSceneItemsTrimsEveryParallelField() {
        let capsule = ContextCapsule(
            applications: ["Figma", "Safari"],
            applicationBundleIdentifiers: ["com.figma.Desktop", "com.apple.Safari"],
            windowFacts: [
                ContextWindowFact(applicationBundleIdentifier: "com.figma.Desktop", title: "Board"),
                ContextWindowFact(applicationBundleIdentifier: "com.apple.Safari", title: "Notes")
            ],
            files: [draft, outline],
            links: [page],
            terminalWorkingDirectories: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")],
            terminalCommands: ["swift test", "npm run dev"]
        )
        let items = SceneSnapshotBuilder.items(from: capsule)
        let struck = items.filter {
            ($0.kind == .file && $0.address == outline.absoluteString)
                || ($0.kind == .terminal && $0.address == URL(fileURLWithPath: "/tmp/a").absoluteString)
                || ($0.kind == .application && $0.address == "com.figma.Desktop")
        }
        XCTAssertEqual(struck.count, 3)

        let trimmed = capsule.removing(struck)
        XCTAssertEqual(trimmed.files, [draft])
        XCTAssertEqual(trimmed.links, [page])
        XCTAssertEqual(trimmed.terminalWorkingDirectories, [URL(fileURLWithPath: "/tmp/b")])
        XCTAssertEqual(trimmed.terminalCommands, ["npm run dev"], "命令要跟着目录一起删，不能错位")
        XCTAssertEqual(trimmed.applicationBundleIdentifiers, ["com.apple.Safari"])
        XCTAssertEqual(trimmed.windowFacts.map(\.applicationBundleIdentifier), ["com.apple.Safari"])
        XCTAssertEqual(trimmed.applications, ["Safari"])
    }

    /// 暂时放下：写回划掉后的现场与回来先看，切换瞬间不再重新采集把它捞回来。
    func testSetAsideForNowKeepsTheTrimmedSceneAndReturnCue() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "整理访谈材料"))
        let episode = try XCTUnwrap(workspace.startEpisode(
            targetID: target.id,
            context: ContextCapsule(files: [draft, outline])
        ))
        let kept = ContextCapsule(files: [draft])

        XCTAssertTrue(workspace.setAsideCurrent(.pause, keeping: kept, returnCue: "第 7 页的数据"))

        let paused = try XCTUnwrap(workspace.snapshot.episodes[episode.id])
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.returnCue, "第 7 页的数据")
        XCTAssertEqual(paused.context.files, [draft], "划掉的 outline 不该被带走")
    }

    /// 在等什么：变成等待，等待项带着写下的描述；空描述用默认文案。
    func testSetAsideAsWaitingCreatesTheWait() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "发布 1.4"))
        let episode = try XCTUnwrap(workspace.startEpisode(
            targetID: target.id,
            context: ContextCapsule(files: [draft])
        ))

        XCTAssertTrue(workspace.setAsideCurrent(.wait("CI 跑完"), returnCue: ""))

        // 球交到别人手里 = 这件事被放下了；它归「等着别人」是因为身上挂着
        // 一条没等到的结果，不是因为有个叫「等待中」的状态。
        let waiting = try XCTUnwrap(workspace.snapshot.episodes[episode.id])
        XCTAssertEqual(waiting.state, .paused)
        let item = try XCTUnwrap(workspace.snapshot.activeWaitingItems.first)
        XCTAssertEqual(item.episodeID, episode.id)
        XCTAssertEqual(item.description, "CI 跑完")
    }

    /// 做完了：这一段结束（completed），不是放下。
    func testSetAsideAsDoneEndsTheEpisode() throws {
        let workspace = makeWorkspace()
        let target = try XCTUnwrap(workspace.createTarget(name: "回复 Lena"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        XCTAssertTrue(workspace.setAsideCurrent(.done, returnCue: ""))

        let ended = try XCTUnwrap(workspace.snapshot.episodes[episode.id])
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.endedReason, .completed)
        XCTAssertNil(workspace.setAsideEpisodesContaining(target.id), "做完的事不该出现在放下的里")
    }

    /// 放下之后开始另一件：手上那件已是 paused，`startEpisode` 不会再放一次；
    /// 整个流程发生在静默切换里时，事后不弹「已放下」确认卡。
    func testQuietSwitchDoesNotAnnounceSetAside() throws {
        let workspace = makeWorkspace()
        let a = try XCTUnwrap(workspace.createTarget(name: "A"))
        let b = try XCTUnwrap(workspace.createTarget(name: "B"))
        let first = try XCTUnwrap(workspace.startEpisode(
            targetID: a.id,
            context: ContextCapsule(files: [draft])
        ))

        let started: AttentionEpisode? = workspace.performQuietSwitch {
            XCTAssertTrue(workspace.setAsideCurrent(.pause, keeping: ContextCapsule(files: [draft]), returnCue: "改第二段"))
            return workspace.startEpisode(targetID: b.id)
        }

        XCTAssertNotNil(started)
        XCTAssertEqual(workspace.currentEpisode?.targetID, b.id)
        XCTAssertEqual(workspace.snapshot.episodes[first.id]?.state, .paused)
        XCTAssertEqual(workspace.snapshot.episodes[first.id]?.returnCue, "改第二段")

        let expectation = expectation(description: "现场自动采集有机会完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertNil(workspace.recentSetAside, "静默切换之后不该再弹「已放下」确认卡")
    }
}

private extension AttentionWorkspace {
    func setAsideEpisodesContaining(_ targetID: UUID) -> AttentionEpisode? {
        snapshot.setAsideEpisodes.first { $0.targetID == targetID }
    }
}
