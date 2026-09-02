import Foundation

import AppKit

enum EnvironmentActionStatus: String, Equatable {
    case succeeded
    case skipped
    case failed
    case cancelled
}

struct EnvironmentActionResult: Equatable {
    let actionID: UUID
    let status: EnvironmentActionStatus
    let message: String
}

enum EnvironmentUndoOperation: Equatable {
    case unhideApplications([String])
    case hideApplications([String])
}

struct EnvironmentUndoStep: Equatable {
    let actionID: UUID
    let operation: EnvironmentUndoOperation
}

struct EnvironmentExecution: Equatable {
    let results: [EnvironmentActionResult]
    let undoSteps: [EnvironmentUndoStep]
    /// 本次执行才启动（执行前没有在运行）的应用，收场时可选择退出。
    let launchedApplicationBundleIdentifiers: [String]

    init(
        results: [EnvironmentActionResult],
        undoSteps: [EnvironmentUndoStep],
        launchedApplicationBundleIdentifiers: [String] = []
    ) {
        self.results = results
        self.undoSteps = undoSteps
        self.launchedApplicationBundleIdentifiers = launchedApplicationBundleIdentifiers
    }

    /// 收场是否有事可做：有可还原的显示状态，或有本次新打开的应用。
    var isCloseOutMeaningful: Bool {
        !undoSteps.isEmpty || !launchedApplicationBundleIdentifiers.isEmpty
    }
}

// MARK: - 预览（干跑）

enum EnvironmentActionPreviewStatus: Equatable {
    /// 届时会真实执行。
    case ready
    /// 届时会跳过（动作关闭 / 不在允许列表 / 目标应用未在运行）。
    case willSkip(String)
    /// 届时会失败（值缺失、文件不存在、应用未安装等）。
    case blocked(String)
}

struct EnvironmentActionPreview: Identifiable, Equatable {
    let id: UUID
    /// 一句话说明届时会做什么，如「打开应用 Xcode」。
    let summary: String
    /// 补充信息（路径、命令原文等），可为空。
    let detail: String
    let status: EnvironmentActionPreviewStatus
}

final class EnvironmentActionRunner {
    func execute(_ profile: EnvironmentProfile) async -> [EnvironmentActionResult] {
        await executeSession(profile).results
    }

    func executeSession(_ profile: EnvironmentProfile) async -> EnvironmentExecution {
        var results: [EnvironmentActionResult] = []
        var undoSteps: [EnvironmentUndoStep] = []
        var launchedApplications: [String] = []
        for action in profile.actions {
            if Task.isCancelled {
                results.append(EnvironmentActionResult(
                    actionID: action.id,
                    status: .cancelled,
                    message: tr("the_remaining_actions_were_cancelled")
                ))
                continue
            }
            let before = applicationState(for: action)
            let result = await execute(action, in: profile)
            results.append(result)
            if result.status == .succeeded,
               let undoStep = makeUndoStep(for: action, before: before) {
                undoSteps.append(undoStep)
            }
            if result.status == .succeeded,
               action.kind == .openApplication,
               let before, !before.wasRunning,
               !launchedApplications.contains(before.bundleIdentifier) {
                launchedApplications.append(before.bundleIdentifier)
            }
        }
        return EnvironmentExecution(
            results: results,
            undoSteps: undoSteps,
            launchedApplicationBundleIdentifiers: launchedApplications
        )
    }

    /// 干跑：逐条说明届时会发生什么，并做可行性检查。不执行任何动作。
    func preview(_ profile: EnvironmentProfile) -> [EnvironmentActionPreview] {
        profile.actions.map { action in
            preview(action, in: profile)
        }
    }

