import Foundation
import XCTest
@testable import LightAnchor

/// 端到端：事件落盘 → `lightAnchorEventsChanged` 通知 → 去抖 → git 快照。
@MainActor
final class SnapshotControllerTests: XCTestCase {
    func testCommittingEventsProducesADebouncedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: defaultsName) }

        let service = GitSnapshotService(rootURL: root, userDefaults: defaults)
        let controller = SnapshotController(service: service, debounce: .milliseconds(50))
        controller.start()
        defer { controller.stop() }

        // 事件写进同一个数据根目录，workspace 的 commit 会发通知。
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true))
        )
        XCTAssertNotNil(workspace.createTarget(name: "触发快照的工作"))

        // 等去抖窗口过去、快照落盘（轮询，最多 5 秒）。
        var history: [LightAnchorSnapshot] = []
        for _ in 0..<100 {
            history = (try? service.history()) ?? []
            if !history.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(history.isEmpty, "事件提交后应自动产生一个快照")
    }
}
