import Combine
import Foundation

import AppKit

@MainActor
final class CaptureDraftCoordinator: ObservableObject {
    static let shared = CaptureDraftCoordinator()

    private(set) var activeDraftID: UUID?
    private(set) var hasUnsavedContent = false

    private init() {}

    func begin() -> UUID {
        let id = UUID()
        activeDraftID = id
        hasUnsavedContent = false
        return id
    }

    func update(draftID: UUID, hasUnsavedContent: Bool) {
        guard activeDraftID == draftID else { return }
        self.hasUnsavedContent = hasUnsavedContent
    }

    func end(draftID: UUID) {
        guard activeDraftID == draftID else { return }
        activeDraftID = nil
        hasUnsavedContent = false
    }
}

@MainActor
final class AppTerminationController: ObservableObject {
    static let shared = AppTerminationController()

    private weak var runtime: WorkspaceRuntime?
    private var isTerminating = false
    private var terminationPromptPending = false

    private init() {}

    func attach(runtime: WorkspaceRuntime) {
        self.runtime = runtime
    }

    func requestQuit() {
        guard !isTerminating, !terminationPromptPending else { return }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(
        _ application: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }

        if CaptureDraftCoordinator.shared.hasUnsavedContent {
            guard !terminationPromptPending else { return .terminateLater }
            terminationPromptPending = true
            NotificationCenter.default.post(
                name: .requestCaptureDraftTerminationDecision,
                object: nil
            )
            return .terminateLater
        }

        allowTermination()
        return .terminateNow
    }

    /// 用户在「未保存内容」提示里选了取消（或保存失败）：撤回这次退出。
    func cancelCaptureDraftTermination() {
        guard terminationPromptPending else { return }
        terminationPromptPending = false
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    func captureDraftDidSaveOrDiscard() {
        guard terminationPromptPending else { return }
        allowTermination()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func allowTermination() {
        isTerminating = true
        terminationPromptPending = false
        runtime?.stop()
    }
}