    private func preview(
        _ action: EnvironmentAction,
        in profile: EnvironmentProfile
    ) -> EnvironmentActionPreview {
        func make(
            _ summary: String,
            detail: String = "",
            status: EnvironmentActionPreviewStatus = .ready
        ) -> EnvironmentActionPreview {
            EnvironmentActionPreview(id: action.id, summary: summary, detail: detail, status: status)
        }

        guard action.isEnabled else {
            return make(action.kind.title, detail: action.value, status: .willSkip(tr("action_is_off")))
        }
        guard !action.value.isEmpty else {
            return make(action.kind.title, status: .blocked(tr("nothing_filled_in_yet")))
        }

        switch action.kind {
        case .openApplication, .hideApplication:
            let verb = action.kind == .openApplication ? tr("open_app") : tr("hide_app")
            guard let bundleIdentifier = applicationBundleIdentifier(for: action.value) else {
                return make(verb, detail: action.value, status: .blocked(tr("invalid_app_path_or_no_bundle_id")))
            }
            let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
            let name = applicationURL.map {
                FileManager.default.displayName(atPath: $0.path)
                    .replacingOccurrences(of: ".app", with: "")
            } ?? bundleIdentifier
            if !profile.allowedApplicationBundleIdentifiers.isEmpty,
               !profile.allowedApplicationBundleIdentifiers.contains(bundleIdentifier) {
                return make(String(format: tr("verb_quoted_name"), verb, name), detail: bundleIdentifier, status: .willSkip(tr("not_in_the_allow_list")))
            }
            guard applicationURL != nil else {
                return make(verb, detail: bundleIdentifier, status: .blocked(tr("the_app_isn_t_installed")))
            }
            let running = !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
            if action.kind == .hideApplication, !running {
                return make(String(format: tr("hide_app_named"), name), detail: bundleIdentifier, status: .willSkip(tr("it_isn_t_running_right_now")))
            }
            if action.kind == .openApplication, !running {
                return make(String(format: tr("open_app_named"), name), detail: tr("not_running_will_launch_can_quit_on_wind_down"))
            }
            return make(String(format: tr("verb_quoted_name"), verb, name), detail: bundleIdentifier)

        case .openURL:
            guard let url = URL(string: action.value), url.scheme != nil else {
                return make(tr("open_link"), detail: action.value, status: .blocked(tr("invalid_link")))
            }
            guard RestoreItemPolicy.allowsLink(url) else {
                return make(tr("open_link"), detail: url.absoluteString, status: .blocked(tr("only_http_links_can_be_opened")))
            }
            return make(tr("open_link"), detail: url.absoluteString)

        case .openFile:
            guard FileManager.default.fileExists(atPath: action.value) else {
                return make(tr("open_file"), detail: action.value, status: .blocked(tr("the_file_doesn_t_exist")))
            }
            guard RestoreItemPolicy.allowsFile(URL(fileURLWithPath: action.value)) else {
                return make(tr("open_file"), detail: action.value, status: .blocked(tr("file_isn_t_a_plain_document")))
            }
            return make(String(format: tr("open_file_named"), (action.value as NSString).lastPathComponent), detail: action.value)

        case .runShortcut:
            guard let shortcutName = Self.shortcutName(from: action.value) else {
                return make(tr("run_shortcut"), detail: action.value, status: .blocked(tr("shortcut_name_can_t_start_with_a_dash")))
            }
            return make(String(format: tr("run_shortcut_named"), shortcutName))

        case .runCommand:
            return make(tr("run_a_command_in_zsh"), detail: action.value)
        }
    }

    /// 收场：按相反顺序还原显示状态；可选把本次新打开的应用一并退出（温和 terminate）。
    func closeOut(
        _ execution: EnvironmentExecution,
        quitLaunchedApplications: Bool
    ) async -> [EnvironmentActionResult] {
        var results = await undo(execution)
        guard quitLaunchedApplications else { return results }
        for bundleIdentifier in execution.launchedApplicationBundleIdentifiers {
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            guard !applications.isEmpty else { continue }
            let requested = applications.allSatisfy { $0.terminate() }
            results.append(EnvironmentActionResult(
                actionID: UUID(),
                status: requested ? .succeeded : .failed,
                message: requested
                    ? tr("asked_the_apps_opened_this_run_to_quit")
                    : tr("couldn_t_ask_the_apps_to_quit")
            ))
        }
        return results
    }

    func undo(_ execution: EnvironmentExecution) async -> [EnvironmentActionResult] {
        var results: [EnvironmentActionResult] = []
        for step in execution.undoSteps.reversed() {
            if Task.isCancelled { break }
            results.append(await undo(step))
        }
        return results
    }

