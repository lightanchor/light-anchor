import Foundation
import XCTest
@testable import LightAnchor

/// 捕获去向：稍后（inbox）与暂存箱（reference）在落盘那一刻就分开。
@MainActor
final class CaptureDestinationTests: XCTestCase {
    private func makeWorkspace() -> AttentionWorkspace {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-destination-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
        return AttentionWorkspace(store: LocalEventStore(directoryURL: url))
    }

    func testDefaultCaptureLandsInLater() throws {
        let workspace = makeWorkspace()
        let capture = try XCTUnwrap(workspace.captureText("回头修构建脚本"))
        XCTAssertEqual(capture.status, .inbox)
        XCTAssertEqual(workspace.snapshot.inbox.map(\.id), [capture.id])
        XCTAssertTrue(workspace.snapshot.referenceCaptures.isEmpty)
    }

    func testStagingDestinationLandsInStagingBox() throws {
        let workspace = makeWorkspace()
        let thought = try XCTUnwrap(
            workspace.captureText("一个想法", destination: .reference)
        )
        let link = try XCTUnwrap(
            workspace.captureLink(
                XCTUnwrap(URL(string: "https://example.com/spec")),
                destination: .reference
            )
        )
        XCTAssertEqual(thought.status, .reference)
        XCTAssertEqual(link.status, .reference)
        XCTAssertTrue(workspace.snapshot.inbox.isEmpty, "存进暂存箱的不该出现在稍后")
        XCTAssertEqual(
            Set(workspace.snapshot.referenceCaptures.map(\.id)),
            [thought.id, link.id]
        )
    }

    /// 只认稍后/暂存箱两个去向：传别的值不得让捕获凭空变成已归档。
    func testUnsupportedDestinationFallsBackToLater() throws {
        let workspace = makeWorkspace()
        let capture = try XCTUnwrap(
            workspace.captureText("异常去向", destination: .archived)
        )
        XCTAssertEqual(capture.status, .inbox)
    }
}
