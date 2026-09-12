import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class AttentionActionTests: XCTestCase {
    func testCaptureActionUsesTheAttachedWorkspace() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
        AttentionActionRouter.shared.attach(workspace: workspace)

        let result = AttentionActionRouter.shared.perform(
            .captureText("从快捷动作捕获的想法"),
            now: Date(timeIntervalSince1970: 100)
        )

        guard case .captured(let captureID) = result else {
            return XCTFail("Expected a captured result, got \(result)")
        }
        XCTAssertEqual(workspace.snapshot.inbox.map(\.id), [captureID])
    }

    func testManualWaitingActionRequiresAndUsesCurrentEpisode() throws {
        let workspace = AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
        AttentionActionRouter.shared.attach(workspace: workspace)
        let target = try XCTUnwrap(workspace.createTarget(name: "快捷动作测试"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        let result = AttentionActionRouter.shared.perform(
            .beginManualWaiting("等我回来再继续"),
            now: Date(timeIntervalSince1970: 200)
        )

        guard case .waitingStarted(let waitingID) = result else {
            return XCTFail("Expected a waiting result, got \(result)")
        }
        XCTAssertEqual(workspace.snapshot.waitingItems[waitingID]?.episodeID, episode.id)
        // 交出去之后它就不占「现在」页了——你在等的时候一定在做别的。
        XCTAssertNil(workspace.currentEpisode)
        XCTAssertEqual(workspace.snapshot.episodes[episode.id]?.state, .paused)
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorActionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events", isDirectory: true)
    }
}
