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
            kind: .reply,
            description: "客户已确认最终版本",
            completionCondition: "查看邮件回复"
        ))
        _ = workspace.completeWaiting(ready.id, evidence: "定时提醒已触发")
        _ = workspace.resumeEpisode(episode.id)

        _ = workspace.beginWaiting(
            episodeID: episode.id,
            kind: .build,
            description: "等构建流水线跑完集成测试",
            completionCondition: "看失败用例列表"
        )
        _ = workspace.resumeEpisode(episode.id)
    }
}
