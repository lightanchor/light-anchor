import Foundation
import XCTest
@testable import LightAnchor

/// 步骤（大任务拆小步骤）：子目标的归属、进度、完成时的连带收起，
/// 以及独立目标的可选归属与收起状态。
@MainActor
final class StepTargetsTests: XCTestCase {
    func testAddStepCreatesChildAndRefusesNesting() throws {
        let workspace = makeWorkspace()
        let parent = try XCTUnwrap(workspace.createTarget(name: "发布 2.0"))

        let step = try XCTUnwrap(workspace.addStep(named: "写更新日志", to: parent.id))
        XCTAssertEqual(step.parentTargetID, parent.id)
        XCTAssertEqual(workspace.snapshot.steps(of: parent.id).map(\.id), [step.id])

        // 只有一层：步骤不能再拆步骤。
        XCTAssertNil(workspace.addStep(named: "再拆一层", to: step.id))
        // 空名字不收。
        XCTAssertNil(workspace.addStep(named: "   ", to: parent.id))
    }

    func testStepProgressCountsCompletedSteps() throws {
        let workspace = makeWorkspace()
        let parent = try XCTUnwrap(workspace.createTarget(name: "季度复盘"))
        let stepA = try XCTUnwrap(workspace.addStep(named: "整理数据", to: parent.id))
        let stepB = try XCTUnwrap(workspace.addStep(named: "写结论", to: parent.id))

        XCTAssertEqual(workspace.snapshot.stepProgress(of: parent.id)?.done, 0)
        XCTAssertEqual(workspace.snapshot.stepProgress(of: parent.id)?.total, 2)

        // 完成一步（独立计时也走同一条 episode 通道）。
        let episode = try XCTUnwrap(workspace.startEpisode(targetID: stepA.id))
        XCTAssertTrue(workspace.endEpisode(episode.id))

        let progress = try XCTUnwrap(workspace.snapshot.stepProgress(of: parent.id))
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(workspace.snapshot.unfinishedSteps(of: parent.id).map(\.id), [stepB.id])
        // 还没动过的那步在「步骤」组里等着被挑。
        XCTAssertEqual(workspace.snapshot.plannedSteps.map(\.id), [stepB.id])
    }

    func testFinishingParentCollapsesUnfinishedSteps() throws {
        let workspace = makeWorkspace()
        let parent = try XCTUnwrap(workspace.createTarget(name: "搬家"))
        let started = try XCTUnwrap(workspace.addStep(named: "打包书房", to: parent.id))
        let planned = try XCTUnwrap(workspace.addStep(named: "换地址", to: parent.id))

        // 动过又放下的一步。
        let stepEpisode = try XCTUnwrap(workspace.startEpisode(targetID: started.id))
        XCTAssertTrue(workspace.pauseEpisode(stepEpisode.id))

        // 回到大任务上，完成它并连带收起。
        let parentEpisode = try XCTUnwrap(workspace.startEpisode(targetID: parent.id))
        XCTAssertTrue(workspace.endEpisodeCollapsingSteps(parentEpisode.id))

        // 大任务按完成收束。
        XCTAssertTrue(workspace.snapshot.isTargetCompleted(parent.id))
        // 动过的步骤：开着的段按放弃收束。
        let collapsed = try XCTUnwrap(workspace.snapshot.latestEpisode(of: started.id))
        XCTAssertEqual(collapsed.state, .ended)
        XCTAssertEqual(collapsed.endedReason, .abandoned)
        // 两步都盖上墓碑，从此不进清单。
        XCTAssertNotNil(workspace.snapshot.targets[started.id]?.retiredAt)
        XCTAssertNotNil(workspace.snapshot.targets[planned.id]?.retiredAt)
        XCTAssertTrue(workspace.snapshot.unfinishedSteps(of: parent.id).isEmpty)
        XCTAssertTrue(workspace.snapshot.plannedSteps.isEmpty)
        // 放下的清单里也不再有它们。
        XCTAssertTrue(workspace.snapshot.setAsideEpisodes.isEmpty)
        XCTAssertFalse(workspace.recentTargetNames.contains(started.name))
        XCTAssertFalse(workspace.recentTargetNames.contains(planned.name))
    }

    func testStepFieldsSurviveReloadAndUpdateTargetKeepsThem() throws {
        let store = LocalEventStore(directoryURL: temporaryEventsDirectoryURL())
        let workspace = AttentionWorkspace(store: store)
        let parent = try XCTUnwrap(workspace.createTarget(name: "写论文"))
        let step = try XCTUnwrap(workspace.addStep(named: "查文献", to: parent.id))

        // 改名不抹掉步骤归属（updateTarget 改字段而不是重建）。
        XCTAssertTrue(workspace.updateTarget(step.id, name: "查最新文献", note: "", environmentProfileID: nil))
        XCTAssertEqual(workspace.snapshot.targets[step.id]?.parentTargetID, parent.id)

        // 重放事件日志（重启）后归属还在。
        let reloaded = AttentionWorkspace(store: store)
        XCTAssertEqual(reloaded.snapshot.targets[step.id]?.parentTargetID, parent.id)
        XCTAssertEqual(reloaded.snapshot.steps(of: parent.id).map(\.id), [step.id])
    }

    func testStandaloneTargetRoundTripsWithoutParentOrRetirement() throws {
        let original = AttentionTarget(name: "独立任务")
        let data = try JSONEncoder().encode(original)
        let target = try JSONDecoder().decode(AttentionTarget.self, from: data)
        XCTAssertEqual(target, original)
        XCTAssertNil(target.parentTargetID)
        XCTAssertNil(target.retiredAt)
    }

    private func makeWorkspace() -> AttentionWorkspace {
        AttentionWorkspace(store: LocalEventStore(directoryURL: temporaryEventsDirectoryURL()))
    }

    private func temporaryEventsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StepTargetsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }
}
