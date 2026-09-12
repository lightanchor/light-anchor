import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DataManagementView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @AppStorage(AttentionWorkspace.inboxAutoArchiveEnabledKey)
    private var inboxAutoArchiveEnabled = false
    @AppStorage(AttentionWorkspace.inboxAutoArchiveDaysKey)
    private var inboxAutoArchiveDays = 7.0
    @State private var exportDocument: JSONDataDocument?
    @State private var diagnosticDocument: JSONDataDocument?
    @State private var showingDataExporter = false
    @State private var showingDiagnosticExporter = false
    @State private var showingArchiveImporter = false
    @State private var showingRestoreConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var archiveToRestore: URL?
    @State private var archivePhase: LocalDataArchivePhase?
    @State private var operationError: String?
    @State private var operationMessage: String?

    // 版本快照：服务实例无状态（串行队列内聚），视图直接持有。
    private let snapshotService = GitSnapshotService()
    @State private var snapshots: [LightAnchorSnapshot] = []
    @State private var snapshotToRestore: LightAnchorSnapshot?
    @State private var confirmFirstSync = false
    @State private var remoteURLText = ""
    @State private var lastPush: Date?

    // GitHub 一键连接（Device Flow）。
    private let githubAuth = GitHubAuthService()
    @State private var githubConnected = false
    @State private var deviceAuthorization: GitHubDeviceAuthorization?
    @State private var pairingExpired = false
    @State private var githubWaitTask: Task<Void, Never>?
    @State private var creatingBackupRepo = false

    var body: some View {
        // 样机 setbody：组标签 + 白卡行式，与外观页同一套组件。
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupLabel(tr("export"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            title: tr("export_local_data"),
                            detail: tr("json_format_easy_to_inspect_local")
                        ) {
                            Button(tr("export")) { exportData() }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                        }
                        settingsRowDivider
                        settingsRow(
                            title: tr("export_diagnostics"),
                            detail: tr("local_run_records_for_troubleshooting")
                        ) {
                            Button(tr("export")) { exportDiagnostics() }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                        }
                    }
                }

                settingsGroupLabel(tr("full_backup"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            title: tr("create_backup"),
                            detail: tr("includes_records_and_attachments_not_running")
                        ) {
                            Button(tr("create_backup")) { saveArchive() }
                                .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                                .disabled(archivePhase != nil)
                        }
                        settingsRowDivider
                        settingsRow(
                            title: tr("restore_from_backup"),
                            detail: tr("current_data_is_kept_as_a")
                        ) {
                            Button(tr("restore_from_backup")) { showingArchiveImporter = true }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                                .disabled(archivePhase != nil)
                        }
                        if let archivePhase {
                            settingsRowDivider
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(archivePhase.title)
                                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                                    .foregroundStyle(LightAnchorTheme.mutedInk)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                        }
                    }
                }

                settingsGroupLabel(tr("version_snapshots"))
                settingsCard {
                    VStack(spacing: 0) {
                        // 「现在」条：自动存的状态展示，不是按钮（视觉稿 .now-strip）。
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(LightAnchorTheme.successBadge.opacity(0.18))
                                    .frame(width: 13, height: 13)
                                Circle()
                                    .fill(LightAnchorTheme.successBadge)
                                    .frame(width: 7, height: 7)
                            }
                            .frame(width: 13, height: 13)
                            Text(tr("snapshot_now_strip"))
                                .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                                .foregroundStyle(LightAnchorTheme.ink)
                            Spacer(minLength: 8)
                            if let latest = snapshots.first {
                                Text(String(
                                    format: tr("last_snapshot_at"),
                                    latest.date.formatted(date: .omitted, time: .shortened)
                                ))
                                .font(LightAnchorTheme.supportingFont(size: 11.5))
                                .foregroundStyle(LightAnchorTheme.faintInk)
                                .monospacedDigit()
                            }
                            Button(tr("snapshot_now")) { takeSnapshot() }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        settingsRowDivider
                        if snapshots.isEmpty {
                            settingsRow(title: tr("no_snapshots_yet"), detail: nil) { }
                        } else {
                            // 按天分组的时间线（视觉稿 .tl）：快照说明 = 那一刻在做的事。
                            VStack(spacing: 0) {
                                ForEach(SnapshotDayGrouping.groups(for: snapshots)) { group in
                                    Text(group.label)
                                        .font(LightAnchorTheme.labelFont(size: 11))
                                        .foregroundStyle(LightAnchorTheme.mutedInk)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 18)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)
                                    ForEach(group.snapshots, id: \.id) { snapshot in
                                        SnapshotTimelineRow(
                                            snapshot: snapshot,
                                            isLatest: snapshot.id == snapshots.first?.id
                                        ) {
                                            snapshotToRestore = snapshot
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        settingsRowDivider
                        settingsRow(
                            title: tr("sync_with_remote"),
                            detail: syncStatusDetail
                        ) {
                            Button(tr("sync_now")) { requestSync() }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                                .disabled(remoteURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        // GitHub 行三态：连接 / 配对码行内态 / 已连接（视觉稿 ④）。
                        // 一键连接要求构建配置 client id；已连接时始终出现，保证能断开。
                        if GitHubAuthService.isConfigured || githubConnected {
                            settingsRowDivider
                            if let authorization = deviceAuthorization {
                                githubPairingRow(authorization)
                            } else {
                                githubStatusRow
                                // 已连接但还没填地址：一键建私有库，别让用户自己开网页建库再粘链接。
                                if githubConnected && remoteURLText.trimmingCharacters(in: .whitespaces).isEmpty {
                                    settingsRowDivider
                                    settingsRow(
                                        title: tr("create_backup_repo"),
                                        detail: tr("create_backup_repo_detail")
                                    ) {
                                        Button(creatingBackupRepo ? tr("creating_backup_repo") : tr("create_backup_repo")) {
                                            ensureBackupRepo()
                                        }
                                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                                        .disabled(creatingBackupRepo)
                                    }
                                }
                            }
                        }
                        settingsRowDivider
                        // 备份地址写成句子填空，贴表单三条硬规则。
                        HStack(spacing: 6) {
                            Text(tr("push_to_sentence_prefix"))
                                .font(LightAnchorTheme.supportingFont(size: 12))
                            TextField("https://…", text: $remoteURLText)
                                .textFieldStyle(.plain)
                                .font(LightAnchorTheme.supportingFont(size: 12))
                                .onSubmit { saveRemoteURL() }
                            Text(tr("push_to_sentence_suffix"))
                                .font(LightAnchorTheme.supportingFont(size: 12))
                        }
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                }

                settingsGroupLabel(tr("inbox_auto_archive"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            title: tr("enable_auto_archive"),
                            detail: tr("untouched_ordinary_captures_are_archived_after")
                        ) {
                            Toggle("", isOn: $inboxAutoArchiveEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(tr("enable_auto_archive"))
                        }
                        settingsRowDivider
                        LightAnchorSelectField(
                            tr("keep_ordinary_captures"),
                            selection: $inboxAutoArchiveDays,
                            options: [3.0, 7.0, 14.0, 30.0],
                            titleForValue: { String(format: tr("d_2"), Int($0)) }
                        )
                        .disabled(!inboxAutoArchiveEnabled)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        settingsRowDivider
                        settingsRow(
                            title: inboxAutoArchiveEnabled ? tr("runs_periodically_in_the_background") : tr("existing_captures_won_t_be_auto"),
                            detail: nil
                        ) {
                            Button(tr("run_now")) {
                                let archivedCount = workspace.archiveConfiguredInbox()
                                operationMessage = archivedCount == 0
                                    ? tr("no_captures_need_auto_archiving")
                                    : String(
                                        format: archivedCount == 1
                                            ? tr("auto_archived_n_captures_one")
                                            : tr("auto_archived_n_captures"),
                                        archivedCount
                                    )
                            }
                            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                            .disabled(!inboxAutoArchiveEnabled)
                        }
                    }
                }

                settingsGroupLabel(tr("tidy_up"))
                settingsCard {
                    settingsRow(
                        title: tr("delete_all_local_data"),
                        detail: tr("make_sure_you_ve_exported_or")
                    ) {
                        Button(tr("delete"), role: .destructive) { showingDeleteConfirmation = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(LightAnchorTheme.dangerText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .onChange(of: inboxAutoArchiveEnabled) { _, _ in
            autoArchiveSettingsChanged()
        }
        .onChange(of: inboxAutoArchiveDays) { _, _ in
            autoArchiveSettingsChanged()
        }
        .fileExporter(isPresented: $showingDataExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "light-anchor-export.json") { handleExporterResult($0) }
        .fileExporter(isPresented: $showingDiagnosticExporter, document: diagnosticDocument, contentType: .json,
                      defaultFilename: "light-anchor-diagnostics.json") { handleExporterResult($0) }
        .fileImporter(isPresented: $showingArchiveImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                archiveToRestore = url
                showingRestoreConfirmation = true
            case .failure(let error):
                operationError = error.localizedDescription
            }
        }
        .alert(tr("restore_from_backup_2"), isPresented: $showingRestoreConfirmation) {
            Button(tr("restore"), role: .destructive) { restoreArchive() }
            Button(tr("cancel"), role: .cancel) { archiveToRestore = nil }
        } message: {
            Text(tr("current_data_is_saved_as_a"))
        }
        .onAppear { reloadSnapshotState() }
        // 「回到这一刻」与「首次推送」两屏确认装不进 .alert（目标卡 / 出机清单），
        // 用设置页轻量模态落视觉稿 ②③。
        .overlay {
            if let target = snapshotToRestore {
                restoreSnapshotDialog(target)
            } else if confirmFirstSync {
                firstSyncDialog
            }
        }
        .alert(tr("delete_all_local_data_2"), isPresented: $showingDeleteConfirmation) {
            // 全应用最重的不可撤销操作：确认键复述完整后果，不用裸「删除」
            //（那是单条捕获的日常词）。
            Button(tr("delete_all_data"), role: .destructive) {
                if workspace.deleteAllData() {
                    operationMessage = tr("workspace_data_on_this_mac_has")
                } else {
                    operationError = workspace.lastError ?? tr("couldn_t_delete_local_data")
                }
            }
            Button(tr("cancel"), role: .cancel) { }
        } message: {
            Text(tr("this_deletes_current_work_later_items"))
        }
        .alert(tr("operation_finished"), isPresented: Binding(get: { operationMessage != nil }, set: { if !$0 { operationMessage = nil } })) {
            Button(tr("got_it")) { operationMessage = nil }
        } message: {
            Text(operationMessage ?? "")
        }
        .alert(tr("operation_failed"), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button(tr("got_it")) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    // MARK: - 版本快照

    /// 同步行的状态：失败要说出来（自动同步是静默跑的，这里是唯一出口）。
    private var syncStatusDetail: String {
        if let error = snapshotService.lastSyncError {
            return String(format: tr("last_sync_failed"), error)
        }
        if let date = snapshotService.lastSyncDate {
            return String(format: tr("last_synced_at"), date.formatted(date: .abbreviated, time: .shortened))
        }
        return tr("sync_with_remote_detail")
    }

    /// 对话框里展示的备份地址：剥掉 scheme 和可能内嵌的 PAT，绝不回显令牌。
    private var sanitizedRemoteDescription: String {
        let trimmed = remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else { return trimmed }
        return host + url.path
    }

    /// 「回到这一刻」确认（视觉稿 ②）：目标时刻钉在浅蓝卡里，正文说清可撤销。
    private func restoreSnapshotDialog(_ target: LightAnchorSnapshot) -> some View {
        let newerCount = snapshots.firstIndex(where: { $0.id == target.id }) ?? 0
        let moment = "\(SnapshotDayGrouping.label(for: target.date)) \(target.date.formatted(date: .omitted, time: .shortened))"
        return LightAnchorSettingsDialog(
            title: tr("restore_snapshot_confirm_title"),
            cancelTitle: tr("cancel"),
            confirmTitle: tr("restore_snapshot"),
            width: 400,
            onCancel: { snapshotToRestore = nil },
            onConfirm: {
                snapshotToRestore = nil
                restoreSnapshot(target)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(LightAnchorTheme.primaryAction)
                            .frame(width: 6, height: 6)
                        Text(target.subject)
                            .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.ink)
                            .lineLimit(1)
                    }
                    Text(newerCount == 0 ? moment : "\(moment) · \(snapshotsAfterText(newerCount))")
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LightAnchorTheme.accentWash,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                Text(tr("restore_snapshot_body"))
                    .font(LightAnchorTheme.supportingFont(size: 13))
                    .foregroundStyle(LightAnchorTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func snapshotsAfterText(_ count: Int) -> String {
        String(
            format: count == 1 ? tr("snapshots_after_one") : tr("snapshots_after_many"),
            count
        )
    }

    /// 首次同步确认（视觉稿 ③）：数据出机的唯一通道，剪贴板单独一条说透。
    private var firstSyncDialog: some View {
        LightAnchorSettingsDialog(
            title: tr("first_push_confirm_title"),
            cancelTitle: tr("not_yet"),
            confirmTitle: tr("push_confirm_go"),
            width: 440,
            onCancel: { confirmFirstSync = false },
            onConfirm: {
                confirmFirstSync = false
                runSync()
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: tr("first_push_body_to"), sanitizedRemoteDescription))
                    .font(LightAnchorTheme.supportingFont(size: 13))
                    .foregroundStyle(LightAnchorTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("leave_mac_list_title"))
                        .font(LightAnchorTheme.labelFont(size: 11))
                        .foregroundStyle(LightAnchorTheme.warning)
                    ForEach(
                        [
                            tr("leave_mac_item_records"),
                            tr("leave_mac_item_shots"),
                            tr("leave_mac_item_clipboard"),
                        ],
                        id: \.self
                    ) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(item)
                        }
                        .font(LightAnchorTheme.supportingFont(size: 12.5))
                        .foregroundStyle(LightAnchorTheme.secondaryInk)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LightAnchorTheme.warningBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LightAnchorTheme.warning.opacity(0.35), lineWidth: 1)
                )
                Text(tr("first_push_keep_private"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// GitHub 状态行（视觉稿 ④ 左半）：图标 + 连接/断开。
    @ViewBuilder
    private var githubStatusRow: some View {
        HStack(spacing: 10) {
            GitHubMarkIcon()
                .foregroundStyle(LightAnchorTheme.secondaryInk)
            VStack(alignment: .leading, spacing: 1) {
                Text(githubConnected ? tr("github_connected") : tr("connect_github"))
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                if !githubConnected {
                    Text(pairingExpired ? tr("github_code_expired") : tr("connect_github_detail"))
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }
            }
            Spacer(minLength: 14)
            if githubConnected {
                Button(tr("disconnect_github")) {
                    githubAuth.disconnect()
                    githubConnected = false
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            } else {
                Button(pairingExpired ? tr("github_restart_pairing") : tr("connect_github")) { connectGitHub() }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    /// 配对码行内态（视觉稿 ④ 右半）：等宽大字，可选中可拷贝，不弹窗打断设置流。
    private func githubPairingRow(_ authorization: GitHubDeviceAuthorization) -> some View {
        HStack(spacing: 14) {
            GitHubMarkIcon(size: 17)
                .foregroundStyle(LightAnchorTheme.secondaryInk)
            Text(authorization.userCode)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(LightAnchorTheme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    LightAnchorTheme.recessed,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("github_pairing_hint"))
                Text(tr("github_waiting_for_you") + "…")
            }
            .font(LightAnchorTheme.supportingFont(size: 11.5))
            .foregroundStyle(LightAnchorTheme.faintInk)
            Spacer(minLength: 8)
            Button(tr("copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authorization.userCode, forType: .string)
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            Button(tr("open_github")) {
                NSWorkspace.shared.open(authorization.verificationURL)
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func reloadSnapshotState() {
        snapshots = (try? snapshotService.history(limit: 20)) ?? []
        remoteURLText = snapshotService.remoteURL?.absoluteString ?? ""
        lastPush = snapshotService.lastPushDate
        githubConnected = githubAuth.isConnected
    }

    private func connectGitHub() {
        let auth = githubAuth
        githubWaitTask?.cancel()
        pairingExpired = false
        githubWaitTask = Task {
            do {
                let authorization = try await auth.begin()
                deviceAuthorization = authorization
                // 配对码一出来就打开浏览器，别让用户自己找入口。
                NSWorkspace.shared.open(authorization.verificationURL)
                _ = try await auth.waitForToken(authorization)
                deviceAuthorization = nil
                githubConnected = true
                operationMessage = tr("github_connected_done")
            } catch is CancellationError {
                deviceAuthorization = nil
            } catch GitHubAuthError.expired {
                // 配对码过期不弹窗：行内变成「配对码过期了——重新开始」（视觉稿 ④）。
                deviceAuthorization = nil
                pairingExpired = true
            } catch {
                deviceAuthorization = nil
                operationError = error.localizedDescription
            }
        }
    }

    /// 一键备好备份仓库：创建（或采用已有的）私有库，地址自动填好。
    /// 只填地址不动数据——首次同步仍会先弹「数据离开这台 Mac」确认。
    private func ensureBackupRepo() {
        let auth = githubAuth
        creatingBackupRepo = true
        Task {
            do {
                let outcome = try await auth.ensurePrivateBackupRepository()
                switch outcome {
                case .created(let url):
                    remoteURLText = url.absoluteString
                    saveRemoteURL()
                    operationMessage = tr("backup_repo_created")
                case .alreadyExisted(let url):
                    remoteURLText = url.absoluteString
                    saveRemoteURL()
                    operationMessage = tr("backup_repo_adopted")
                }
            } catch {
                operationError = error.localizedDescription
            }
            creatingBackupRepo = false
        }
    }

    private func takeSnapshot() {
        do {
            let made = try snapshotService.snapshot(note: tr("manual_snapshot_subject"))
            operationMessage = made == nil ? tr("snapshot_nothing_new") : tr("snapshot_saved")
            reloadSnapshotState()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func restoreSnapshot(_ snapshot: LightAnchorSnapshot) {
        do {
            try snapshotService.restore(to: snapshot.id)
            guard workspace.reloadFromDisk() else {
                operationError = workspace.lastError ?? tr("couldn_t_reload_after_restore")
                return
            }
            operationMessage = tr("snapshot_restored")
            reloadSnapshotState()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func saveRemoteURL() {
        let trimmed = remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshotService.remoteURL = trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    private func requestSync() {
        saveRemoteURL()
        // 还没推送过 = 数据第一次离开这台机器，先确认；之后直接同步。
        if lastPush == nil {
            confirmFirstSync = true
        } else {
            runSync()
        }
    }

    private func runSync() {
        saveRemoteURL()
        let service = snapshotService
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<GitSnapshotService.SyncOutcome, Error> in
                do {
                    return .success(try service.sync())
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let outcome):
                if outcome == .merged {
                    guard workspace.reloadFromDisk() else {
                        operationError = workspace.lastError ?? tr("couldn_t_reload_after_restore")
                        reloadSnapshotState()
                        return
                    }
                    operationMessage = tr("sync_done_merged")
                } else {
                    operationMessage = tr("sync_done_up_to_date")
                }
            case .failure(let error):
                operationError = error.localizedDescription
            }
            reloadSnapshotState()
        }
    }

    private func exportData() {
        do {
            exportDocument = JSONDataDocument(data: try workspace.exportData())
            showingDataExporter = true
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func exportDiagnostics() {
        do {
            diagnosticDocument = JSONDataDocument(data: try LocalDiagnostics.shared.exportData())
            showingDiagnosticExporter = true
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func saveArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "light-anchor-backup.zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runArchiveOperation(startingWith: .collecting) { service, report in
            try service.createArchive(at: url, onProgress: report)
            return tr("full_backup_created")
        }
    }

    private func restoreArchive() {
        guard let archive = archiveToRestore else { return }
        archiveToRestore = nil
        runArchiveOperation(startingWith: .extracting) { service, report in
            try service.restoreArchive(from: archive, onProgress: report)
            return nil
        } onFinish: {
            guard workspace.reloadFromDisk(quarantiningRestoredAutomation: true) else {
                operationError = workspace.lastError ?? tr("backup_restored_but_the_data_couldn")
                return
            }
            operationMessage = tr("local_data_restored_from_backup")
        }
    }

    /// Copying and zipping the whole data directory takes long enough to freeze
    /// the window, so it runs off the main actor with the phase reported back.
    private func runArchiveOperation(
        startingWith phase: LocalDataArchivePhase,
        _ work: @escaping @Sendable (
            LocalDataArchiveService,
            @escaping @Sendable (LocalDataArchivePhase) -> Void
        ) throws -> String?,
        onFinish: @MainActor @escaping () -> Void = { }
    ) {
        guard archivePhase == nil else { return }
        archivePhase = phase
        let service = LocalDataArchiveService()
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String?, Error> in
                do {
                    return .success(try work(service) { reached in
                        Task { @MainActor in archivePhase = reached }
                    })
                } catch {
                    return .failure(error)
                }
            }.value

            archivePhase = nil
            switch result {
            case .success(let message):
                if let message { operationMessage = message }
                onFinish()
            case .failure(let error):
                operationError = error.localizedDescription
            }
        }
    }

    private func handleExporterResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            operationError = error.localizedDescription
        }
    }

    private func autoArchiveSettingsChanged() {
        UserDefaults.standard.set(
            inboxAutoArchiveDays,
            forKey: AttentionWorkspace.inboxAutoArchiveDaysKey
        )
        workspace.runBackgroundMaintenance()
    }
}
