import Foundation
import XCTest
@testable import LightAnchor

/// 双机同步：两台「机器」= 两个数据根目录 + 两个服务实例，共用一个本地
/// 裸仓库当远端。验证并集合并、新机接入、冲突裁决与收敛。
final class GitSyncTests: XCTestCase {
    private var machineA: URL!
    private var machineB: URL!
    private var bare: URL!
    private var defaultsA: UserDefaults!
    private var defaultsB: UserDefaults!
    private var suiteNames: [String] = []

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSyncTests-\(UUID().uuidString)", isDirectory: true)
        machineA = base.appendingPathComponent("machine-a", isDirectory: true)
        machineB = base.appendingPathComponent("machine-b", isDirectory: true)
        bare = base.appendingPathComponent("remote.git", isDirectory: true)
        for url: URL in [machineA, machineB, bare] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try GitRunner.run(in: bare, ["init", "--bare"])

        defaultsA = try makeDefaults()
        defaultsB = try makeDefaults()
        addTeardownBlock { [suiteNames] in
            for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        }
        addTeardownBlock { [base] in try? FileManager.default.removeItem(at: base) }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "light-anchor.tests.\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func service(for root: URL, defaults: UserDefaults) -> GitSnapshotService {
        let service = GitSnapshotService(rootURL: root, userDefaults: defaults)
        defaults.set("file://\(bare.path)", forKey: GitSnapshotService.remoteURLKey)
        return service
    }

    @MainActor
    private func workspace(on root: URL) -> AttentionWorkspace {
        AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true))
        )
    }

    // MARK: - 并集合并

    @MainActor
    func testTwoMachinesConvergeToTheUnionOfTheirEvents() throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        let serviceB = service(for: machineB, defaults: defaultsB)
        try serviceA.prepare()
        try serviceB.prepare()

        // A、B 各自记录不同的工作。
        let workspaceA = workspace(on: machineA)
        XCTAssertNotNil(workspaceA.createTarget(name: "A 机的工作"))
        let workspaceB = workspace(on: machineB)
        XCTAssertNotNil(workspaceB.createTarget(name: "B 机的工作"))

        // A 先同步（远端空 → 直接推），B 后同步（并集），A 再同步一次收敛。
        XCTAssertEqual(try serviceA.sync(), .alreadyUpToDate)
        XCTAssertEqual(try serviceB.sync(), .merged)
        XCTAssertEqual(try serviceA.sync(), .merged)

        // 两边看到同一组目标。
        let reloadedA = workspace(on: machineA)
        let reloadedB = workspace(on: machineB)
        XCTAssertEqual(reloadedA.snapshot.targets.count, 2)
        XCTAssertEqual(
            Set(reloadedA.snapshot.targets.values.map(\.name)),
            Set(reloadedB.snapshot.targets.values.map(\.name))
        )
        XCTAssertEqual(
            Set(reloadedA.snapshot.targets.keys),
            Set(reloadedB.snapshot.targets.keys)
        )
    }

    @MainActor
    func testFreshMachineAdoptsRemoteData() throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        try serviceA.prepare()
        let workspaceA = workspace(on: machineA)
        XCTAssertNotNil(workspaceA.createTarget(name: "老机器的工作"))
        _ = try serviceA.sync()

        // B 是全新机器：init 过但一个提交都没有 → 直接采纳远端。
        let serviceB = service(for: machineB, defaults: defaultsB)
        try serviceB.prepare()
        XCTAssertEqual(try serviceB.sync(), .merged)

        let reloadedB = workspace(on: machineB)
        XCTAssertEqual(reloadedB.snapshot.targets.values.map(\.name), ["老机器的工作"])
    }

    @MainActor
    func testSyncWhenNothingChangedIsUpToDate() throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        try serviceA.prepare()
        _ = workspace(on: machineA).createTarget(name: "一件事")
        _ = try serviceA.sync()
        XCTAssertEqual(try serviceA.sync(), .alreadyUpToDate)
    }

    // MARK: - 冲突裁决

    /// 同一条事件文件在两台机器上被改成不同内容：两边各自同步后，最终内容一致
    ///（收敛），且等于 blob 哈希较大的一方。
    @MainActor
    func testConflictingEditsConvergeToTheSameWinner() throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        try serviceA.prepare()
        let sharedPath = "events/2026-09-10/shared.json"
        try write("{\"v\":\"原始\"}", to: sharedPath, in: machineA)
        _ = try serviceA.snapshot(note: "共同起点")
        _ = try serviceA.sync()

        // B 接入拿到同一份。
        let serviceB = service(for: machineB, defaults: defaultsB)
        try serviceB.prepare()
        _ = try serviceB.sync()

        // 两边各改各的。
        try write("{\"v\":\"A 的版本\"}", to: sharedPath, in: machineA)
        try write("{\"v\":\"B 的版本\"}", to: sharedPath, in: machineB)

        // A 先同步（推上 A 版），B 同步遇冲突 → 裁决 → 推；A 再同步收敛。
        _ = try serviceA.sync()
        _ = try serviceB.sync()
        _ = try serviceA.sync()

        let contentA = try String(contentsOf: machineA.appendingPathComponent(sharedPath), encoding: .utf8)
        let contentB = try String(contentsOf: machineB.appendingPathComponent(sharedPath), encoding: .utf8)
        XCTAssertEqual(contentA, contentB, "两台机器必须收敛到同一内容")
        XCTAssertTrue(
            contentA == "{\"v\":\"A 的版本\"}" || contentA == "{\"v\":\"B 的版本\"}",
            "赢家必须是两版之一，而不是合并残片"
        )
    }

    /// 一边删除、一边修改：删除赢（隐私动作不能被旧副本复活）。
    @MainActor
    func testDeletionWinsOverConcurrentEdit() throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        try serviceA.prepare()
        let sharedPath = "events/2026-09-10/doomed.json"
        try write("{\"v\":\"待删\"}", to: sharedPath, in: machineA)
        _ = try serviceA.snapshot(note: "共同起点")
        _ = try serviceA.sync()

        let serviceB = service(for: machineB, defaults: defaultsB)
        try serviceB.prepare()
        _ = try serviceB.sync()

        // A 删，B 改。
        try FileManager.default.removeItem(at: machineA.appendingPathComponent(sharedPath))
        try write("{\"v\":\"B 还在改\"}", to: sharedPath, in: machineB)

        _ = try serviceA.sync()
        _ = try serviceB.sync()
        _ = try serviceA.sync()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: machineA.appendingPathComponent(sharedPath).path),
            "A 上保持已删"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: machineB.appendingPathComponent(sharedPath).path),
            "B 上的修改被删除盖过——删除优先"
        )
    }

    // MARK: - 同步状态记录

    /// 自动同步是静默的，成败都要留痕，设置页才有东西可给用户看。
    @MainActor
    func testSyncRecordsSuccessAndFailureState() throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        try serviceA.prepare()
        _ = workspace(on: machineA).createTarget(name: "一件事")

        XCTAssertNil(serviceA.lastSyncDate)
        _ = try serviceA.sync()
        XCTAssertNotNil(serviceA.lastSyncDate)
        XCTAssertNil(serviceA.lastSyncError)

        // 远端指向不存在的路径 → 失败要被记下来。
        defaultsA.set("file:///nonexistent/nowhere.git", forKey: GitSnapshotService.remoteURLKey)
        XCTAssertThrowsError(try serviceA.sync())
        XCTAssertNotNil(serviceA.lastSyncError)

        // 修好远端再同步，错误痕迹清掉。
        defaultsA.set("file://\(bare.path)", forKey: GitSnapshotService.remoteURLKey)
        _ = try serviceA.sync()
        XCTAssertNil(serviceA.lastSyncError)
    }

    // MARK: - 定时自动同步

    /// A 推了新内容后，B 的控制器在下一个周期自动把它拉进来并重载工作区。
    /// 闸门验证：B 若从未推送过（没确认过数据出机），定时器绝不同步。
    @MainActor
    func testAutoSyncPullsRemoteChangesOnSchedule() async throws {
        let serviceA = service(for: machineA, defaults: defaultsA)
        try serviceA.prepare()
        _ = workspace(on: machineA).createTarget(name: "A 机新工作")
        _ = try serviceA.sync()

        let serviceB = service(for: machineB, defaults: defaultsB)
        try serviceB.prepare()

        // 先验闸门：B 没推送过（lastPushDate == nil），自动同步不该跑。
        let gated = SnapshotController(
            service: serviceB, debounce: .seconds(60), autoSyncInterval: .milliseconds(120)
        )
        gated.start()
        try await Task.sleep(for: .milliseconds(400))
        gated.stop()
        XCTAssertNil(serviceB.lastPushDate, "从未确认出机的机器不该被定时器推出去")

        // 用户手动同步过一次（= 已确认出机），此后定时器接管。
        _ = try serviceB.sync()
        _ = workspace(on: machineA).createTarget(name: "A 机后来的工作")
        _ = try serviceA.sync()

        let workspaceB = workspace(on: machineB)
        let controller = SnapshotController(
            service: serviceB, debounce: .seconds(60), autoSyncInterval: .milliseconds(200)
        )
        controller.workspace = workspaceB
        controller.start()
        defer { controller.stop() }

        // 窗口放宽到 30 秒：全量测试时磁盘上有大量并发 git 进程与后台任务，
        // 单轮同步会显著变慢；这里测的是「会发生」，不是「多快发生」。
        var converged = false
        for _ in 0..<200 {
            if workspaceB.snapshot.targets.values.map(\.name).contains("A 机后来的工作") {
                converged = true
                break
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertTrue(converged, "自动同步应把 A 的新内容拉进 B 并重载工作区")
    }

    // MARK: - 工具

    private func write(_ content: String, to relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }
}