    private func execute(
        _ action: EnvironmentAction,
        in profile: EnvironmentProfile
    ) async -> EnvironmentActionResult {
        guard action.isEnabled else {
            return EnvironmentActionResult(
                actionID: action.id,
                status: .skipped,
                message: tr("the_action_is_off")
            )
        }

        if let authorizationFailure = authorizationFailure(for: action, in: profile) {
            return authorizationFailure
        }

        switch action.kind {
        case .openApplication:
            let opened: Bool
            if action.value.hasPrefix("/") {
                opened = NSWorkspace.shared.open(URL(fileURLWithPath: action.value))
            } else if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: action.value
            ) {
                opened = NSWorkspace.shared.open(url)
            } else {
                opened = false
            }
            return result(for: action, succeeded: opened, success: tr("opened_the_app"), failure: tr("couldn_t_open_the_app"))

        case .openURL:
            // 值来自持久化配置（可从备份恢复），只放 http/https：不让 file:// /
            // 自定义 scheme 借「打开链接」启动别的东西。
            guard let url = URL(string: action.value), RestoreItemPolicy.allowsLink(url) else {
                return EnvironmentActionResult(
                    actionID: action.id,
                    status: .failed,
                    message: tr("only_http_links_can_be_opened")
                )
            }
            let opened = NSWorkspace.shared.open(url)
            return result(for: action, succeeded: opened, success: tr("opened_the_link"), failure: tr("the_link_is_invalid_or_wouldn_t_open"))

        case .openFile:
            // 只打开普通文档；应用、脚本、安装包、可执行文件走「打开应用」或
            // 「运行命令」那种明确的动作，不该藏在「打开文件」里。
            let fileURL = URL(fileURLWithPath: action.value)
            guard RestoreItemPolicy.allowsFile(fileURL) else {
                return EnvironmentActionResult(
                    actionID: action.id,
                    status: .failed,
                    message: FileManager.default.fileExists(atPath: action.value)
                        ? tr("file_isn_t_a_plain_document")
                        : tr("couldn_t_open_the_file")
                )
            }
            let opened = NSWorkspace.shared.open(fileURL)
            return result(for: action, succeeded: opened, success: tr("opened_the_file"), failure: tr("couldn_t_open_the_file"))

        case .runShortcut:
            // 以 - 开头的名字会被 `shortcuts` 当成选项解析。
            guard let shortcutName = Self.shortcutName(from: action.value) else {
                return EnvironmentActionResult(
                    actionID: action.id,
                    status: .failed,
                    message: tr("shortcut_name_can_t_start_with_a_dash")
                )
            }
            return await runProcess(
                action,
                executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
                arguments: ["run", shortcutName]
            )

        case .runCommand:
            return await runProcess(
                action,
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", action.value]
            )

        case .hideApplication:
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: action.value
            )
            let hidden = applications.allSatisfy { $0.hide() }
            return result(for: action, succeeded: hidden, success: tr("hid_the_app"), failure: tr("couldn_t_hide_the_app"))
        }
    }

    private func authorizationFailure(
        for action: EnvironmentAction,
        in profile: EnvironmentProfile
    ) -> EnvironmentActionResult? {
        guard !profile.allowedApplicationBundleIdentifiers.isEmpty else { return nil }
        switch action.kind {
        case .openApplication, .hideApplication:
            guard let bundleIdentifier = applicationBundleIdentifier(for: action.value) else {
                return EnvironmentActionResult(
                    actionID: action.id,
                    status: .failed,
                    message: tr("the_app_action_has_no_valid_bundle_id")
                )
            }
            guard profile.allowedApplicationBundleIdentifiers.contains(bundleIdentifier) else {
                return EnvironmentActionResult(
                    actionID: action.id,
                    status: .skipped,
                    message: tr("the_app_isn_t_in_this_environment_s_allow_list")
                )
            }
        case .openURL, .openFile, .runShortcut, .runCommand:
            break
        }
        return nil
    }

    private func runProcess(
        _ action: EnvironmentAction,
        executableURL: URL,
        arguments: [String]
    ) async -> EnvironmentActionResult {
        do {
            let output = try await ProcessExecutionSupport.run(
                executableURL: executableURL,
                arguments: arguments
            )
            return EnvironmentActionResult(
                actionID: action.id,
                status: .succeeded,
                message: output.isEmpty ? tr("the_command_finished") : output
            )
        } catch is CancellationError {
            return EnvironmentActionResult(
                actionID: action.id,
                status: .cancelled,
                message: tr("the_command_was_cancelled")
            )
        } catch let error as ProcessExecutionError {
            return EnvironmentActionResult(
                actionID: action.id,
                status: .failed,
                message: error.localizedDescription
            )
        } catch {
            return EnvironmentActionResult(
                actionID: action.id,
                status: .failed,
                message: error.localizedDescription
            )
        }
    }

    private func result(
        for action: EnvironmentAction,
        succeeded: Bool,
        success: String,
        failure: String
    ) -> EnvironmentActionResult {
        EnvironmentActionResult(
            actionID: action.id,
            status: succeeded ? .succeeded : .failed,
            message: succeeded ? success : failure
        )
    }

    private func undo(_ step: EnvironmentUndoStep) async -> EnvironmentActionResult {
        switch step.operation {
        case .unhideApplications(let bundleIdentifiers):
            let applications = bundleIdentifiers.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            }
            let succeeded = applications.allSatisfy { $0.unhide() }
            return EnvironmentActionResult(
                actionID: step.actionID,
                status: succeeded ? .succeeded : .failed,
                message: succeeded ? tr("restored_the_apps_visible_state") : tr("couldn_t_fully_restore_the_apps_visible_state")
            )

        case .hideApplications(let bundleIdentifiers):
            let applications = bundleIdentifiers.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            }
            let succeeded = applications.allSatisfy { $0.hide() }
            return EnvironmentActionResult(
                actionID: step.actionID,
                status: succeeded ? .succeeded : .failed,
                message: succeeded ? tr("restored_the_apps_hidden_state") : tr("couldn_t_fully_restore_the_apps_hidden_state")
            )
        }
    }

    private struct ApplicationState {
        let bundleIdentifier: String
        let visibleBefore: Bool
        let hiddenBefore: Bool
        var wasRunning: Bool { visibleBefore || hiddenBefore }
    }

    private func applicationState(for action: EnvironmentAction) -> ApplicationState? {
        guard action.kind == .openApplication || action.kind == .hideApplication,
              let bundleIdentifier = applicationBundleIdentifier(for: action.value)
        else { return nil }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard !applications.isEmpty else {
            return ApplicationState(
                bundleIdentifier: bundleIdentifier,
                visibleBefore: false,
                hiddenBefore: false
            )
        }
        return ApplicationState(
            bundleIdentifier: bundleIdentifier,
            visibleBefore: applications.contains { !$0.isHidden },
            hiddenBefore: applications.contains(where: \.isHidden)
        )
    }

    private func makeUndoStep(
        for action: EnvironmentAction,
        before: ApplicationState?
    ) -> EnvironmentUndoStep? {
        guard let before else { return nil }
        switch action.kind {
        case .openApplication:
            guard before.hiddenBefore else { return nil }
            return EnvironmentUndoStep(
                actionID: action.id,
                operation: .hideApplications([before.bundleIdentifier])
            )
        case .hideApplication:
            guard before.visibleBefore else { return nil }
            return EnvironmentUndoStep(
                actionID: action.id,
                operation: .unhideApplications([before.bundleIdentifier])
            )
        case .openURL, .openFile, .runShortcut, .runCommand:
            return nil
        }
    }

    /// 传给 `shortcuts run` 的名字：去掉首尾空白；以 `-` 开头（会被当成选项）或
    /// 为空的一律拒绝，返回 nil。
    static func shortcutName(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        return trimmed
    }

    private func applicationBundleIdentifier(for value: String) -> String? {
        if value.hasPrefix("/") {
            return Bundle(url: URL(fileURLWithPath: value))?.bundleIdentifier
        }
        return value.isEmpty ? nil : value
    }
}
