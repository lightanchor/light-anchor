import Foundation
import XCTest
@testable import LightAnchor

/// 覆盖 2026-08-22 补齐的两块：环境的预览/收场，和四个现场开关的真实链路。
final class EnvironmentPreviewAndSwitchesTests: XCTestCase {

    // MARK: - 环境预览（干跑）

    func testPreviewMarksDisabledActionAsSkip() {
        let profile = EnvironmentProfile(
            name: "预览",
            actions: [EnvironmentAction(kind: .runCommand, value: "echo hi", isEnabled: false)]
        )
        let previews = EnvironmentActionRunner().preview(profile)
        XCTAssertEqual(previews.count, 1)
        guard case .willSkip(let reason) = previews[0].status else {
            return XCTFail("关闭的动作应标记为跳过，实际 \(previews[0].status)")
        }
        XCTAssertTrue(reason.contains("关闭"))
    }

    func testPreviewBlocksEmptyValueAndMissingFile() {
        let profile = EnvironmentProfile(
            name: "预览",
            actions: [
                EnvironmentAction(kind: .openURL, value: ""),
                EnvironmentAction(kind: .openFile, value: "/nonexistent/light-anchor-\(UUID().uuidString)")
            ]
        )
        let previews = EnvironmentActionRunner().preview(profile)
        guard case .blocked = previews[0].status else {
            return XCTFail("空值应标记为会失败")
        }
        guard case .blocked(let reason) = previews[1].status else {
            return XCTFail("不存在的文件应标记为会失败")
        }
        XCTAssertTrue(reason.contains("不存在"))
    }

    func testPreviewSkipsApplicationOutsideAllowedList() {
        let profile = EnvironmentProfile(
            name: "受限",
            actions: [EnvironmentAction(kind: .openApplication, value: "com.example.NotAllowed")],
            allowedApplicationBundleIdentifiers: ["com.apple.TextEdit"]
        )
        let previews = EnvironmentActionRunner().preview(profile)
        guard case .willSkip(let reason) = previews[0].status else {
            return XCTFail("允许列表外的应用应标记为跳过")
        }
        XCTAssertTrue(reason.contains("允许列表"))
    }

    func testPreviewReadyForRunCommandAndNeverExecutes() {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-anchor-preview-\(UUID().uuidString)")
        let profile = EnvironmentProfile(
            name: "预览",
            actions: [EnvironmentAction(kind: .runCommand, value: "touch \(markerURL.path)")]
        )
        let previews = EnvironmentActionRunner().preview(profile)
        XCTAssertEqual(previews[0].status, .ready)
        XCTAssertEqual(previews[0].detail, "touch \(markerURL.path)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "预览不能执行任何动作"
        )
    }

    // MARK: - 环境收场

    func testCloseOutWithNothingToRestoreReturnsNoResults() async {
        let execution = EnvironmentExecution(results: [], undoSteps: [])
        let results = await EnvironmentActionRunner().closeOut(
            execution,
            quitLaunchedApplications: true
        )
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(execution.isCloseOutMeaningful)
    }

    func testExecutionWithLaunchedApplicationsIsCloseOutMeaningful() {
        let execution = EnvironmentExecution(
            results: [],
            undoSteps: [],
            launchedApplicationBundleIdentifiers: ["com.apple.TextEdit"]
        )
        XCTAssertTrue(execution.isCloseOutMeaningful)
    }

    // MARK: - 现场快照带上终端命令与剪贴板

    func testBuilderCarriesTerminalCommandAndClipboardIntoSnapshot() async {
        let capsule = ContextCapsule(
            applications: ["Terminal"],
            applicationBundleIdentifiers: ["com.apple.Terminal"],
            terminalWorkingDirectories: [URL(fileURLWithPath: "/tmp/project", isDirectory: true)],
            terminalCommands: ["swift test"],
            clipboardText: "剪贴板里的一段话"
        )
        let snapshot = await SceneSnapshotBuilder.buildSnapshot(
            from: capsule,
            targetID: nil,
            targetName: "测试",
            targetNote: "",
            filterMode: .saveAll,
            engine: HeuristicIntelligenceEngine(),
            generateReturnCue: false
        )
        let terminalItem = snapshot.items.first { $0.kind == .terminal }
        XCTAssertEqual(terminalItem?.detail, "swift test")
        XCTAssertEqual(snapshot.clipboardText, "剪贴板里的一段话")
    }

