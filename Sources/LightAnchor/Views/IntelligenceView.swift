import SwiftUI

// MARK: - 智能偏好页
//
// 在设置中展示为「智能」feature 的详情页（内嵌，不再开二级 sheet）。

struct IntelligenceView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace

    @State private var preferences: IntelligencePreferences = .default

    var body: some View {
        // 样机 setbody：组标签 + 白卡行式，与外观页同一套组件。
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupLabel(tr("engine"))
                engineCard

                // 云端配置是独立一张卡，摊在这一层而不是塞进引擎卡里：
                // 嵌套卡片会把「选哪套」这件事压到看不见的深处。
                if preferences.engine == .cloud {
                    CloudProfilesSettings(preferences: $preferences, onSave: save)
                }

                settingsGroupLabel(tr("scene_snapshot"))
                sceneSnapshotCard

                settingsGroupLabel(tr("features"))
                featureTogglesCard

                Text(tr("cloud_enhancement_needs_your_own_api"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .onAppear {
            preferences = workspace.intelligencePreferences
        }
    }

    // MARK: - 引擎选择

    private var engineCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 8) {
                    engineOption(.cloud, icon: "cloud", title: tr("cloud_primary"), detail: tr("connect_a_compatible_service_of_your"))
                    engineOption(.onDevice, icon: "cpu", title: tr("on_device_fallback"), detail: tr("use_on_device_apple_intelligence_nothing"))
                }

                // 端侧可用性提示
                if preferences.engine == .onDevice && !IntelligenceEngineFactory.onDeviceAvailable {
                    HStack(spacing: 8) {
                        LightAnchorIcon("info", size: 14)
                            .foregroundStyle(LightAnchorTheme.warning)
                        Text(tr("on_device_models_need_macos_26"))
                            .font(LightAnchorTheme.supportingFont(size: 12))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LightAnchorTheme.warningBackground.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func engineOption(_ engine: IntelligenceEngine, icon: String, title: String, detail: String) -> some View {
        Button {
            preferences.engine = engine
            save()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(preferences.engine == engine
                            ? LightAnchorTheme.accentInk
                            : LightAnchorTheme.elevatedSurface)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            preferences.engine == engine
                                ? LightAnchorTheme.accentInk.opacity(0.45)
                                : LightAnchorTheme.ink.opacity(0.13),
                            lineWidth: 1
                        )
                    if preferences.engine == engine {
                        LightAnchorIcon("check", size: 12)
                            .foregroundStyle(LightAnchorTheme.onAction)
                    }
                }
                .frame(width: 20, height: 20)

                LightAnchorIcon(icon, size: 16)
                    .foregroundStyle(LightAnchorTheme.mutedInk)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                        .foregroundStyle(LightAnchorTheme.ink)
                    Text(detail)
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            preferences.engine == engine
                ? LightAnchorTheme.accentInk.opacity(0.08)
                : LightAnchorTheme.recessed,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityAddTraits(preferences.engine == engine ? .isSelected : [])
    }

    // MARK: - 现场快照设置

    private var sceneSnapshotCard: some View {
        settingsCard {
            VStack(spacing: 0) {
                SceneFilterPicker(
                    mode: preferences.sceneFilterDefault,
                    onChange: { newMode in
                        preferences.sceneFilterDefault = newMode
                        save()
                    }
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                settingsRowDivider
                toggleRow(
                    title: tr("save_terminal_directory_and_running_command"),
                    detail: nil,
                    isOn: $preferences.saveTerminalCommands
                )
                settingsRowDivider
                toggleRow(
                    title: tr("save_clipboard_contents"),
                    detail: tr("notes_the_clipboard_text_when_you"),
                    isOn: $preferences.saveClipboardContent
                )
                settingsRowDivider
                toggleRow(
                    title: tr("save_window_screenshots"),
                    detail: screenshotToggleDetail,
                    isOn: screenshotToggleBinding
                )
            }
        }
    }

    // MARK: - 功能开关

    private var featureTogglesCard: some View {
        settingsCard {
            VStack(spacing: 0) {
                toggleRow(
                    title: tr("adhd_friendly_output"),
                    detail: tr("shapes_all_ai_generated_text_return"),
                    isOn: $preferences.adhdFriendlyOutput
                )
                settingsRowDivider
                toggleRow(
                    title: tr("auto_draft_look_at_this_first"),
                    detail: nil,
                    isOn: $preferences.generateReturnCue
                )
                settingsRowDivider
                toggleRow(
                    title: tr("auto_summarize_episodes"),
                    detail: tr("auto_summarize_episodes_detail"),
                    isOn: $preferences.autoSummarizeEpisodes
                )
                settingsRowDivider
                toggleRow(
                    title: tr("check_whether_the_scene_changed_before"),
                    detail: nil,
                    isOn: $preferences.checkSceneStaleness
                )
                settingsRowDivider
                toggleRow(
                    title: tr("auto_tidy_the_inbox"),
                    detail: tr("fills_in_missing_link_titles_and"),
                    isOn: $preferences.inboxAutoOrganize
                )
                settingsRowDivider
                toggleRow(
                    title: tr("auto_record_episodes"),
                    detail: tr("auto_record_episodes_detail"),
                    isOn: $preferences.autoRecordEpisodes
                )
            }
        }
    }

    /// 截图开关的文案随权限状态变化：没权限时说清打开后会发生什么。
    private var screenshotToggleDetail: String {
        if !SceneScreenshotRecorder.hasPermission {
            return tr("saves_one_desktop_screenshot_with_the_2")
        }
        return tr("saves_one_desktop_screenshot_with_the")
    }

    /// 打开截图开关时顺手申请屏幕录制权限（系统只弹一次，之后要去系统设置改）。
    private var screenshotToggleBinding: Binding<Bool> {
        Binding(
            get: { preferences.saveWindowScreenshot },
            set: { enabled in
                preferences.saveWindowScreenshot = enabled
                if enabled, !SceneScreenshotRecorder.hasPermission {
                    Task { await SceneScreenshotRecorder.requestPermission() }
                }
            }
        )
    }

    /// 样机 .setrow：左标题/说明 + 右开关。
    private func toggleRow(title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        settingsRow(title: title, detail: detail) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: isOn.wrappedValue) { _, _ in save() }
                .accessibilityLabel(title)
        }
    }

    private func save() {
        workspace.updateIntelligencePreferences(preferences)
    }
}

