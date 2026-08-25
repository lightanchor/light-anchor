import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct EnvironmentProfilesView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @State private var showingEditor = false
    @State private var editingProfile: EnvironmentProfile?
    @State private var snapshotDraft: EnvironmentSnapshotBuilder.Draft?
    @State private var snapshotLimitations: [String] = []
    @State private var snapshotFailureMessage: String?
    @State private var executionMessage: String?
    @State private var previewingProfile: EnvironmentProfile?
    @State private var confirmingCloseOut = false
    @State private var isClosingOut = false

    private var sortedProfiles: [EnvironmentProfile] {
        workspace.snapshot.environments.values.sorted { $0.name < $1.name }
    }

    var body: some View {
        // 样机 page-env：.readout 眉题行 + .listpanel 白卡行式列表，
        // 行内左标题/灰元信息、右侧 .btn.sm 操作组（试运行 / 编辑）。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LightAnchorReadout(tr("environments"), status: tr("one_click_to_set_up_a")) {
                    if !sortedProfiles.isEmpty {
                        LightAnchorReadoutCount(sortedProfiles.count)
                    }
                    #if os(macOS)
                    Button(tr("save_current_scene")) { snapshotCurrentScene() }
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                        .help(tr("save_the_apps_files_and_pages"))
                    #endif
                    Button(tr("new_environment")) {
                        editingProfile = nil
                        snapshotDraft = nil
                        snapshotLimitations = []
                        showingEditor = true
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                }

                if let session = workspace.environmentRunSession {
                    closeOutBanner(session)
                        .padding(.bottom, 10)
                }

                if sortedProfiles.isEmpty {
                    LightAnchorEmptyState(
                        title: tr("no_environments_yet"),
                        detail: tr("once_created_bind_one_to_your"),
                        actionTitle: tr("new_environment"),
                        action: {
                            editingProfile = nil
                            snapshotDraft = nil
                            snapshotLimitations = []
                            showingEditor = true
                        }
                    )
                    .padding(.top, 4)
                } else {
                    LightAnchorListPanel {
                        ForEach(sortedProfiles) { profile in
                            environmentRow(profile)
                            if profile.id != sortedProfiles.last?.id {
                                LightAnchorRowSeparator()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .sheet(isPresented: $showingEditor) {
            EnvironmentEditorView(
                profile: editingProfile,
                draft: snapshotDraft,
                draftLimitations: snapshotLimitations
            )
            .environmentObject(workspace)
        }
        .sheet(item: $previewingProfile) { profile in
            EnvironmentPreviewSheet(profile: profile) {
                previewingProfile = nil
                run(profile)
            }
        }
        .confirmationDialog(
            tr("closing_out_restores_the_apps_this"),
            isPresented: $confirmingCloseOut,
            titleVisibility: .visible
        ) {
            let launchedCount = workspace.environmentRunSession?
                .execution.launchedApplicationBundleIdentifiers.count ?? 0
            Button(tr("only_restore_visibility")) { closeOut(quitLaunched: false) }
            if launchedCount > 0 {
                Button(String(
                    format: launchedCount == 1
                        ? tr("restore_and_quit_the_apps_opened_one")
                        : tr("restore_and_quit_the_apps_opened"),
                    launchedCount
                )) {
                    closeOut(quitLaunched: true)
                }
            }
            Button(UserFacingCopy.cancel, role: .cancel) {}
        }
        .alert(
            tr("run_result"),
            isPresented: Binding(
                get: { executionMessage != nil },
                set: { if !$0 { executionMessage = nil } }
            )
        ) {
            Button(UserFacingCopy.done) { executionMessage = nil }
        } message: {
            Text(executionMessage ?? "")
        }
        // 存现场失败有自己的弹窗标题——它不是「执行结果」，
        // 而且要把没读到的原因（权限、无窗口）一并说清。
        .alert(
            tr("couldn_t_save_the_scene"),
            isPresented: Binding(
                get: { snapshotFailureMessage != nil },
                set: { if !$0 { snapshotFailureMessage = nil } }
            )
        ) {
            Button(UserFacingCopy.done) { snapshotFailureMessage = nil }
        } message: {
            Text(snapshotFailureMessage ?? "")
        }
    }

    /// 样机 .row：标题 13.5/550 + 灰元信息（「N 个动作 · 动作种类」），
    /// 右侧 .btn.sm 操作组，无行首图标、无 chevron。
    #if os(macOS)
    /// 环境逆向生成：把 ContextKit 当前采集到的桌面事实变成一份环境草稿,
    /// 打开编辑器让用户修剪后保存。配置成本从"逐项添加"变成"一次快照"。
    private func snapshotCurrentScene() {
        let observation = MacContextRecorder().capture()
        let draft = EnvironmentSnapshotBuilder.draft(from: observation.capsule)
        guard !draft.actions.isEmpty else {
            snapshotFailureMessage = observation.limitations.isEmpty
                ? tr("nothing_to_save_no_apps_with")
                : tr("nothing_to_save_right_now") + observation.limitations.joined(separator: " ")
            return
        }
        editingProfile = nil
        snapshotDraft = draft
        snapshotLimitations = observation.limitations
        showingEditor = true
    }
    #endif

    private func environmentRow(_ profile: EnvironmentProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine(for: profile))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(2)
            }

            Spacer(minLength: 14)

            HStack(spacing: 6) {
                Button(tr("preview")) {
                    previewingProfile = profile
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .disabled(profile.actions.isEmpty)
                .help(tr("dry_run_see_what_each_step"))
                .accessibilityLabel(String(format: tr("preview_environment"), profile.name))
                Button(tr("test_run")) {
                    run(profile)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .disabled(profile.actions.filter(\.isEnabled).isEmpty)
                Button(tr("edit")) {
                    editingProfile = profile
                    showingEditor = true
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .accessibilityLabel(String(format: tr("edit_environment"), profile.name))
            }
            .layoutPriority(1)
        }
        .lightAnchorListRow()
    }

    private func metaLine(for profile: EnvironmentProfile) -> String {
        guard !profile.actions.isEmpty else { return tr("no_actions") }
        let kinds = profile.actions.map { $0.kind.title }.joined(separator: "、")
        return String(
            format: profile.actions.count == 1 ? tr("n_actions_kinds_one") : tr("n_actions_kinds"),
            profile.actions.count,
            kinds
        )
    }

    private func run(_ profile: EnvironmentProfile) {
        Task { @MainActor in
            let execution = await EnvironmentActionRunner().executeSession(profile)
            workspace.recordEnvironmentRun(profile: profile, execution: execution)
            let results = execution.results
            let failed = results.filter { $0.status == .failed }.count
            let succeeded = results.filter { $0.status == .succeeded }.count
            let skipped = results.filter { $0.status == .skipped }.count
            let details = results.map(\.message).filter { !$0.isEmpty }.joined(separator: "\n")
            var summary = String(
                format: tr("environment_run_summary"),
                profile.name,
                succeeded,
                skipped,
                failed
            )
            if execution.isCloseOutMeaningful {
                summary += tr("wind_down_above_the_list_to")
            }
            executionMessage = summary + (details.isEmpty ? "" : "\n\(details)")
        }
    }

    private func closeOut(quitLaunched: Bool) {
        isClosingOut = true
        Task { @MainActor in
            executionMessage = await workspace.closeOutEnvironmentRun(
                quitLaunchedApplications: quitLaunched
            )
            isClosingOut = false
        }
    }

    /// 收场横幅：一次环境执行后出现，收场（恢复显示状态、可选退出新开应用）或忽略。
    private func closeOutBanner(_ session: AttentionWorkspace.EnvironmentRunSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            LightAnchorIcon("rotate-ccw", size: 16)
                .foregroundStyle(LightAnchorTheme.accentInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: tr("ran_at"), session.profileName, session.startedAt.formatted(date: .omitted, time: .shortened)))
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                Text(closeOutDetail(session))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            }
            Spacer(minLength: 14)
            Button(isClosingOut ? tr("closing_out") : tr("close_out")) {
                confirmingCloseOut = true
            }
            .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
            .disabled(isClosingOut)
            Button(tr("dismiss_2")) { workspace.dismissEnvironmentRunSession() }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .disabled(isClosingOut)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            LightAnchorTheme.accentWash,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func closeOutDetail(_ session: AttentionWorkspace.EnvironmentRunSession) -> String {
        var parts: [String] = []
        if !session.execution.undoSteps.isEmpty {
            parts.append(
                String(
                    format: session.execution.undoSteps.count == 1
                        ? tr("n_display_states_can_be_restored_one")
                        : tr("n_display_states_can_be_restored"),
                    session.execution.undoSteps.count
                )
            )
        }
        let launched = session.execution.launchedApplicationBundleIdentifiers.count
        if launched > 0 {
            parts.append(String(
                format: launched == 1 ? tr("n_apps_opened_this_run_one") : tr("n_apps_opened_this_run"),
                launched
            ))
        }
        return parts.joined(separator: " · ")
    }
}

/// 环境预览：干跑清单，逐条说明届时会发生什么 + 可行性检查。不执行任何动作。
private struct EnvironmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: EnvironmentProfile
    let onRun: () -> Void

    private var previews: [EnvironmentActionPreview] {
        EnvironmentActionRunner().preview(profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("environment"),
                title: String(format: tr("preview_2"), profile.name),
                subtitle: tr("here_s_what_a_test_run"),
                icon: "panels-top-left"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(previews.enumerated()), id: \.element.id) { index, preview in
                        previewRow(preview, index: index)
                    }
                }
                .padding(.vertical, 1)
            }

            LightAnchorSheetActionBar {
                Button(UserFacingCopy.done) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                Button(tr("test_run")) { onRun() }
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                    .disabled(!previews.contains { $0.status == .ready })
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 540, height: 480)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .onExitCommand { dismiss() }
    }

    private func previewRow(_ preview: EnvironmentActionPreview, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LightAnchorIcon(statusIcon(preview.status), size: 15)
                .foregroundStyle(statusColor(preview.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(preview.summary)")
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                if !preview.detail.isEmpty {
                    Text(preview.detail)
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .lineLimit(2)
                }
                if let note = statusNote(preview.status) {
                    Text(note)
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(statusColor(preview.status))
                }
            }
            Spacer(minLength: 8)
        }
        .lightAnchorRecessed(radius: 10, padding: 10)
    }

    private func statusIcon(_ status: EnvironmentActionPreviewStatus) -> String {
        switch status {
        case .ready: "check"
        case .willSkip: "circle-dashed"
        case .blocked: "alert-triangle"
        }
    }

    private func statusColor(_ status: EnvironmentActionPreviewStatus) -> LightAnchorThemeColor {
        switch status {
        case .ready: LightAnchorTheme.success
        case .willSkip: LightAnchorTheme.mutedInk
        case .blocked: LightAnchorTheme.warning
        }
    }

    private func statusNote(_ status: EnvironmentActionPreviewStatus) -> String? {
        switch status {
        case .ready: nil
        case .willSkip(let reason): String(format: tr("will_skip_reason"), reason)
        case .blocked(let reason): String(format: tr("will_fail_reason"), reason)
        }
    }
}

