import Foundation
import XCTest
@testable import LightAnchor

/// 备份要装得下「这台机器上的用户数据」的全部，不只是数据目录。
///
/// 回顾正文、云端配置、快捷键、采集偏好都住在 UserDefaults 里：只打包目录的
/// 备份，换机恢复后这些会静静地全丢——而用户手里那个 zip 看起来是完整备份。
final class LocalBackupPreferencesTests: XCTestCase {

    func testArchiveCarriesPreferencesAndRestoreWritesThemBack() throws {
        let workspace = try makeWorkspaceDirectory()
        let defaults = try makeScratchDefaults()
        try writeEmptyEventLog(in: workspace.root)

        // 用户写的回顾正文与填过的云端配置。
        NarrativeStore.save("这周把删除链路补齐了。", forKey: "week-2026-08-17", defaults: defaults)
        var preferences = IntelligencePreferences.default
        preferences.activeCloudProfile.apiKey = "sk-backup"
        preferences.saveClipboardContent = false
        preferences.save(to: defaults)

        let service = LocalDataArchiveService(rootURL: workspace.root, defaults: defaults)
        try service.createArchive(at: workspace.archive)

        // 备份之后本机改动/丢失。
        defaults.removeObject(forKey: NarrativeStore.storageKey)
        defaults.removeObject(forKey: IntelligencePreferences.storageKey)

        try service.restoreArchive(from: workspace.archive)

        XCTAssertEqual(
            NarrativeStore.text(forKey: "week-2026-08-17", defaults: defaults),
            "这周把删除链路补齐了。"
        )
        let restored = IntelligencePreferences.load(from: defaults)
        XCTAssertEqual(restored.activeCloudProfile.apiKey, "sk-backup")
        XCTAssertFalse(restored.saveClipboardContent)
    }

    /// 偏好文件是备份的载体，不是数据目录的成员：恢复完不能留在数据目录里。
    func testRestoreDoesNotLeavePreferencesFileInsideTheDataDirectory() throws {
        let workspace = try makeWorkspaceDirectory()
        let defaults = try makeScratchDefaults()
        try writeEmptyEventLog(in: workspace.root)

        let service = LocalDataArchiveService(rootURL: workspace.root, defaults: defaults)
        try service.createArchive(at: workspace.archive)
        try service.restoreArchive(from: workspace.archive)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.root
                    .appendingPathComponent(LocalPreferencesArchive.fileName).path
            )
        )
    }

    /// 备份文件是外部输入：里面出现清单外的键，一律不写进 UserDefaults。
    func testRestoreIgnoresKeysOutsideTheArchiveInventory() throws {
        let defaults = try makeScratchDefaults()
        let crafted: [String: Any] = [
            NarrativeStore.storageKey: Data("真键".utf8),
            "com.apple.somebody.elses.setting": "别写我",
            "lightanchor.notAKeyWeKnow": true
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: crafted,
            format: .xml,
            options: 0
        )

        try LocalPreferencesArchive.restore(from: data, into: defaults)

        XCTAssertNotNil(defaults.object(forKey: NarrativeStore.storageKey))
        XCTAssertNil(defaults.object(forKey: "com.apple.somebody.elses.setting"))
        XCTAssertNil(defaults.object(forKey: "lightanchor.notAKeyWeKnow"))
    }

    /// 偏好快照是备份的一部分：包里没有它就不是我们打的包，整体拒绝，
    /// 现有数据目录一个字都不动。
    func testRestoreRejectsArchivesWithoutAPreferencesFile() throws {
        let workspace = try makeWorkspaceDirectory()
        let defaults = try makeScratchDefaults()
        let staging = workspace.directory.appendingPathComponent("staging", isDirectory: true)
        let payload = staging.appendingPathComponent("LightAnchorData", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try writeEmptyEventLog(in: payload)
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, workspace.archive.path])
        let existingMarker = workspace.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existingMarker)

        let service = LocalDataArchiveService(rootURL: workspace.root, defaults: defaults)
        XCTAssertThrowsError(try service.restoreArchive(from: workspace.archive)) { error in
            guard case LocalDataArchiveError.archiveStructureInvalid = error else {
                return XCTFail("应报备份结构不完整，实际：\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: existingMarker), Data("keep".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("events.json").path)
        )
    }

    /// 恢复前会先解一遍事件日志，所以夹具必须是合法的空日志，而不是随便一串字节。
    private func writeEmptyEventLog(in root: URL) throws {
        try LocalEventStore(fileURL: root.appendingPathComponent("events.json")).save(events: [])
    }

    // MARK: - 工具

    private struct WorkspaceDirectory {
        let directory: URL
        let root: URL
        let archive: URL
    }

    private func makeWorkspaceDirectory() throws -> WorkspaceDirectory {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-anchor-backup-prefs-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("LightAnchorData", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return WorkspaceDirectory(
            directory: directory,
            root: root,
            archive: directory.appendingPathComponent("backup.zip")
        )
    }

    /// 独立的 UserDefaults 域：测试绝不能碰跑测试这台机器上的真实偏好。
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
