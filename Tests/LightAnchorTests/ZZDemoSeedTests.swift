import XCTest
@testable import LightAnchor

/// 一次性演示数据播种（仅当 LIGHTANCHOR_SEED_DEMO=1 时运行；截图用，随后删除本文件）。
@MainActor
final class ZZDemoSeedTests: XCTestCase {
    func testSeedDemoData() throws {
        guard ProcessInfo.processInfo.environment["LIGHTANCHOR_SEED_DEMO"] == "1" else {
            throw XCTSkip("demo seeding disabled")
        }
        let workspace = AttentionWorkspace()

        _ = workspace.captureText("给设计稿补充深色模式的边界情况")
        _ = workspace.captureLink(URL(string: "https://example.com/spec")!, title: "排版规范参考页")
        _ = workspace.captureText("录音转写：下一版先解决恢复现场的可靠性")

        let target = try XCTUnwrap(workspace.createTarget(
            name: "整理访谈材料",
            note: "先把三段录音的要点摘出来，再对照上周的提纲。"
        ))
        let episode = try XCTUnwrap(workspace.startEpisode(
            targetID: target.id,
            now: Date().addingTimeInterval(-42 * 60)
        ))

        let ready = try XCTUnwrap(workspace.beginWaiting(
            episodeID: episode.id,
            description: "客户已确认最终版本",
            completionCondition: "查看邮件回复"
        ))
        _ = workspace.completeWaiting(ready.id, evidence: "定时提醒已触发")
        _ = workspace.resumeEpisode(episode.id)

        _ = workspace.beginWaiting(
            episodeID: episode.id,
            description: "等构建流水线跑完集成测试",
            completionCondition: "看失败用例列表"
        )
        _ = workspace.resumeEpisode(episode.id)

        // 给 episode 一个丰富的 context 胶囊：应用内切换/放下时,
        // boundaryContext 在实时采集为空的环境（无辅助功能权限）会回退到它,
        // 「已放下」确认卡的端到端演示才有素材。
        _ = workspace.updateContext(for: episode.id, context: ContextCapsule(
            applications: ["Safari"],
            applicationBundleIdentifiers: ["com.apple.Safari"],
            files: [URL(fileURLWithPath: NSHomeDirectory() + "/Developer/light-anchor/README.md")],
            links: [URL(string: "https://example.com/spec")!],
            terminalWorkingDirectories: [URL(fileURLWithPath: NSHomeDirectory() + "/Developer/light-anchor")],
            terminalCommands: ["swift test"],
            clipboardText: "lightanchor/light-anchor"
        ))

        // 现场卡演示条目：覆盖四类条目（应用图标解析各走一条路径）。
        // 生产里现场只由实时采集产出；演示夹具直接追加进事件日志。
        let store = LocalEventStore()
        let scene = SceneSnapshot(
            targetID: target.id,
            episodeID: episode.id,
            items: [
                SceneItem(
                    kind: .application,
                    title: "Safari",
                    address: "com.apple.Safari",
                    sourceApplication: "Safari"
                ),
                SceneItem(
                    kind: .terminal,
                    title: "light-anchor",
                    address: "file://" + NSHomeDirectory() + "/Developer/light-anchor",
                    sourceApplication: "终端",
                    detail: "swift test"
                ),
                SceneItem(
                    kind: .file,
                    title: "README.md",
                    address: NSHomeDirectory() + "/Developer/light-anchor/README.md",
                    sourceApplication: "Visual Studio Code"
                ),
                SceneItem(
                    kind: .link,
                    title: "排版规范参考页",
                    address: "https://example.com/spec",
                    sourceApplication: "Safari"
                )
            ],
            filterMode: .saveAll,
            clipboardText: "lightanchor/light-anchor"
        )
        try store.save(events: try store.load() + [.sceneSnapshotChanged(scene, at: scene.capturedAt)])
    }
}