struct EnvironmentEditorView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    private let profile: EnvironmentProfile?
    @State private var name: String
    @State private var actions: [EnvironmentAction]
    @State private var allowedApplicationIDsText: String
    @State private var showingFileImporter = false
    @State private var fileActionID: UUID?

    /// 从「存下当前现场」进来时的开场说明：带入了什么、没读到什么。
    private let snapshotNote: (detail: String, incomplete: Bool)?

    init(
        profile: EnvironmentProfile?,
        draft: EnvironmentSnapshotBuilder.Draft? = nil,
        draftLimitations: [String] = []
    ) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? draft?.name ?? "")
        _actions = State(initialValue: profile?.actions ?? draft?.actions ?? [])
        let allowedIDs = profile?.allowedApplicationBundleIdentifiers
            ?? draft?.allowedApplicationBundleIdentifiers
        _allowedApplicationIDsText = State(
            initialValue: allowedIDs?.sorted().joined(separator: ", ") ?? ""
        )
        if profile == nil, let draft {
            var detail = String(
                format: tr("actions_from_scene_summary"),
                draft.actions.count,
                draft.actions.filter { $0.kind == .openApplication }.count,
                draft.actions.filter { $0.kind == .openFile }.count,
                draft.actions.filter { $0.kind == .openURL }.count
            )
            if !draftLimitations.isEmpty {
                detail += "\n" + draftLimitations.joined(separator: " ")
            }
            snapshotNote = (detail: detail, incomplete: !draftLimitations.isEmpty)
        } else {
            snapshotNote = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("environment"),
                title: profile == nil ? tr("new_environment_2") : tr("edit_environment_2"),
                subtitle: tr("configure_apps_links_files_or_commands"),
                icon: "panels-top-left"
            )

            if let snapshotNote {
                LightAnchorInfoStrip(
                    title: tr("brought_in_from_the_current_scene"),
                    detail: snapshotNote.detail,
                    icon: snapshotNote.incomplete ? "info" : "check-circle",
                    tint: snapshotNote.incomplete ? LightAnchorTheme.warning : LightAnchorTheme.success
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LightAnchorSettingsSection(
                        title: tr("basics"),
                        detail: tr("give_this_setup_a_name_you"),
                        icon: "panels-top-left"
                    ) {
                        TextField(tr("e_g_writing_desk"), text: $name)
                            .textFieldStyle(LightAnchorTextFieldStyle())
                    }

                    LightAnchorSettingsSection(
                        title: tr("actions"),
                        detail: actions.isEmpty ? tr("an_empty_environment_can_be_saved") : tr("actions_run_in_list_order"),
                        icon: "layers"
                    ) {
                        HStack {
                            Spacer()
                            Button {
                                actions.append(EnvironmentAction(kind: .openApplication, value: ""))
                            } label: {
                                LightAnchorLabel(title: tr("add_action"), icon: "plus", spacing: 6)
                            }
                            .buttonStyle(LightAnchorQuietButtonStyle())
                        }

                        if actions.isEmpty {
                            Text(tr("no_actions_yet"))
                                .font(LightAnchorTheme.supportingFont(size: 12))
                                .foregroundStyle(LightAnchorTheme.mutedInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lightAnchorRecessed(radius: 12, padding: 12)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                    actionRow(action, index: index)
                                }
                            }
                        }
                    }

                    LightAnchorSettingsSection(
                        title: tr("app_allowlist"),
                        detail: tr("optional_when_set_the_environment_only"),
                        icon: "app-window"
                    ) {
                        if selectedAllowedApplicationNames.isEmpty {
                            Text(tr("no_app_restriction"))
                                .font(LightAnchorTheme.supportingFont(size: 12))
                                .foregroundStyle(LightAnchorTheme.mutedInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(selectedAllowedApplicationNames) { application in
                                    HStack(spacing: 8) {
                                        LightAnchorIcon("app-window", size: 15)
                                            .foregroundStyle(LightAnchorTheme.iconSubtle)
                                        Text(application.name)
                                            .font(LightAnchorTheme.interfaceFont(size: 12, weight: .medium))
                                            .foregroundStyle(LightAnchorTheme.ink)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Button {
                                            removeAllowedApplication(application.id)
                                        } label: {
                                            LightAnchorIcon("x", size: 13)
                                        }
                                        .buttonStyle(LightAnchorIconButtonStyle())
                                        .help(tr("remove_app_2"))
                                        .accessibilityLabel(String(format: tr("remove_app"), application.name))
                                    }
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button(tr("choose_apps")) { chooseAllowedApplications() }
                                .buttonStyle(LightAnchorQuietButtonStyle())
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            LightAnchorSheetActionBar {
                Button(UserFacingCopy.cancel) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(UserFacingCopy.save) { save() }
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 620, height: 620)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item]
        ) { result in
            guard let actionID = fileActionID,
                  case .success(let url) = result else { return }
            actionValueBinding(actionID).wrappedValue = url.path
            fileActionID = nil
        }
    }

    private func actionRow(_ action: EnvironmentAction, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LightAnchorSelectField(
                    tr("action_type"),
                    selection: actionKindBinding(action.id),
                    options: EnvironmentAction.Kind.allCases,
                    titleForValue: { $0.title }
                )
                Button {
                    moveAction(action.id, offset: -1)
                } label: {
                    LightAnchorIcon("chevron-up", size: 14)
                }
                .buttonStyle(LightAnchorIconButtonStyle())
                .disabled(index == 0)
                .help(tr("move_up"))
                .accessibilityLabel(tr("move_action_up"))
                Button {
                    moveAction(action.id, offset: 1)
                } label: {
                    LightAnchorIcon("chevron-down", size: 14)
                }
                .buttonStyle(LightAnchorIconButtonStyle())
                .disabled(index == actions.count - 1)
                .help(tr("move_down"))
                .accessibilityLabel(tr("move_action_down"))
                Button {
                    actions.removeAll { $0.id == action.id }
                } label: {
                    LightAnchorIcon("trash-2", size: 16)
                }
                .buttonStyle(LightAnchorIconButtonStyle())
                .help(UserFacingCopy.delete)
                .accessibilityLabel(UserFacingCopy.delete)
            }
            actionValueControl(action)
            HStack(spacing: 8) {
                switch action.kind {
                case .openApplication, .hideApplication:
                    Button(tr("choose_apps")) { chooseApplication(for: action.id) }
                        .buttonStyle(LightAnchorQuietButtonStyle())
                case .openFile:
                    Button(tr("choose_file")) {
                        fileActionID = action.id
                        showingFileImporter = true
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                case .openURL, .runShortcut, .runCommand:
                    EmptyView()
                }
                Spacer(minLength: 8)
            }
            Toggle(tr("enable"), isOn: actionEnabledBinding(action.id))
                .toggleStyle(.switch)
        }
        .lightAnchorRecessed(radius: 14, padding: 12)
    }

    @ViewBuilder
    private func actionValueControl(_ action: EnvironmentAction) -> some View {
        switch action.kind {
        case .openApplication, .hideApplication:
            HStack(spacing: 8) {
                LightAnchorIcon("app-window", size: 15)
                    .foregroundStyle(LightAnchorTheme.iconSubtle)
                Text(applicationDisplayName(for: action.value) ?? fallbackApplicationName(for: action.value))
                    .font(LightAnchorTheme.interfaceFont(size: 12, weight: .medium))
                    .foregroundStyle(
                        action.value.isEmpty
                            ? LightAnchorTheme.mutedInk
                            : LightAnchorTheme.ink
                    )
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34, alignment: .leading)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LightAnchorTheme.subtleBorder.opacity(0.72), lineWidth: 1)
            }
        default:
            TextField(valuePlaceholder(for: action.kind), text: actionValueBinding(action.id))
                .textFieldStyle(LightAnchorTextFieldStyle())
        }
    }

    private struct SelectedApplication: Identifiable {
        let id: String
        let name: String
    }

    private var allowedApplicationIDs: [String] {
        allowedApplicationIDsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var selectedAllowedApplicationNames: [SelectedApplication] {
        allowedApplicationIDs.map { bundleID in
            SelectedApplication(
                id: bundleID,
                name: applicationDisplayName(for: bundleID) ?? fallbackApplicationName(for: bundleID)
            )
        }
    }

    private func applicationDisplayName(for value: String) -> String? {
        #if os(macOS)
        let applicationURL: URL?
        if value.hasPrefix("/") {
            applicationURL = URL(fileURLWithPath: value)
        } else {
            applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
        }
        guard let applicationURL else { return nil }

        if let bundleDisplayName = Bundle(url: applicationURL)?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String,
           !bundleDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundleDisplayName
        }

        let fileDisplayName = FileManager.default.displayName(atPath: applicationURL.path)
        if !fileDisplayName.isEmpty {
            return fileDisplayName.hasSuffix(".app")
                ? String(fileDisplayName.dropLast(4))
                : fileDisplayName
        }
        return applicationURL.deletingPathExtension().lastPathComponent
        #else
        return nil
        #endif
    }

    private func fallbackApplicationName(for value: String) -> String {
        value.isEmpty ? tr("no_app_selected") : tr("app_selected_not_currently_installed")
    }

    private func removeAllowedApplication(_ bundleID: String) {
        allowedApplicationIDsText = allowedApplicationIDs
            .filter { $0 != bundleID }
            .joined(separator: ", ")
    }

    // Bindings resolve by identity, not position: a row that is still alive
    // after a neighbour is deleted would subscript past the end of `actions`.
    private func action(_ id: UUID) -> EnvironmentAction? {
        actions.first { $0.id == id }
    }

    private func replaceAction(_ id: UUID, with newAction: EnvironmentAction) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index] = newAction
    }

    private func moveAction(_ id: UUID, offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard actions.indices.contains(destination) else { return }
        actions.swapAt(index, destination)
    }

    private func actionKindBinding(_ id: UUID) -> Binding<EnvironmentAction.Kind> {
        Binding(
            get: { action(id)?.kind ?? .openApplication },
            set: { newKind in
                guard let current = action(id) else { return }
                replaceAction(id, with: EnvironmentAction(
                    id: current.id,
                    kind: newKind,
                    value: current.value,
                    isEnabled: current.isEnabled
                ))
            }
        )
    }

    private func actionValueBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { action(id)?.value ?? "" },
            set: { value in
                guard let current = action(id) else { return }
                replaceAction(id, with: EnvironmentAction(
                    id: current.id,
                    kind: current.kind,
                    value: value,
                    isEnabled: current.isEnabled
                ))
            }
        )
    }

    private func actionEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { action(id)?.isEnabled ?? false },
            set: { enabled in
                guard let current = action(id) else { return }
                replaceAction(id, with: EnvironmentAction(
                    id: current.id,
                    kind: current.kind,
                    value: current.value,
                    isEnabled: enabled
                ))
            }
        )
    }

    private func valuePlaceholder(for kind: EnvironmentAction.Kind) -> String {
        switch kind {
        case .openApplication, .hideApplication: tr("choose_an_app")
        case .openURL: tr("paste_a_link_to_open")
        case .openFile: tr("choose_a_file_to_open")
        case .runShortcut: tr("enter_the_shortcut_s_name")
        case .runCommand: tr("enter_a_command_e_g_cd")
        }
    }

    private func chooseAllowedApplications() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK else { return }
        let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        allowedApplicationIDsText = Set(allowedApplicationIDs + bundleIDs)
            .sorted()
            .joined(separator: ", ")
        #endif
    }

    private func chooseApplication(for actionID: UUID) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        actionValueBinding(actionID).wrappedValue = Bundle(url: url)?.bundleIdentifier ?? url.path
        #endif
    }

    private func save() {
        let bundleIDs = Set(allowedApplicationIDs)
        let saved: Bool
        if let profile {
            saved = workspace.updateEnvironment(
                profile.id,
                name: name,
                actions: actions,
                allowedApplicationBundleIdentifiers: bundleIDs
            )
        } else {
            saved = workspace.createEnvironment(
                name: name,
                actions: actions,
                allowedApplicationBundleIdentifiers: bundleIDs
            ) != nil
        }
        if saved { dismiss() }
    }
}