// MARK: - 云端配置方案
//
// 卡片只做两件日常事：看清哪套在用（点行即切换），和一键测试。
// 编辑收进独立弹窗（环境页同款 sheet），取消/保存兜底，设置页不再摊开
// 一整墙字段。新建/复制收进「新建方案」菜单，建完直接进编辑弹窗补 Key。
private struct CloudProfilesSettings: View {
    @Binding var preferences: IntelligencePreferences
    let onSave: () -> Void

    @State private var isTestingConnection = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var editingProfile: CloudProviderProfile?

    private var activeProfile: CloudProviderProfile { preferences.activeCloudProfile }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroupLabel(tr("cloud_providers"))
            profileCard
        }
        .sheet(item: $editingProfile) { profile in
            CloudProfileEditorView(
                profile: profile,
                isOnlyProfile: preferences.cloudProfiles.count < 2,
                siblingNames: Set(
                    preferences.cloudProfiles
                        .filter { $0.id != profile.id }
                        .map(\.name)
                ),
                onSave: { commitEdited($0) },
                onDelete: { deleteProfile(id: profile.id) }
            )
        }
        .onAppear {
            #if DEBUG
            // 调试后门（截图/验收用）：直接打开使用中方案的编辑弹窗。
            if ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_EDIT_PROFILE"] == "1" {
                editingProfile = preferences.activeCloudProfile
            }
            #endif
        }
    }

    private var profileCard: some View {
        settingsCard {
            VStack(spacing: 0) {
                ForEach(preferences.cloudProfiles) { row in
                    if row.id != preferences.cloudProfiles.first?.id {
                        settingsRowDivider
                    }
                    profileRow(row)
                }

                settingsRowDivider

                HStack(spacing: 8) {
                    newProfileMenu

                    Spacer(minLength: 8)

                    if activeProfile.status != .ready {
                        Text(tr("complete_the_provider_to_test"))
                            .font(LightAnchorTheme.supportingFont(size: 11))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 5) {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isTestingConnection ? tr("testing") : tr("test_connection"))
                        }
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                    .disabled(isTestingConnection || activeProfile.status != .ready)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                if let message {
                    Text(message)
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(messageIsError ? LightAnchorTheme.error : LightAnchorTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    /// 一行一套方案：点行主体切换（单一职责），行尾「编辑」开弹窗。
    private func profileRow(_ row: CloudProviderProfile) -> some View {
        let isActive = row.id == preferences.activeCloudProfileID
        return HStack(spacing: 10) {
            Button {
                switchTo(row)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(isActive ? LightAnchorTheme.accentInk : LightAnchorTheme.elevatedSurface)
                        Circle()
                            .strokeBorder(
                                isActive
                                    ? LightAnchorTheme.accentInk.opacity(0.45)
                                    : LightAnchorTheme.ink.opacity(0.16),
                                lineWidth: 1
                            )
                        if isActive {
                            LightAnchorIcon("check", size: 11)
                                .foregroundStyle(LightAnchorTheme.onAction)
                        }
                    }
                    .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name.isEmpty ? tr("unnamed_provider") : row.name)
                            .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                            .foregroundStyle(LightAnchorTheme.ink)
                        Text(row.summary)
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }

                    Spacer(minLength: 12)

                    if row.status != .ready {
                        HStack(spacing: 5) {
                            LightAnchorIcon("info", size: 13)
                            Text(shortStatus(row.status))
                                .font(LightAnchorTheme.supportingFont(size: 11.5))
                        }
                        .foregroundStyle(LightAnchorTheme.warning)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Button(tr("edit")) {
                editingProfile = row
            }
            .buttonStyle(LightAnchorInlineButtonStyle())
            .accessibilityLabel(String(format: tr("edit_provider_named"), row.name))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? LightAnchorTheme.accentWash : LightAnchorThemeColor.clear)
    }

    /// 新建按服务开一套填好的空方案，复制则连 Key 一起带走
    /// （同一家换个模型是最常见的第二套）。两种都建完即开编辑弹窗。
    private var newProfileMenu: some View {
        Menu {
            ForEach(CloudServicePreset.allCases) { preset in
                Button(preset.title) { addProfile(provider: preset) }
            }
            Divider()
            Button(tr("duplicate_provider")) { duplicateProfile() }
        } label: {
            HStack(spacing: 5) {
                LightAnchorIcon("plus", size: 13)
                Text(tr("add_provider"))
            }
        }
        .menuStyle(.button)
        .buttonStyle(LightAnchorInlineButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tr("add_provider"))
    }

    private func shortStatus(_ status: CloudConfigurationStatus) -> String {
        switch status {
        case .ready: tr("cloud_configuration_ready")
        case .invalidEndpoint: tr("invalid_endpoint")
        case .missingModel: tr("model_missing")
        }
    }

    // MARK: - 方案操作

    /// 菜单动作是带动画事务跑的：清单插一行时，新行和被推开的旧行会在
    /// 同一帧里交叠淡入——看上去就是两行文字叠在一起。清单的增删改一律
    /// 不做动画：一行就是一整块文字，位移过程中必然重叠，没有好看的中间态。
    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func switchTo(_ row: CloudProviderProfile) {
        guard row.id != preferences.activeCloudProfileID else { return }
        withoutAnimation {
            preferences.selectCloudProfile(id: row.id)
            messageIsError = false
            message = String(format: tr("switched_to"), row.name)
        }
        onSave()
    }

    private func addProfile(provider: CloudServicePreset) {
        var id = UUID()
        withoutAnimation {
            id = preferences.addCloudProfile(provider: provider)
            message = nil
        }
        onSave()
        openEditorSoon(for: id)
    }

    private func duplicateProfile() {
        var id = UUID()
        withoutAnimation {
            id = preferences.duplicateActiveCloudProfile()
            message = nil
        }
        onSave()
        openEditorSoon(for: id)
    }

    /// 从菜单动作里同帧开 sheet 会和菜单收起、清单插行两个动画打架
    /// （弹窗闪跳）。推迟一拍，等这一帧的界面更新落定再弹。
    private func openEditorSoon(for id: UUID) {
        DispatchQueue.main.async {
            editingProfile = preferences.cloudProfiles.first { $0.id == id }
        }
    }

    private func commitEdited(_ profile: CloudProviderProfile) {
        guard let index = preferences.cloudProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        withoutAnimation {
            preferences.cloudProfiles[index] = profile
            message = nil
        }
        onSave()
    }

    private func deleteProfile(id: UUID) {
        withoutAnimation {
            preferences.removeCloudProfile(id: id)
            message = nil
        }
        onSave()
    }

    private func testConnection() async {
        let profile = activeProfile
        isTestingConnection = true
        message = nil
        defer { isTestingConnection = false }

        let engine = CloudIntelligenceEngine(
            apiKey: profile.apiKey,
            endpoint: profile.chatEndpoint,
            model: profile.model,
            apiProtocol: profile.apiProtocol
        )
        do {
            let seconds = try await engine.testConnection()
            messageIsError = false
            message = String(format: tr("connected_responded_in_s"), profile.model, seconds)
        } catch {
            messageIsError = true
            message = String(format: tr("test_failed"), error.localizedDescription)
        }
    }
}

// MARK: - 方案编辑弹窗
//
// 草稿式编辑：改的是副本，「保存」才写回，取消不留痕。
// 「连接并获取模型」「测试连接」都用草稿里的值——先验证再保存。
private struct CloudProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CloudProviderProfile
    @State private var discoveredModels: [String] = []
    @State private var isFetchingModels = false
    @State private var isTestingConnection = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmingDelete = false

    private let isOnlyProfile: Bool
    private let siblingNames: Set<String>
    private let onSave: (CloudProviderProfile) -> Void
    private let onDelete: () -> Void

    init(
        profile: CloudProviderProfile,
        isOnlyProfile: Bool,
        siblingNames: Set<String>,
        onSave: @escaping (CloudProviderProfile) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        self.isOnlyProfile = isOnlyProfile
        self.siblingNames = siblingNames
        self.onSave = onSave
        self.onDelete = onDelete
    }

    /// 模型输入框右缘的建议列表：拉到过就用真实列表，否则用推荐值。
    private var modelSuggestions: [String] {
        discoveredModels.isEmpty ? draft.provider.recommendedModels : discoveredModels
    }

    private var endpointPlaceholder: String {
        draft.provider.endpoint(for: draft.apiProtocol)
            ?? "https://your-service.example/v1/chat/completions"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LightAnchorSheetHeader(
                eyebrow: tr("cloud"),
                title: tr("edit_provider"),
                subtitle: tr("takes_effect_on_save"),
                icon: "cloud"
            )

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(tr("provider_name"))
                TextField(tr("name_this_provider"), text: $draft.name)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .accessibilityLabel(tr("provider_name"))
            }

            // 服务与协议并排：都是「选一下」的字段，摊两行只会把弹窗抻高。
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(tr("provider"))
                    LightAnchorSelectField(
                        tr("provider"),
                        selection: providerBinding,
                        options: CloudServicePreset.allCases,
                        titleForValue: { $0.title },
                        embedded: true
                    )
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(tr("protocol"))
                    LightAnchorSelectField(
                        tr("protocol"),
                        selection: protocolBinding,
                        options: draft.provider.supportedAPIProtocols,
                        titleForValue: { $0.title },
                        embedded: true
                    )
                }
            }

            Text(tr("the_protocol_decides_request_body_auth"))
                .font(LightAnchorTheme.supportingFont(size: 11))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("API Key")
                SecureField(tr("paste_the_provider_s_api_key"), text: apiKeyBinding)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .accessibilityLabel("API Key")
                Text(tr("api_key_may_be_left_empty"))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(tr("endpoint"))
                TextField(endpointPlaceholder, text: endpointBinding)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .accessibilityLabel(tr("endpoint"))
                Text(tr("enter_the_full_request_url_the"))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .fixedSize(horizontal: false, vertical: true)
                // 明文 http 发给非本机：Key 会裸着走网络，请求时会被拦下。
                // 这里先把话说清，别等到「测试连接」才报错。
                if CloudNetworkPolicy.isInsecureRemote(endpoint: draft.chatEndpoint) {
                    Text(tr("http_endpoint_to_remote_host_warning"))
                        .font(LightAnchorTheme.supportingFont(size: 11))
                        .foregroundStyle(LightAnchorTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(tr("http_endpoint_to_remote_host_warning"))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // 标签行只放标签，输入框独占整行——和上面几个字段一模一样，
                // 这一段不再显得比别的字段挤。
                fieldLabel(tr("model"))
                LightAnchorComboField(
                    tr("enter_a_model_id_or_pick"),
                    text: modelBinding,
                    suggestions: modelSuggestions
                )
                // 两个连接动作收成输入框下面靠右的一行小按钮：
                // 「获取模型列表」把结果灌进上面的 ⌄，「测试连接」验证整套配置。
                // 结果与报错固定占最后一行，成功失败都在同一个位置出现。
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack(spacing: 5) {
                            if isFetchingModels {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                LightAnchorIcon("refresh-cw", size: 12)
                            }
                            Text(isFetchingModels ? tr("fetching") : tr("connect_fetch_models"))
                        }
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    .disabled(isFetchingModels)
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 5) {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isTestingConnection ? tr("testing") : tr("test_connection"))
                        }
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                    .disabled(isTestingConnection || draft.status != .ready)
                }
                .padding(.top, 2)
            }

            if let message {
                Text(message)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(messageIsError ? LightAnchorTheme.error : LightAnchorTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.status != .ready {
                Text(shortStatusDetail)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }

            LightAnchorSheetActionBar(fillsWidth: true) {
                // 撑满整行，让删除钮贴住左缘——危险动作和确认动作
                // 分居两端是弹窗的惯例。
                HStack(spacing: 8) {
                    Button(tr("delete_provider"), role: .destructive) {
                        confirmingDelete = true
                    }
                    .buttonStyle(LightAnchorInlineButtonStyle(tint: LightAnchorTheme.dangerText))
                    .disabled(isOnlyProfile)
                    .confirmationDialog(
                        tr("delete_this_provider_question"),
                        isPresented: $confirmingDelete,
                        titleVisibility: .visible
                    ) {
                        Button(tr("delete_provider"), role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                        Button(tr("cancel"), role: .cancel) {}
                    } message: {
                        Text(tr("deleting_a_provider_cannot_be_undone"))
                    }

                    Spacer(minLength: 8)

                    Button(tr("cancel")) { dismiss() }
                        .buttonStyle(LightAnchorQuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(tr("save")) {
                        onSave(draft)
                        dismiss()
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 560)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
            .foregroundStyle(LightAnchorTheme.mutedInk)
    }

    private var shortStatusDetail: String {
        switch draft.status {
        case .ready: ""
        case .invalidEndpoint: tr("enter_a_full_endpoint_starting_with")
        case .missingModel: tr("enter_a_model_id_or_pick")
        }
    }

    // MARK: - 草稿字段

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { draft.apiKey },
            set: { value in
                message = nil
                draft.apiKey = value
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.model },
            set: { value in
                message = nil
                draft.model = value
            }
        )
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { draft.chatEndpoint },
            set: { value in
                discoveredModels = []
                message = nil
                draft.chatEndpoint = value
                // 端点被改成预设地址以外的样子，就是一套自定义服务了。
                let preset = draft.provider.endpoint(for: draft.apiProtocol)
                if preset.map(CloudConnectionConfiguration.normalize)
                    != CloudConnectionConfiguration.normalize(value) {
                    draft.provider = .custom
                }
            }
        )
    }

    private var providerBinding: Binding<CloudServicePreset> {
        Binding(
            get: { draft.provider },
            set: { provider in
                discoveredModels = []
                message = nil
                // 名字还是自动名（用户没改过）时跟着换服务，
                // 免得清单里挂着「OpenAI」却连着别家。
                let autoNamed = draft.name
                    == CloudProviderProfile.defaultName(provider: draft.provider)
                draft.provider = provider
                draft.apiProtocol = provider.defaultAPIProtocol
                if let endpoint = provider.endpoint(for: draft.apiProtocol) {
                    draft.chatEndpoint = endpoint
                }
                if provider != .custom {
                    // 上一家服务的模型 ID 对新服务没有意义，一并换掉；
                    // 本地服务（defaultModel 为空）连上后再从列表里选。
                    draft.model = provider.defaultModel ?? ""
                }
                if autoNamed {
                    draft.name = CloudProviderProfile.uniqueName(
                        base: CloudProviderProfile.defaultName(provider: provider),
                        existingNames: siblingNames
                    )
                }
            }
        )
    }

    private var protocolBinding: Binding<CloudAPIProtocol> {
        Binding(
            get: { draft.apiProtocol },
            set: { apiProtocol in
                discoveredModels = []
                message = nil
                draft.apiProtocol = apiProtocol
                if draft.provider != .custom,
                   let endpoint = draft.provider.endpoint(for: apiProtocol) {
                    draft.chatEndpoint = endpoint
                }
            }
        )
    }

    // MARK: - 连接动作

    private func testConnection() async {
        isTestingConnection = true
        message = nil
        defer { isTestingConnection = false }

        let engine = CloudIntelligenceEngine(
            apiKey: draft.apiKey,
            endpoint: draft.chatEndpoint,
            model: draft.model,
            apiProtocol: draft.apiProtocol
        )
        do {
            let seconds = try await engine.testConnection()
            messageIsError = false
            message = String(format: tr("connected_responded_in_s"), draft.model, seconds)
        } catch {
            messageIsError = true
            message = String(format: tr("test_failed"), error.localizedDescription)
        }
    }

    private func fetchModels() async {
        let connection = draft.connection
        guard connection.modelsURL != nil else {
            messageIsError = true
            message = connection.status == .invalidEndpoint
                ? tr("enter_a_full_endpoint_starting_with")
                : tr("couldn_t_derive_a_model_list")
            return
        }

        isFetchingModels = true
        message = nil
        defer { isFetchingModels = false }

        do {
            // Key 为空也照发：免鉴权的网关/本地服务同样能列模型。
            let models = try await CloudModelCatalog().fetchModels(
                apiKey: connection.apiKey,
                endpoint: connection.normalizedModelsEndpoint,
                apiProtocol: draft.apiProtocol
            )
            discoveredModels = models
            // 只在模型框为空时代填第一个；用户手输的 ID 不动——
            // 列表接口不一定枚举服务支持的所有模型。
            if draft.model.isEmpty, let first = models.first {
                draft.model = first
            }
            messageIsError = false
            message = String(
                format: models.count == 1
                    ? tr("connected_found_available_models_one")
                    : tr("connected_found_available_models"),
                models.count
            )
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }
}

// MARK: - 自然语言建规则