    // MARK: - 收件箱自动整理

    func testHostTagStripsWWWAndRejectsNonHTTP() {
        XCTAssertEqual(
            InboxAutoOrganizer.hostTag(for: URL(string: "https://www.github.com/a/b")!),
            "github.com"
        )
        XCTAssertEqual(
            InboxAutoOrganizer.hostTag(for: URL(string: "http://developer.apple.com")!),
            "developer.apple.com"
        )
        XCTAssertNil(InboxAutoOrganizer.hostTag(for: URL(fileURLWithPath: "/tmp/x")))
    }

    func testNeedsTitleOnlyForBareLinkCaptures() {
        let url = URL(string: "https://example.com/article")!
        let bare = CaptureItem(kind: .link, body: url.absoluteString, sourceURL: url)
        XCTAssertTrue(InboxAutoOrganizer.needsTitle(bare))
        XCTAssertTrue(InboxAutoOrganizer.canOrganize(bare))

        let titled = CaptureItem(kind: .link, body: "好文章", title: "好文章", sourceURL: url)
        XCTAssertFalse(InboxAutoOrganizer.needsTitle(titled))
        // 有标题但缺域名标签：仍有整理空间
        XCTAssertTrue(InboxAutoOrganizer.canOrganize(titled))

        let organized = CaptureItem(
            kind: .link, body: "好文章", title: "好文章",
            sourceURL: url, tags: ["example.com"]
        )
        XCTAssertFalse(InboxAutoOrganizer.canOrganize(organized))

        let text = CaptureItem(kind: .text, body: "一句想法")
        XCTAssertFalse(InboxAutoOrganizer.canOrganize(text))
    }

    // MARK: - ADHD 友好输出

    func testStyledAppendsAdhdBlockOnlyWhenEnabled() {
        let base = IntelligencePrompts.returnCueInstructions
        let styled = IntelligencePrompts.styled(base, adhdFriendly: true)
        XCTAssertTrue(styled.hasPrefix(base), "塑形块必须附加在任务指令之后，不能改写任务本身")
        XCTAssertTrue(styled.contains("ADHD"))
        XCTAssertEqual(IntelligencePrompts.styled(base, adhdFriendly: false), base)
    }

    func testAdhdFriendlyOutputDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(IntelligencePreferences.default.adhdFriendlyOutput, "开关必须默认打开")

        var prefs = IntelligencePreferences.default
        prefs.adhdFriendlyOutput = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(IntelligencePreferences.self, from: data)
        XCTAssertFalse(decoded.adhdFriendlyOutput)
    }

    func testFactoryPassesAdhdFlagToCloudEngine() {
        var preferences = IntelligencePreferences.default
        preferences.engine = .cloud
        preferences.adhdFriendlyOutput = false
        let engine = IntelligenceEngineFactory.make(preferences: preferences)
        let cloud = engine as? CloudIntelligenceEngine
        XCTAssertEqual(cloud?.adhdFriendlyOutput, false)

        preferences.adhdFriendlyOutput = true
        let enabled = IntelligenceEngineFactory.make(preferences: preferences) as? CloudIntelligenceEngine
        XCTAssertEqual(enabled?.adhdFriendlyOutput, true)
    }

    func testParseTitleDecodesEntitiesAndTrims() {
        let html = "<html><head><title>\n  Swift &amp; SwiftUI — a &quot;guide&quot;  \n</title></head></html>"
        XCTAssertEqual(
            InboxLinkTitleFetcher.parseTitle(from: html),
            "Swift & SwiftUI — a \"guide\""
        )
        XCTAssertNil(InboxLinkTitleFetcher.parseTitle(from: "<html><body>无标题</body></html>"))
        XCTAssertNil(InboxLinkTitleFetcher.parseTitle(from: "<title>   </title>"))
    }
}
