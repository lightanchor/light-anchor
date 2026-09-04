import AppKit
import XCTest
@testable import LightAnchor

/// 一次性演示数据播种（仅当 LIGHTANCHOR_SEED_DEMO=1 时运行；截图/验收用）。
///
/// 播出的数据刚好铺满「换一件事」的四组候选、一份可看的现场、以及跨两段的复写条：
/// - 现在：整理访谈材料（active，带现场 + 剪贴板历史）
/// - 结果到了：回复 Lena 的合同问题
/// - 放下的：季度复盘 PPT（带 5 条现场 + 跨两段的剪贴板历史）、读 Dev Mode 新文档
/// - 等待中：发布 1.4
/// - 稍后：两条随手记
@MainActor
final class ZZDemoSeedTests: XCTestCase {
    func testSeedDemoData() throws {
        guard ProcessInfo.processInfo.environment["LIGHTANCHOR_SEED_DEMO"] == "1" else {
            throw XCTSkip("demo seeding disabled")
        }
        let workspace = AttentionWorkspace()
        let store = LocalEventStore()
        let clipboardStore = ClipboardHistoryStore()
        let now = Date()
        let home = NSHomeDirectory()
        // 现场快照统一在最后写：workspace 的每次操作都会把它自己的事件数组全量落盘，
        // 中途插入的 .sceneSnapshotChanged 会被下一次操作覆盖掉。
        var scenes: [SceneSnapshot] = []

        // ---- 放下的：季度复盘 PPT（要去的那件；现场 5 条 + 复写条跨两段）----
        let review = try XCTUnwrap(workspace.createTarget(name: "季度复盘 PPT"))
        let reviewEpisode = try XCTUnwrap(workspace.startEpisode(
            targetID: review.id, now: now.addingTimeInterval(-190 * 60)
        ))
        _ = workspace.updateContext(for: reviewEpisode.id, context: ContextCapsule(
            applications: ["Keynote"],
            applicationBundleIdentifiers: ["com.apple.iWork.Keynote"],
            files: [URL(fileURLWithPath: home + "/Developer/light-anchor/README.md")],
            links: [URL(string: "https://example.com/finance-alignment")!],
            terminalWorkingDirectories: [URL(fileURLWithPath: home + "/Developer/light-anchor")],
            terminalCommands: ["swift build"],
            clipboardText: "Q3 毛利率 41.2%（待财务确认）"
        ))
        // 两段专注区间：做一阵 → 放下 → 接着做 → 再放下。复写条才会撕成两张纸，
        // 撕口写着中间放下了多久。
        _ = workspace.setAsideCurrent(.pause, returnCue: "先去开会", now: now.addingTimeInterval(-167 * 60))
        _ = workspace.resumeEpisode(reviewEpisode.id, now: now.addingTimeInterval(-135 * 60))
        _ = workspace.setAsideCurrent(
            .pause,
            returnCue: "第 7 页的数据还没对，等财务的表",
            now: now.addingTimeInterval(-125 * 60)
        )

        let reviewScene = SceneSnapshot(
            targetID: review.id,
            episodeID: reviewEpisode.id,
            items: [
                SceneItem(kind: .application, title: "Keynote", address: "com.apple.iWork.Keynote", sourceApplication: "Keynote"),
                SceneItem(kind: .file, title: "README.md", address: home + "/Developer/light-anchor/README.md", sourceApplication: "Visual Studio Code"),
                SceneItem(kind: .link, title: "飞书 – 财务口径确认", address: "https://example.com/finance-alignment", sourceApplication: "Safari"),
                SceneItem(kind: .link, title: "知乎 – 复盘模板怎么写", address: "https://example.com/how-to", sourceApplication: "Safari", isRelevant: false),
                SceneItem(kind: .terminal, title: "light-anchor", address: "file://" + home + "/Developer/light-anchor", sourceApplication: "终端", detail: "swift build")
            ],
            filterMode: .saveAll,
            returnCue: "第 7 页的数据还没对，等财务的表",
            clipboardText: "Q3 毛利率 41.2%（待财务确认）",
            // 桌面截图：走和平时一样的附件目录，让现场页的照片区能被看到。
            screenshotAssetURL: try? LocalAssetStore().save(data: Self.desktopShotPNG(), fileExtension: "png"),
            capturedAt: now.addingTimeInterval(-125 * 60)
        )
        scenes.append(reviewScene)
        // 复写条：最近一段三条 + 放下 42 分钟 + 更早一段两条。
        try clipboardStore.save([
            ClipboardHistoryEntry(at: now.addingTimeInterval(-188 * 60), text: "Q3 复盘模板 v2.key", sourceApplication: "Keynote"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-186 * 60), text: "同比 +18.4%，环比 +3.1%", sourceApplication: "Numbers"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-133 * 60), text: "财务口径：毛利率含补贴", sourceApplication: "飞书"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-129 * 60), text: "=SUMPRODUCT(B2:B15,C2:C15)/SUM(C2:C15)", sourceApplication: "Numbers"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-126 * 60), text: "Q3 毛利率 41.2%（待财务确认）", sourceApplication: "Numbers")
        ], for: reviewEpisode.id)

        // ---- 放下的：读 Dev Mode 新文档 ----
        let devMode = try XCTUnwrap(workspace.createTarget(name: "读 Dev Mode 新文档"))
        let devEpisode = try XCTUnwrap(workspace.startEpisode(
            targetID: devMode.id, now: now.addingTimeInterval(-3 * 24 * 60 * 60)
        ))
        _ = workspace.setAsideCurrent(.pause, returnCue: "")
        let devScene = SceneSnapshot(
            targetID: devMode.id,
            episodeID: devEpisode.id,
            items: [SceneItem(kind: .link, title: "Figma – Dev Mode 文档", address: "https://example.com/dev-mode", sourceApplication: "Safari")],
            filterMode: .saveAll,
            capturedAt: now.addingTimeInterval(-3 * 24 * 60 * 60)
        )
        scenes.append(devScene)

        // ---- 等待中：发布 1.4 ----
        let release = try XCTUnwrap(workspace.createTarget(name: "发布 1.4"))
        let releaseEpisode = try XCTUnwrap(workspace.startEpisode(
            targetID: release.id, now: now.addingTimeInterval(-70 * 60)
        ))
        _ = workspace.beginWaiting(
            episodeID: releaseEpisode.id,
            description: "等 CI 跑完 build 412",
            completionCondition: "看 Actions 的结论",
            now: now.addingTimeInterval(-40 * 60)
        )

        // ---- 结果到了：回复 Lena 的合同问题 ----
        let contract = try XCTUnwrap(workspace.createTarget(name: "回复 Lena 的合同问题"))
        let contractEpisode = try XCTUnwrap(workspace.startEpisode(
            targetID: contract.id, now: now.addingTimeInterval(-24 * 60 * 60)
        ))
        let ready = try XCTUnwrap(workspace.beginWaiting(
            episodeID: contractEpisode.id,
            description: "等的邮件回了",
            completionCondition: "看 Lena 的回复",
            now: now.addingTimeInterval(-23 * 60 * 60)
        ))
        // 结果是 12 分钟前到的——左栏那行的绿色小字说的就是这个。
        _ = workspace.completeWaiting(ready.id, evidence: "邮件已到", now: now.addingTimeInterval(-12 * 60))
        let contractScene = SceneSnapshot(
            targetID: contract.id,
            episodeID: contractEpisode.id,
            items: [
                SceneItem(kind: .file, title: "README.md", address: home + "/Developer/light-anchor/README.md", sourceApplication: "预览"),
                SceneItem(kind: .application, title: "Mail", address: "com.apple.mail", sourceApplication: "Mail")
            ],
            filterMode: .saveAll,
            returnCue: "第 3 条付款条款的措辞",
            clipboardText: "付款条款按 v4 第 3 条走",
            capturedAt: now.addingTimeInterval(-23 * 60 * 60)
        )
        scenes.append(contractScene)

        // ---- 稍后：随手记。前两条是稿子上那两条，后面几条把清单撑过折叠线
        // （左栏默认列 9 条，多的折成「还有 N 件 · 打字找」）----
        _ = workspace.captureText("问问财务报销截止")
        _ = workspace.captureLink(URL(string: "https://example.com/spec")!, title: "试一下录音转文字")
        for text in [
            "把周报模板换成新的口径",
            "查一下 Sentry 上那条崩溃",
            "给设计回一句关于间距的问题",
            "订下周三的会议室",
            "把旧的构建产物清一遍",
            "读完那篇讲增量编译的文章",
            "把访谈的转写导出成 md"
        ] {
            _ = workspace.captureText(text)
        }

        // ---- 现在：整理访谈材料（手上这件；现场 + 复写条 + 步骤）----
        let interview = try XCTUnwrap(workspace.createTarget(
            name: "整理访谈材料",
            note: "先把三段录音的要点摘出来，再对照上周的提纲。"
        ))
        // 步骤：一步已完成（有自己的段和计时）、一步还没动（换一件事的「步骤」组）。
        let stepDone = try XCTUnwrap(workspace.addStep(named: "摘录音 01 的要点", to: interview.id))
        let stepDoneEpisode = try XCTUnwrap(workspace.startEpisode(
            targetID: stepDone.id, now: now.addingTimeInterval(-96 * 60)
        ))
        _ = workspace.endEpisode(stepDoneEpisode.id, now: now.addingTimeInterval(-70 * 60))
        _ = try XCTUnwrap(workspace.addStep(named: "对照上周提纲补缺口", to: interview.id))
        let episode = try XCTUnwrap(workspace.startEpisode(
            targetID: interview.id, now: now.addingTimeInterval(-43 * 60)
        ))
        _ = workspace.updateContext(for: episode.id, context: ContextCapsule(
            applications: ["Safari", "Figma"],
            applicationBundleIdentifiers: ["com.apple.Safari", "com.figma.Desktop"],
            files: [
                URL(fileURLWithPath: home + "/Developer/light-anchor/README.md"),
                URL(fileURLWithPath: home + "/Developer/light-anchor/Package.swift")
            ],
            links: [URL(string: "https://example.com/interview-notes")!],
            terminalWorkingDirectories: [URL(fileURLWithPath: home + "/Developer/light-anchor")],
            terminalCommands: ["swift test"],
            clipboardText: "预算部分再核一遍"
        ))
        try clipboardStore.save([
            ClipboardHistoryEntry(at: now.addingTimeInterval(-41 * 60), text: "访谈提纲 v3 第 4 题要改", sourceApplication: "Pages"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-28 * 60), text: "王工：「这块我们内部还在讨论」", sourceApplication: "Obsidian"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-14 * 60), text: "访谈录音 03 已转写完毕", sourceApplication: "Safari"),
            ClipboardHistoryEntry(at: now.addingTimeInterval(-2 * 60), text: "预算部分再核一遍", sourceApplication: "备忘录")
        ], for: episode.id)

        // ---- 现场快照落盘（必须在所有 workspace 操作之后）----
        try store.save(events: try store.load() + scenes.map { .sceneSnapshotChanged($0, at: $0.capturedAt) })
    }

    /// 一张假桌面：深色底加两块亮窗，缩到 168×96 就是设计里那张缩略图的样子。
    private static func desktopShotPNG() -> Data {
        let size = NSSize(width: 1600, height: 1000)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.31, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 90, y: 150, width: 940, height: 700), xRadius: 22, yRadius: 22).fill()
        NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: 660, y: 70, width: 830, height: 560), xRadius: 22, yRadius: 22).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
