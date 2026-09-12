import Foundation
import XCTest
@testable import LightAnchor

/// `GitSnapshotService` 的集成测试：真实 git、真实临时目录。
/// 远端用本地裸仓库（file://），推送全链路可测且不出机器。
final class GitSnapshotServiceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsName = "light-anchor.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    private func makeService() -> GitSnapshotService {
        GitSnapshotService(rootURL: root, userDefaults: defaults)
    }

    private func write(_ content: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    // MARK: - 初始化

    func testPrepareCreatesRepositoryWithLocalIdentity() throws {
        let service = makeService()
        XCTAssertFalse(service.isRepository)
        try service.prepare()
        XCTAssertTrue(service.isRepository)

        // 身份写在仓库本地 config，不碰全局。
        let name = try GitRunner.run(in: root, ["config", "user.name"])
        XCTAssertEqual(name, "LightAnchor")
        let localOnly = try GitRunner.run(in: root, ["config", "--local", "user.name"])
        XCTAssertEqual(localOnly, "LightAnchor")
    }

    func testPrepareIsIdempotent() throws {
        let service = makeService()
        try service.prepare()
        try service.prepare()
        XCTAssertTrue(service.isRepository)
    }

    // MARK: - 快照

    func testSnapshotWithoutRepositoryDoesNothing() throws {
        let service = makeService()
        try write("内容", to: "events/2026-09-10/a.json")
        // 未 prepare 时快照是无操作：绝不自己 git init。
        XCTAssertNil(try service.snapshot())
        XCTAssertFalse(service.isRepository)
    }

    func testSnapshotCommitsChangesAndSkipsWhenClean() throws {
        let service = makeService()
        try service.prepare()
        try write("第一批", to: "events/2026-09-10/a.json")

        let first = try XCTUnwrap(try service.snapshot(note: "第一批事件"))
        XCTAssertEqual(first.subject, "第一批事件")

        // 无变化 → 不产生空提交。
        XCTAssertNil(try service.snapshot(note: "不该出现"))

        try write("第二批", to: "events/2026-09-10/b.json")
        let second = try XCTUnwrap(try service.snapshot())
        XCTAssertEqual(second.subject, "保存工作区变化")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testHistoryListsNewestFirst() throws {
        let service = makeService()
        try service.prepare()
        try write("一", to: "events/a.json")
        _ = try service.snapshot(note: "第一个")
        try write("二", to: "events/b.json")
        _ = try service.snapshot(note: "第二个")

        let history = try service.history()
        XCTAssertEqual(history.map(\.subject), ["第二个", "第一个"])
    }

    // MARK: - 还原

    func testRestoreReturnsToEarlierStateAndKeepsHistory() throws {
        let service = makeService()
        try service.prepare()
        try write("昨天的内容", to: "events/a.json")
        let yesterday = try XCTUnwrap(try service.snapshot(note: "昨天"))

        try write("今天的内容", to: "events/a.json")
        try write("今天新增", to: "events/b.json")
        _ = try service.snapshot(note: "今天")

        // 还原前会自动把当前状态拍下来吗？——这里工作区是干净的（已快照），
        // 所以 before 为 nil；数据回到昨天，b.json 消失。
        let before = try service.restore(to: yesterday.id)
        XCTAssertNil(before)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("events/a.json"), encoding: .utf8),
            "昨天的内容"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("events/b.json").path)
        )
        // 版本历史还在：还能看到「今天」那个快照。
        // reset --hard 会把分支指回昨天，但对象仍在仓库里；用 reflog 确认可回。
        let reflog = try GitRunner.run(in: root, ["reflog", "-n", "5"])
        XCTAssertTrue(reflog.contains("reset"))
    }

    func testRestoreSnapshotsDirtyStateFirstSoNothingIsLost() throws {
        let service = makeService()
        try service.prepare()
        try write("已快照的", to: "events/a.json")
        let target = try XCTUnwrap(try service.snapshot(note: "基准"))

        // 有未快照的改动时还原：先自动拍一张，改动可从历史找回。
        try write("没来得及快照的", to: "events/dirty.json")
        let before = try XCTUnwrap(try service.restore(to: target.id))
        XCTAssertEqual(before.subject, "回到版本 \(target.id.prefix(8)) 前，存下当前状态")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("events/dirty.json").path)
        )

        // 从「还原前」快照再还原回来，脏文件失而复得。
        _ = try service.restore(to: before.id)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("events/dirty.json"), encoding: .utf8),
            "没来得及快照的"
        )
    }

    func testRestoreToUnknownSnapshotThrows() throws {
        let service = makeService()
        try service.prepare()
        try write("内容", to: "events/a.json")
        _ = try service.snapshot()
        XCTAssertThrowsError(try service.restore(to: "0000000000000000000000000000000000000000"))
    }

    // MARK: - 远程推送

    func testPushToLocalBareRepositoryAndRecordsDate() throws {
        let service = makeService()
        try service.prepare()
        try write("要备份的", to: "events/a.json")
        _ = try service.snapshot(note: "备份内容")

        // 「远端」= 本地裸仓库。file:// 也是合法远端（U 盘、NAS 都走这条路）。
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSnapshotTests-remote-\(UUID().uuidString).git", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try GitRunner.run(in: bare, ["init", "--bare"])

        XCTAssertNil(service.lastPushDate)
        service.remoteURL = URL(string: "file://\(bare.path)")
        try service.push()
        XCTAssertNotNil(service.lastPushDate)

        // 远端真的收到了内容（裸仓库 HEAD 默认指 master，明确查 main 分支）。
        let remoteLog = try GitRunner.run(in: bare, ["log", "main", "--format=%s", "-n", "1"])
        XCTAssertEqual(remoteLog, "备份内容")

        // 再推一次（无新内容）也成功——幂等。
        try service.push()
    }

    func testPushWithoutRemoteThrows() throws {
        let service = makeService()
        try service.prepare()
        XCTAssertThrowsError(try service.push()) { error in
            guard case GitServiceError.noRemoteConfigured = error else {
                return XCTFail("应报「还没有填备份地址」，实际：\(error)")
            }
        }
    }

    // MARK: - 删除

    func testRemoveRepositoryDeletesGitDirectoryOnly() throws {
        let service = makeService()
        try service.prepare()
        try write("数据", to: "events/a.json")
        _ = try service.snapshot()

        try service.removeRepository()
        XCTAssertFalse(service.isRepository)
        // 数据文件不动：删的是版本库，不是数据。
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("events/a.json").path)
        )
    }

    func testHistoryParsingHandlesUnicodeSeparators() {
        let output = "abc\u{001f}1700000000\u{001f}主题一\u{0000}def\u{001f}1700000100\u{001f}主题 二\u{0000}"
        let parsed = GitSnapshotService.parseHistory(output)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "abc")
        XCTAssertEqual(parsed[0].subject, "主题一")
        XCTAssertEqual(parsed[1].subject, "主题 二")
    }
}
