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
