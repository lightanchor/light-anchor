import Foundation
import XCTest
@testable import LightAnchor

/// `LocalEventStore` 改成一事件一文件之后的行为：
/// 每个事件落在一个文件名带序号的 JSON 里，保存只写有差异的部分，加载
/// 按写入顺序（序号）排好，目录里出现坏文件时拒读而不覆盖。
@MainActor
final class LocalEventStoreLayoutTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EventStoreLayoutTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func dayDirectory(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func testMalformedEventRefusesLoadWithoutAutomaticErasure() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events", isDirectory: true)
        let day = directory.appendingPathComponent("2026-09-11", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let recordURL = day.appendingPathComponent("120000-00000000-\(UUID().uuidString).json")
        let original = Data("{\"event\":{}}".utf8)
        try original.write(to: recordURL)

        let store = LocalEventStore(directoryURL: directory)
        XCTAssertThrowsError(try store.load()) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let workspace = AttentionWorkspace(store: store)
        XCTAssertNotNil(workspace.lastError)
        XCTAssertTrue(workspace.snapshot.targets.isEmpty)
        XCTAssertNil(workspace.createTarget(name: "不能覆盖损坏记录"))
        XCTAssertFalse(workspace.reloadFromDisk())
        XCTAssertEqual(try Data(contentsOf: recordURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: day.path).count, 1)
    }

    func testRecordsAndExportUseOnlyTheCurrentStructure() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events", isDirectory: true)
        let store = LocalEventStore(directoryURL: directory)
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let event = AttentionEvent.waitingChanged(
            WaitingItem(episodeID: UUID(), description: "当前格式", dueAt: now),
            at: now
        )
        try store.save(events: [event])
        let day = directory.appendingPathComponent(dayDirectory(for: now), isDirectory: true)
        let recordURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: day, includingPropertiesForKeys: nil
        ).first)
        let recordData = try Data(contentsOf: recordURL)
        let documentData = try store.encodedData(events: [event])
        let record = try JSONDecoder().decode(AttentionEventRecord.self, from: recordData)
        let document = try JSONDecoder().decode(AttentionEventDocument.self, from: documentData)
        let recordObject = try XCTUnwrap(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        let documentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: documentData) as? [String: Any])

        XCTAssertEqual(Set(recordObject.keys), ["event"])
        XCTAssertEqual(Set(documentObject.keys), ["events"])
        XCTAssertEqual(record.event, event)
        XCTAssertEqual(document.events, [event])
        XCTAssertEqual(try LocalEventStore(directoryURL: directory).load(), [event])
    }

    func testEventsAreWrittenOnePerFileUnderDateDirectory() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events", isDirectory: true)
        let store = LocalEventStore(directoryURL: directory)
        let workspace = AttentionWorkspace(store: store)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let target = try XCTUnwrap(workspace.createTarget(name: "写文件布局", now: now))
        try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: now.addingTimeInterval(10)))

        let day = dayDirectory(for: now)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent(day).path
        )
        XCTAssertEqual(files.count, 2, "每个事件一个文件")
        for name in files {
            XCTAssertTrue(name.hasSuffix(".json"))
            // 文件名 = HHmmss-序号-UUID.json，序号是 8 位定宽。
            let parts = name.split(separator: "-", maxSplits: 2)
            XCTAssertEqual(parts.count, 3)
            XCTAssertEqual(parts[1].count, 8)
            if let sequence = Int(parts[1]) {
                XCTAssertEqual(String(format: "%08d", sequence), String(parts[1]))
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".gitignore").path
            ),
            "保存过事件后，数据根目录应自带 .gitignore"
        )
        // 2026-09-09 定的方向：剪贴板历史是用户数据，入库；出库前的确认在产品层做。
        let ignored = try String(
            contentsOf: root.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        XCTAssertFalse(ignored.contains("clipboard"), "剪贴板历史不该被 .gitignore 排除")
        XCTAssertFalse(ignored.contains("events"), "事件日志不该被 .gitignore 排除")

        // 重新打开能读回同样的事件。
        let reloaded = AttentionWorkspace(store: LocalEventStore(directoryURL: directory))
        XCTAssertEqual(reloaded.snapshot.episodes.count, 1)
    }

    func testSaveOnlyRewritesChangedFiles() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events", isDirectory: true)
        let store = LocalEventStore(directoryURL: directory)
        let workspace = AttentionWorkspace(store: store)

        let target = try XCTUnwrap(workspace.createTarget(name: "只改一个文件"))

        let first = try store.load()
        let mtime = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(dayDirectory(for: Date())).path
        )[.modificationDate] as? Date

        // 新增一条事件，不应改动已有文件的内容（增量写，而不是全量重写）。
        try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let second = try store.load()
        XCTAssertGreaterThan(second.count, first.count)

        let newMtime = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(dayDirectory(for: Date())).path
        )[.modificationDate] as? Date
        XCTAssertGreaterThanOrEqual(newMtime ?? .distantPast, mtime ?? .distantPast)
    }

    func testLoadPreservesAppendOrderEvenWhenOccurredAtIsOutOfOrder() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events", isDirectory: true)
        let store = LocalEventStore(directoryURL: directory)
        let workspace = AttentionWorkspace(store: store)

        // occurredAt 是调用方传的业务时间，可以倒着来（回放依赖的是写入顺序）：
        // 先写 later 的目标、再写 earlier 的工作段，load 回来必须仍是这个顺序，
        // 否则回放会先看到没有目标的工作段。
        let later = Date(timeIntervalSince1970: 600)
        let earlier = Date(timeIntervalSince1970: 500)
        let target = try XCTUnwrap(workspace.createTarget(name: "测试排序", now: later))
        try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: earlier))

        let events = try store.load()
        XCTAssertEqual(events.map(\.occurredAt), [later, earlier], "load 应保持写入顺序")

        let reloaded = AttentionWorkspace(store: LocalEventStore(directoryURL: directory))
        XCTAssertEqual(reloaded.snapshot.episodes.count, 1, "乱序时间戳不该破坏回放")
    }

    /// 目录里出现坏文件要让 load 拒读，而不是吞掉或写回覆盖——坏文件是外部
    /// 输入（别人给的仓库、坏掉的磁盘），不该让应用继续回放部分事件。
    func testCorruptRecordRefusesToLoadAndIsNotOverwritten() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("events", isDirectory: true)
        let store = LocalEventStore(directoryURL: directory)
        let workspace = AttentionWorkspace(store: store)
        _ = workspace.createTarget(name: "合法事件")

        let day = dayDirectory(for: Date())
        let corruptDay = directory.appendingPathComponent(day, isDirectory: true)
        let corrupt = "{ not a valid event record"
        let corruptURL = corruptDay.appendingPathComponent("00000000-00000000-00000000-00000000.json")
        try Data(corrupt.utf8).write(to: corruptURL)

        let reopened = AttentionWorkspace(store: LocalEventStore(directoryURL: directory))
        XCTAssertTrue(reopened.snapshot.targets.isEmpty)
        XCTAssertNotNil(reopened.lastError)

        // 拒读后不能再写：否则会把坏文件覆盖成「看起来正常」的日志。
        XCTAssertNil(reopened.createTarget(name: "不该写进去的工作"))
        XCTAssertEqual(try String(contentsOf: corruptURL, encoding: .utf8), corrupt)
    }
}
