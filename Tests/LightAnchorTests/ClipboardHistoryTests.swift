import Foundation
import XCTest
@testable import LightAnchor

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    // MARK: - 辅助

    /// 可控的「系统剪贴板」：测试里改 text 就等于用户复制了一次。
    private final class FakeClipboard {
        private(set) var changeCount = 0
        private(set) var text = ""
        var sourceApplication = "Safari"

        func copy(_ text: String) {
            self.text = text
            changeCount += 1
        }

        /// 模拟复制了机密 / 非文字 / 敏感前台：剪贴板变了，但读不到文字。
        func copyConcealed() {
            text = ""
            changeCount += 1
        }

        func sample() -> ClipboardSample {
            ClipboardSample(changeCount: changeCount, text: text, sourceApplication: sourceApplication)
        }
    }

    // 开关住在标准 UserDefaults 里，测试改过必须原样放回，否则会串到别的测试。
    private var savedIntelligencePreferences: IntelligencePreferences!
    private var savedSceneCapturePreferences: SceneCapturePreferences!

    override func setUp() {
        super.setUp()
        savedIntelligencePreferences = IntelligencePreferences.load()
        savedSceneCapturePreferences = SceneCapturePreferences.load()
    }

    override func tearDown() {
        savedIntelligencePreferences.save()
        savedSceneCapturePreferences.save()
        super.tearDown()
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorClipboardTests-\(UUID().uuidString).json")
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAnchorClipboardTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeWorkspace(
        clipboard: FakeClipboard,
        storeURL: URL? = nil,
        historyDirectory: URL? = nil,
        saveClipboardContent: Bool = true
    ) -> AttentionWorkspace {
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: storeURL ?? temporaryEventsDirectoryURL()),
            sceneCapturePreferences: SceneCapturePreferences(),
            recordingTraceStore: RecordingTraceStore(directoryURL: temporaryDirectoryURL()),
            clipboardHistoryStore: ClipboardHistoryStore(directoryURL: historyDirectory ?? temporaryDirectoryURL()),
            clipboardSample: { clipboard.sample() },
            contextCapture: { _, _ in ContextCapsule() }
        )
        var preferences = IntelligencePreferences.default
        preferences.saveClipboardContent = saveClipboardContent
        workspace.updateIntelligencePreferences(preferences)
        return workspace
    }

    private func texts(_ workspace: AttentionWorkspace, _ episodeID: UUID) -> [String] {
        workspace.clipboardHistory(for: episodeID).map(\.text)
    }

    // MARK: - 仓库

    func testStoreRoundTripsEntries() throws {
        let store = ClipboardHistoryStore(directoryURL: temporaryDirectoryURL())
        let episodeID = UUID()
        let entries = [
            ClipboardHistoryEntry(text: "swift test", sourceApplication: "Terminal"),
            ClipboardHistoryEntry(text: "https://example.com", sourceApplication: "Safari")
        ]
        try store.save(entries, for: episodeID)
        XCTAssertEqual(store.load(for: episodeID), entries)
        store.remove(for: episodeID)
        XCTAssertTrue(store.load(for: episodeID).isEmpty)
    }

    // MARK: - 跟随事情

    func testStartRecordsWhatIsInHandAndEveryCopyAfterwards() throws {
        let clipboard = FakeClipboard()
        clipboard.copy("开始前手上拿着的")
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        XCTAssertEqual(texts(workspace, episode.id), ["开始前手上拿着的"])

        clipboard.copy("第一段")
        workspace.sampleClipboardNow()
        clipboard.copy("第二段")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["开始前手上拿着的", "第一段", "第二段"])
        XCTAssertEqual(workspace.clipboardHistory(for: episode.id).last?.sourceApplication, "Safari")
    }

    func testPauseStopsRecordingAndResumeContinuesInTheSameFile() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        clipboard.copy("做事时复制的")
        workspace.sampleClipboardNow()

        // 放下：期间复制的不记。
        XCTAssertTrue(workspace.pauseEpisode(episode.id))
        clipboard.copy("放下期间复制的")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["做事时复制的"])

        // 接着做：手上拿着的那条算这段事的（重新拿起时的现场），之后的照常记。
        XCTAssertTrue(workspace.resumeEpisode(episode.id))
        XCTAssertEqual(texts(workspace, episode.id), ["做事时复制的", "放下期间复制的"])
        clipboard.copy("回来后复制的")
        workspace.sampleClipboardNow()
        XCTAssertEqual(
            texts(workspace, episode.id),
            ["做事时复制的", "放下期间复制的", "回来后复制的"]
        )
    }

    func testWaitingPausesAndReturningResumes() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "等 CI"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        let waiting = try XCTUnwrap(workspace.beginWaiting(episodeID: episode.id, description: "等 CI 跑完"))

        clipboard.copy("等待期间复制的")
        workspace.sampleClipboardNow()
        XCTAssertTrue(texts(workspace, episode.id).isEmpty)

        XCTAssertTrue(workspace.completeWaiting(waiting.id, evidence: "CI 绿了"))
        XCTAssertTrue(workspace.resumeWaitingEpisode(waiting.id))
        clipboard.copy("回来后复制的")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["等待期间复制的", "回来后复制的"])
    }

    func testSwitchingTargetsMovesTheHistoryToTheNewEpisode() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let first = try XCTUnwrap(workspace.createTarget(name: "第一件"))
        let second = try XCTUnwrap(workspace.createTarget(name: "第二件"))
        let firstEpisode = try XCTUnwrap(workspace.startEpisode(targetID: first.id))
        clipboard.copy("给第一件的")
        workspace.sampleClipboardNow()

        let secondEpisode = try XCTUnwrap(workspace.startEpisode(targetID: second.id))
        clipboard.copy("给第二件的")
        workspace.sampleClipboardNow()

        XCTAssertEqual(texts(workspace, firstEpisode.id), ["给第一件的"])
        // 换过去那一拍手上还是第一件的内容，跟着第二件开头记一条，之后各归各。
        XCTAssertEqual(texts(workspace, secondEpisode.id), ["给第一件的", "给第二件的"])

        // 回到第一件：接着它自己的文件写。
        XCTAssertNotNil(workspace.startEpisode(targetID: first.id))
        clipboard.copy("又回到第一件")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, firstEpisode.id), ["给第一件的", "给第二件的", "又回到第一件"])
        XCTAssertEqual(texts(workspace, secondEpisode.id), ["给第一件的", "给第二件的"])
    }

    func testEndingStopsRecordingButKeepsTheHistory() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        clipboard.copy("做事时复制的")
        workspace.sampleClipboardNow()

        XCTAssertTrue(workspace.endEpisode(episode.id))
        clipboard.copy("结束后复制的")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["做事时复制的"])
    }

    // MARK: - 去重、空内容、上限、开关

    func testUnchangedAndConcealedClipboardAreNotRecorded() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        clipboard.copy("同一段")
        workspace.sampleClipboardNow()
        workspace.sampleClipboardNow()
        clipboard.copy("同一段")
        workspace.sampleClipboardNow()
        clipboard.copyConcealed()
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["同一段"])

        // 机密之后再复制普通文字照常记；同样的文字隔了别的内容再出现也算一次。
        clipboard.copy("别的")
        workspace.sampleClipboardNow()
        clipboard.copy("同一段")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["同一段", "别的", "同一段"])
    }

    func testHistoryKeepsOnlyTheMostRecentEntries() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        for index in 0..<(ClipboardHistoryEntry.entryLimit + 5) {
            clipboard.copy("第 \(index) 段")
            workspace.sampleClipboardNow()
        }
        let history = texts(workspace, episode.id)
        XCTAssertEqual(history.count, ClipboardHistoryEntry.entryLimit)
        XCTAssertEqual(history.first, "第 5 段")
        XCTAssertEqual(history.last, "第 \(ClipboardHistoryEntry.entryLimit + 4) 段")
    }

    func testNothingIsRecordedWhileTheSwitchIsOff() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard, saveClipboardContent: false)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        clipboard.copy("开关关着时复制的")
        workspace.sampleClipboardNow()
        XCTAssertTrue(texts(workspace, episode.id).isEmpty)

        // 开关一开，下一次复制就开始记，不用换一件事。
        var preferences = workspace.intelligencePreferences
        preferences.saveClipboardContent = true
        workspace.updateIntelligencePreferences(preferences)
        clipboard.copy("开关开了之后复制的")
        workspace.sampleClipboardNow()
        XCTAssertEqual(texts(workspace, episode.id), ["开关开了之后复制的"])
    }

    func testAutomaticCapturePauseAlsoPausesTheHistory() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))

        var paused = workspace.sceneCapturePreferences
        paused.isAutomaticCapturePaused = true
        workspace.updateSceneCapturePreferences(paused)
        clipboard.copy("暂停自动记录时复制的")
        workspace.sampleClipboardNow()
        XCTAssertTrue(texts(workspace, episode.id).isEmpty)
    }

    // MARK: - 复写条

    private func date(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: hour, minute: minute))!
    }

    func testStripsSplitAtPausesAndReportHowLongEachPauseWas() {
        let entries = [
            ClipboardHistoryEntry(at: date(13, 12), text: "a"),
            ClipboardHistoryEntry(at: date(13, 30), text: "b"),
            ClipboardHistoryEntry(at: date(14, 18), text: "c"),
            ClipboardHistoryEntry(at: date(14, 32), text: "d")
        ]
        let intervals = [
            DateInterval(start: date(13, 10), end: date(13, 36)),
            DateInterval(start: date(14, 18), end: date(14, 32))
        ]
        let strips = ClipboardStrip.build(entries: entries, focusIntervals: intervals)

        XCTAssertEqual(strips.map { $0.entries.map(\.text) }, [["d", "c"], ["b", "a"]])
        XCTAssertNil(strips[0].pauseAfter)
        XCTAssertEqual(strips[1].pauseAfter, 42 * 60)
    }

    func testEntriesOutsideAnyIntervalJoinTheNearestEarlierStrip() {
        // 放下那一刻手上的那条是稍后异步写入的，落在专注区间之后。
        let entries = [
            ClipboardHistoryEntry(at: date(13, 12), text: "a"),
            ClipboardHistoryEntry(at: date(14, 33), text: "late")
        ]
        let intervals = [DateInterval(start: date(13, 10), end: date(14, 32))]
        let strips = ClipboardStrip.build(entries: entries, focusIntervals: intervals)
        XCTAssertEqual(strips.map { $0.entries.map(\.text) }, [["late", "a"]])
    }

    func testWithoutIntervalsEverythingIsOneStrip() {
        let entries = [
            ClipboardHistoryEntry(at: date(13, 12), text: "a"),
            ClipboardHistoryEntry(at: date(15, 0), text: "b")
        ]
        let strips = ClipboardStrip.build(entries: entries, focusIntervals: [])
        XCTAssertEqual(strips.count, 1)
        XCTAssertEqual(strips[0].entries.map(\.text), ["b", "a"])
        XCTAssertTrue(ClipboardStrip.build(entries: [], focusIntervals: []).isEmpty)
    }

    func testWorkspaceStripsFollowTheEpisodeAndAddTheSetAsideClipboard() throws {
        let clipboard = FakeClipboard()
        let workspace = makeWorkspace(clipboard: clipboard)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let t0 = date(13, 12)
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id, now: t0))
        clipboard.copy("第一段")
        workspace.sampleClipboardNow(at: date(13, 20))
        XCTAssertTrue(workspace.pauseEpisode(episode.id, now: date(13, 36)))
        XCTAssertTrue(workspace.resumeEpisode(episode.id, now: date(14, 18)))
        clipboard.copy("第二段")
        workspace.sampleClipboardNow(at: date(14, 25))
        XCTAssertTrue(workspace.pauseEpisode(episode.id, now: date(14, 32)))

        // 放下那一刻现场读到的剪贴板不在历史里：补成最新一条。
        let sceneSnapshot = SceneSnapshot(
            targetID: target.id,
            episodeID: episode.id,
            clipboardText: "放下时手上的",
            capturedAt: date(14, 32)
        )
        XCTAssertTrue(workspace.hasClipboardContent(sceneSnapshot))
        let strips = workspace.clipboardStrips(for: sceneSnapshot, now: date(15, 0))
        XCTAssertEqual(strips.map { $0.entries.map(\.text) }, [["放下时手上的", "第二段"], ["第一段"]])
        XCTAssertEqual(strips[1].pauseAfter, 42 * 60)

        // 现场里的那条已经是历史最新一条时不重复。
        let same = SceneSnapshot(episodeID: episode.id, clipboardText: "第二段", capturedAt: date(14, 32))
        XCTAssertEqual(workspace.clipboardStrips(for: same, now: date(15, 0))[0].entries.map(\.text), ["第二段"])

        // 没有 episode、也没有当时剪贴板：整块不出现。
        XCTAssertFalse(workspace.hasClipboardContent(SceneSnapshot()))
    }

    // MARK: - 持久化与删除

    func testHistorySurvivesRelaunchAndContinuesFollowingTheActiveEpisode() throws {
        let clipboard = FakeClipboard()
        let storeURL = temporaryEventsDirectoryURL()
        let historyDirectory = temporaryDirectoryURL()
        let workspace = makeWorkspace(clipboard: clipboard, storeURL: storeURL, historyDirectory: historyDirectory)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        clipboard.copy("重启前复制的")
        workspace.sampleClipboardNow()
        workspace.stopBackgroundMaintenance()

        let relaunched = makeWorkspace(clipboard: clipboard, storeURL: storeURL, historyDirectory: historyDirectory)
        XCTAssertEqual(texts(relaunched, episode.id), ["重启前复制的"])
        relaunched.runBackgroundMaintenance()
        clipboard.copy("重启后复制的")
        relaunched.sampleClipboardNow()
        XCTAssertEqual(texts(relaunched, episode.id), ["重启前复制的", "重启后复制的"])
    }

    func testDeleteAllDataRemovesTheHistoryDirectory() throws {
        let clipboard = FakeClipboard()
        let root = temporaryDirectoryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyDirectory = root.appendingPathComponent(
            LightAnchorStorage.clipboardHistoryURL().lastPathComponent,
            isDirectory: true
        )
        let workspace = AttentionWorkspace(
            store: LocalEventStore(directoryURL: root.appendingPathComponent("events", isDirectory: true)),
            assetStore: LocalAssetStore(directoryURL: root.appendingPathComponent("assets", isDirectory: true)),
            sceneCapturePreferences: SceneCapturePreferences(),
            recordingTraceStore: RecordingTraceStore(directoryURL: root.appendingPathComponent("recordings", isDirectory: true)),
            clipboardHistoryStore: ClipboardHistoryStore(directoryURL: historyDirectory),
            clipboardSample: { clipboard.sample() },
            contextCapture: { _, _ in ContextCapsule() }
        )
        var preferences = IntelligencePreferences.default
        preferences.saveClipboardContent = true
        workspace.updateIntelligencePreferences(preferences)
        let target = try XCTUnwrap(workspace.createTarget(name: "修签名校验"))
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: target.id))
        clipboard.copy("要被删掉的")
        workspace.sampleClipboardNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyDirectory.path))

        let suiteName = "light-anchor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(workspace.deleteAllData(defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyDirectory.path))
        XCTAssertTrue(texts(workspace, episode.id).isEmpty)
    }
}
