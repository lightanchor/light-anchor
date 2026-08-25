import XCTest
@testable import LightAnchor

final class EnvironmentSnapshotTests: XCTestCase {
    func testDraftMapsApplicationsFilesAndLinksInOrder() throws {
        let capsule = ContextCapsule(
            applications: ["Xcode", "Safari"],
            applicationBundleIdentifiers: ["com.apple.dt.Xcode", "com.apple.Safari"],
            windows: ["LightAnchor.swift", "文档"],
            files: [URL(fileURLWithPath: "/tmp/LightAnchor.swift")],
            links: [URL(string: "https://example.com/docs")!]
        )

        let draft = EnvironmentSnapshotBuilder.draft(
            from: capsule,
            capturedAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        XCTAssertEqual(draft.actions.map(\.kind), [
            .openApplication, .openApplication, .openFile, .openURL
        ])
        XCTAssertEqual(draft.actions.map(\.value), [
            "com.apple.dt.Xcode",
            "com.apple.Safari",
            "/tmp/LightAnchor.swift",
            "https://example.com/docs"
        ])
        XCTAssertTrue(draft.actions.allSatisfy(\.isEnabled))
        XCTAssertTrue(draft.name.hasPrefix("现场 "))
        // 应用限制随快照带上,否则 openApplication 会被授权门拦下。
        XCTAssertEqual(
            draft.allowedApplicationBundleIdentifiers,
            ["com.apple.dt.Xcode", "com.apple.Safari"]
        )
    }

    func testDraftDeduplicatesAndDropsNonWebLinks() throws {
        let capsule = ContextCapsule(
            applicationBundleIdentifiers: ["com.apple.Safari", "com.apple.Safari", " "],
            files: [
                URL(fileURLWithPath: "/tmp/a.txt"),
                URL(fileURLWithPath: "/tmp/a.txt")
            ],
            links: [
                URL(string: "https://example.com")!,
                URL(string: "https://example.com")!,
                URL(string: "ftp://example.com/file")!
            ]
        )

        let draft = EnvironmentSnapshotBuilder.draft(from: capsule)

        XCTAssertEqual(draft.actions.count, 3)
        XCTAssertEqual(
            draft.actions.map(\.value),
            ["com.apple.Safari", "/tmp/a.txt", "https://example.com"]
        )
        XCTAssertEqual(draft.allowedApplicationBundleIdentifiers, ["com.apple.Safari"])
    }

    func testEmptyCapsuleYieldsNoActions() {
        let draft = EnvironmentSnapshotBuilder.draft(from: ContextCapsule())
        XCTAssertTrue(draft.actions.isEmpty)
        XCTAssertTrue(draft.allowedApplicationBundleIdentifiers.isEmpty)
    }

    func testHistoricalSceneCreatesReviewableEnvironmentWithoutTerminalAction() {
        let scene = SceneSnapshot(
            items: [
                SceneItem(
                    kind: .application,
                    title: "Xcode",
                    address: "com.apple.dt.Xcode"
                ),
                SceneItem(
                    kind: .file,
                    title: "Plan.md",
                    address: "file:///tmp/Plan.md"
                ),
                SceneItem(
                    kind: .link,
                    title: "Docs",
                    address: "https://example.com/docs"
                ),
                SceneItem(
                    kind: .terminal,
                    title: "project",
                    address: "file:///tmp/project",
                    detail: "swift test"
                ),
                SceneItem(
                    kind: .application,
                    title: "Music",
                    address: "com.apple.Music",
                    isRelevant: false
                )
            ],
            filterMode: .aiFiltered,
            capturedAt: Date(timeIntervalSinceReferenceDate: 123)
        )

        let draft = EnvironmentSnapshotBuilder.draft(from: scene)

        XCTAssertEqual(draft.actions.map(\.kind), [
            .openApplication, .openFile, .openURL
        ])
        XCTAssertEqual(draft.actions.map(\.value), [
            "com.apple.dt.Xcode", "/tmp/Plan.md", "https://example.com/docs"
        ])
        XCTAssertFalse(draft.actions.contains { $0.kind == .runCommand })
        XCTAssertEqual(draft.allowedApplicationBundleIdentifiers, ["com.apple.dt.Xcode"])
    }
}
