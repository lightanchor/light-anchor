import Foundation
import XCTest
@testable import LightAnchorEventCore

final class EventProtocolTests: XCTestCase {
    func testEventLogRoundTripsRecordsAndAcceptsOneTrailingNewline() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("events.jsonl")
        let log = LightAnchorEventLog(fileURL: fileURL)
        let event = LightAnchorEventRecord(
            source: .terminal,
            kind: .completed,
            correlationID: "native-task-1",
            title: "本地任务",
            detail: "退出码 0",
            payload: ["exitCode": "0"],
            occurredAt: Date(timeIntervalSince1970: 1_754_464_000),
            processIdentifier: 42,
            workingDirectory: URL(fileURLWithPath: "/tmp/light-anchor")
        )

        try log.append(event)

        let records = try log.records()
        XCTAssertEqual(records, [event])
        XCTAssertTrue(try Data(contentsOf: fileURL).last == 0x0A)
    }

    func testEventLogRejectsInternalBlankLinesAndInvalidRecords() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("events.jsonl")
        let log = LightAnchorEventLog(fileURL: fileURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let event = LightAnchorEventRecord(
            source: .build,
            kind: .completed,
            correlationID: "build-1",
            title: "构建",
            detail: "完成"
        )
        let data = try encoder.encode(event)
        try (data + Data([0x0A, 0x0A]) + data + Data([0x0A])).write(to: fileURL)

        XCTAssertThrowsError(try log.records()) { error in
            XCTAssertEqual(error as? LightAnchorEventLogError, .unreadableRecord)
        }

        try Data("{not-json}\n".utf8).write(to: fileURL)
        XCTAssertThrowsError(try log.records()) { error in
            XCTAssertEqual(error as? LightAnchorEventLogError, .unreadableRecord)
        }
    }

    func testEventLogRejectsNonTerminalEventWithoutTitleOrDetail() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("events.jsonl")
        let log = LightAnchorEventLog(fileURL: fileURL)
        let event = LightAnchorEventRecord(
            source: .terminal,
            kind: .started,
            correlationID: "missing-content"
        )

        XCTAssertThrowsError(try log.append(event)) { error in
            XCTAssertEqual(error as? LightAnchorEventLogError, .invalidEvent)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorEventProtocolTests")
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
