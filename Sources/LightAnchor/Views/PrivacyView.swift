import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct PrivacyView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var statuses: [PrivacyCapability: PrivacyPermissionStatus] = [:]
    @State private var capturePreferences = SceneCapturePreferences()
    @State private var newWebsiteHost = ""
    @State private var pendingClearScope: SceneHistoryClearScope?

    private let service = PrivacyPermissionService()

    var body: some View {
        // 样机 setbody：组标签 + 白卡行式，与外观页同一套组件。
        // 导出/删除数据的入口只留在「数据」页，这里不再重复。
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupLabel(tr("capabilities"))
                settingsCard {
                    VStack(spacing: 0) {
                        ForEach(PrivacyCapability.allCases) { capability in
                            settingsRow(
                                title: capability.title,
                                detail: detail(for: capability)
                            ) {
                                Text(statuses[capability]?.title ?? tr("checking"))
                                    .font(LightAnchorTheme.interfaceFont(size: 12, weight: .medium))
                                    .foregroundStyle(statusColor(statuses[capability]))
                                if shouldShowGrant(for: statuses[capability]) {
                                    Button(grantButtonTitle(for: statuses[capability])) {
                                        Task {
                                            statuses[capability] = await service.request(capability)
                                        }
                                    }
                                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                                }
                                #if os(macOS)
                                if let settingsURL = capability.systemSettingsURL,
                                   shouldShowSettings(for: statuses[capability]) {
                                    Button(tr("open_system_settings")) {
                                        NSWorkspace.shared.open(settingsURL)
                                    }
                                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                                }
                                #endif
                            }
                            if capability != PrivacyCapability.allCases.last {
                                settingsRowDivider
                            }
                        }
                    }
                }

                settingsGroupLabel(tr("scene_snapshots_intelligence"))
                settingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("when_you_switch_wait_or_pause"))
                        Text(tr("the_on_device_engine_keeps_content"))
                    }
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }

                settingsGroupLabel(tr("automatic_scene_capture"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            title: tr("pause_automatic_scene_capture"),
                            detail: tr("stops_automatic_capture_when_switching_pausing")
                        ) {
                            Toggle("", isOn: automaticCapturePausedBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel(tr("pause_automatic_scene_capture"))
                        }
                        settingsRowDivider
                        settingsRow(
                            title: tr("app_source_rule"),
                            detail: tr("applied_before_window_and_terminal_facts")
                        ) {
                            LightAnchorSelectField(
                                tr("app_source_rule"),
                                selection: applicationRuleBinding,
                                options: SceneSourceRuleMode.allCases,
                                titleForValue: { $0.title },
                                embedded: true
                            )
                        }
                        settingsRowDivider
                        applicationListRow
                        settingsRowDivider
                        settingsRow(
                            title: tr("website_source_rule"),
                            detail: tr("domain_rules_also_match_subdomains")
                        ) {
                            LightAnchorSelectField(
                                tr("website_source_rule"),
                                selection: websiteRuleBinding,
                                options: SceneSourceRuleMode.allCases,
                                titleForValue: { $0.title },
                                embedded: true
                            )
                        }
                        settingsRowDivider
                        websiteListRow
                    }
                }

                settingsGroupLabel(tr("clear_scene_history"))
                settingsCard {
                    settingsRow(
                        title: tr("clear_recent_scenes"),
                        detail: tr("removes_files_webpages_apps_terminal_context")
                    ) {
                        Menu {
                            Button(tr("clear_the_last_hour"), role: .destructive) {
                                pendingClearScope = .lastHour
                            }
                            Button(tr("clear_all_scene_history"), role: .destructive) {
                                pendingClearScope = .all
                            }
                        } label: {
                            Text(tr("choose_range"))
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .accessibilityLabel(tr("choose_the_scene_history_range_to"))
                    }
                }

                Text(tr("statuses_refresh_while_this_page_is_open"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .task {
            syncCapturePreferences()
            await refreshStatuses()
            await watchSystemSettingsGrants()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshStatuses() }
        }
        .confirmationDialog(
            pendingClearScope?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { pendingClearScope != nil },
                set: { if !$0 { pendingClearScope = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let scope = pendingClearScope {
                Button(scope.actionTitle, role: .destructive) { clearSceneHistory(scope) }
            }
            Button(UserFacingCopy.cancel, role: .cancel) { pendingClearScope = nil }
        } message: {
            Text(tr("this_permanently_removes_scene_facts_from"))
        }
    }

    private enum SceneHistoryClearScope: String, Identifiable {
        case lastHour
        case all

        var id: String { rawValue }
        var confirmationTitle: String {
            switch self {
            case .lastHour: tr("clear_scene_history_from_the_last")
            case .all: tr("clear_all_scene_history_2")
            }
        }
        var actionTitle: String {
            switch self {
            case .lastHour: tr("clear_the_last_hour")
            case .all: tr("clear_all_scene_history")
            }
        }
    }

    private var automaticCapturePausedBinding: Binding<Bool> {
        Binding(
            get: { capturePreferences.isAutomaticCapturePaused },
            set: {
                capturePreferences.isAutomaticCapturePaused = $0
                saveCapturePreferences()
            }
        )
    }

    private var applicationRuleBinding: Binding<SceneSourceRuleMode> {
        Binding(
            get: { capturePreferences.applicationRuleMode },
            set: {
                capturePreferences.applicationRuleMode = $0
                saveCapturePreferences()
            }
        )
    }

    private var websiteRuleBinding: Binding<SceneSourceRuleMode> {
        Binding(
            get: { capturePreferences.websiteRuleMode },
            set: {
                capturePreferences.websiteRuleMode = $0
                saveCapturePreferences()
            }
        )
    }

    // MARK: - 应用清单（Mos 式：挑应用，不填 Bundle ID）

    private struct ListedApplication: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let isInstalled: Bool
    }

    private struct RunningApplicationCandidate: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private var listedApplications: [ListedApplication] {
        capturePreferences.applicationBundleIdentifiers.sorted().map { bundleID in
            #if os(macOS)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return ListedApplication(
                    id: bundleID,
                    name: applicationDisplayName(at: url),
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    isInstalled: true
                )
            }
            #endif
            // 已卸载的应用没有图标和名字，如实标出来而不是悄悄丢掉规则。
            return ListedApplication(id: bundleID, name: bundleID, icon: nil, isInstalled: false)
        }
    }

    /// 「添加应用」菜单的主菜品：正在运行的普通应用（这正是用户此刻
    /// 想排除的那个），已在清单里的不再重复出现。
    private var runningApplicationCandidates: [RunningApplicationCandidate] {
        #if os(macOS)
        let listed = capturePreferences.applicationBundleIdentifiers
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application -> RunningApplicationCandidate? in
                guard let bundleID = application.bundleIdentifier?.lowercased(),
                      let name = application.localizedName,
                      bundleID != Bundle.main.bundleIdentifier?.lowercased(),
                      !listed.contains(bundleID),
                      seen.insert(bundleID).inserted else { return nil }
                return RunningApplicationCandidate(
                    id: bundleID,
                    name: name,
                    icon: application.icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        #else
        return []
        #endif
    }

    private var applicationListRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("listed_apps"))
                        .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                        .foregroundStyle(LightAnchorTheme.ink)
                    Text(tr("pick_from_running_apps_or_finder"))
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }
                Spacer(minLength: 14)
                addApplicationMenu
            }
            if listedApplications.isEmpty {
                Text(tr("no_apps_listed_yet"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            } else {
                VStack(spacing: 4) {
                    ForEach(listedApplications) { entry in
                        sourceListRow(
                            name: entry.name,
                            detail: entry.isInstalled
                                ? entry.id
                                : tr("app_selected_not_currently_installed"),
                            removeLabel: String(format: tr("remove_app"), entry.name)
                        ) {
                            removeApplication(entry.id)
                        } icon: {
                            if let icon = entry.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                            } else {
                                LightAnchorIcon("app-window", size: 16)
                                    .foregroundStyle(LightAnchorTheme.iconSubtle)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var addApplicationMenu: some View {
        Menu {
            ForEach(runningApplicationCandidates) { candidate in
                Button {
                    addApplication(candidate.id)
                } label: {
                    if let icon = menuSizedIcon(candidate.icon) {
                        Label {
                            Text(candidate.name)
                        } icon: {
                            Image(nsImage: icon)
                        }
                    } else {
                        Text(candidate.name)
                    }
                }
            }
            if !runningApplicationCandidates.isEmpty {
                Divider()
            }
            Button(tr("choose_from_finder")) { chooseApplicationsFromFinder() }
        } label: {
            HStack(spacing: 5) {
                LightAnchorIcon("plus", size: 13)
                Text(tr("add_app"))
            }
        }
        .menuStyle(.button)
        .buttonStyle(LightAnchorInlineButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tr("add_app"))
    }

    /// 菜单行的图标要 16pt 版本；直接用原图会按 32pt 原尺寸撑大菜单行。
    private func menuSizedIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon, let copy = icon.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func applicationDisplayName(at url: URL) -> String {
        #if os(macOS)
        if let displayName = Bundle(url: url)?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        let fileDisplayName = FileManager.default.displayName(atPath: url.path)
        if !fileDisplayName.isEmpty {
            return fileDisplayName.hasSuffix(".app")
                ? String(fileDisplayName.dropLast(4))
                : fileDisplayName
        }
        #endif
        return url.deletingPathExtension().lastPathComponent
    }

    private func addApplication(_ bundleID: String) {
        capturePreferences.applicationBundleIdentifiers.insert(bundleID)
        saveCapturePreferences()
    }

    private func removeApplication(_ bundleID: String) {
        capturePreferences.applicationBundleIdentifiers.remove(bundleID)
        saveCapturePreferences()
    }

    private func chooseApplicationsFromFinder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK else { return }
        let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !bundleIDs.isEmpty else { return }
        capturePreferences.applicationBundleIdentifiers.formUnion(bundleIDs)
        saveCapturePreferences()
        #endif
    }

    // MARK: - 网站清单

    private var websiteListRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("listed_websites"))
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                Text(tr("enter_a_domain_or_paste"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            }
            if capturePreferences.websiteHosts.isEmpty {
                Text(tr("no_websites_listed_yet"))
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            } else {
                VStack(spacing: 4) {
                    ForEach(capturePreferences.websiteHosts.sorted(), id: \.self) { host in
                        sourceListRow(
                            name: host,
                            detail: nil,
                            removeLabel: String(format: tr("remove_website"), host)
                        ) {
                            removeWebsiteHost(host)
                        } icon: {
                            LightAnchorIcon("globe", size: 15)
                                .foregroundStyle(LightAnchorTheme.iconSubtle)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("example.com", text: $newWebsiteHost)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                    .onSubmit { addWebsiteHost() }
                    .accessibilityLabel(tr("listed_websites"))
                Button(tr("add")) { addWebsiteHost() }
                    .buttonStyle(LightAnchorInlineButtonStyle())
                    .disabled(
                        newWebsiteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func addWebsiteHost() {
        let host = newWebsiteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        // 归一化交给偏好模型：粘贴整条网址也能落成裸域名。
        capturePreferences.websiteHosts.insert(host)
        saveCapturePreferences()
        newWebsiteHost = ""
    }

    private func removeWebsiteHost(_ host: String) {
        capturePreferences.websiteHosts.remove(host)
        saveCapturePreferences()
    }

    /// 清单里的一行：图标 + 名字（+ 说明）+ 右缘移除钮。
    private func sourceListRow(
        name: String,
        detail: String?,
        removeLabel: String,
        onRemove: @escaping () -> Void,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(name)
                .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
                .foregroundStyle(LightAnchorTheme.ink)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                LightAnchorIcon("x", size: 12)
            }
            .buttonStyle(LightAnchorInlineButtonStyle())
            .accessibilityLabel(removeLabel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            LightAnchorTheme.recessed,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func syncCapturePreferences() {
        capturePreferences = workspace.sceneCapturePreferences
    }

    private func saveCapturePreferences() {
        capturePreferences = capturePreferences.normalized()
        workspace.updateSceneCapturePreferences(capturePreferences)
    }

    private func clearSceneHistory(_ scope: SceneHistoryClearScope) {
        pendingClearScope = nil
        let cutoff: Date? = scope == .lastHour ? Date().addingTimeInterval(-3600) : nil
        guard let result = workspace.clearSceneHistory(capturedSince: cutoff) else { return }
        if result.totalRecordCount == 0 {
            workspace.presentNotice(tr("there_is_no_scene_history_in"))
        } else {
            workspace.presentNotice(
                String(
                    format: result.sceneSnapshotCount == 1
                        ? tr("cleared_n_scenes_focus_ledger_kept_one")
                        : tr("cleared_n_scenes_focus_ledger_kept"),
                    result.sceneSnapshotCount
                )
            )
        }
    }

    private func refreshStatuses() async {
        for capability in PrivacyCapability.allCases {
            statuses[capability] = await service.statusAsync(for: capability)
        }
    }

    /// 辅助功能和屏幕录制是在系统设置里拨的开关，系统不回调应用。页面开着时
    /// 按秒复查，用户拨完开关切回来就能看到「已授权」，不用再点一次。
    /// `.task` 会在页面消失时取消这个循环。
    private func watchSystemSettingsGrants() async {
        let watched = PrivacyCapability.allCases.filter(\.isGrantedInSystemSettings)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            for capability in watched {
                let status = service.status(for: capability)
                if statuses[capability] != status {
                    statuses[capability] = status
                }
            }
        }
    }

    /// 说明文字后面接一句当下最要紧的提示：等系统设置时该去哪、拨完还要做什么。
    private func detail(for capability: PrivacyCapability) -> String {
        guard statuses[capability] == .awaitingSystemSettings else {
            return capability.explanation
        }
        var lines = [capability.explanation, tr("flip_the_switch_in_system_settings")]
        if capability.requiresRelaunchAfterGrant {
            lines.append(tr("this_one_takes_effect_after_you_relaunch"))
        }
        #if os(macOS)
        // ad-hoc / 裸可执行文件每次重新构建签名都变，系统设置里那条旧授权
        // 会留着却对不上新包：不说清楚，用户会以为是应用坏了。
        if capability == .accessibility, AppSignatureFacts.grantsMayNotStick {
            lines.append(tr("this_build_is_ad_hoc_signed_remove_and_re_add"))
        }
        #endif
        return lines.joined(separator: "\n")
    }

    private func statusColor(_ status: PrivacyPermissionStatus?) -> LightAnchorThemeColor {
        switch status {
        // 已授权是「就绪/完成」态，用宜绿文字档；蓝色留给链接与进行中。
        case .granted: LightAnchorTheme.success
        case .denied, .restricted: LightAnchorTheme.dangerText
        // 等系统设置不是坏事，只是没到——用提醒色，不用报错的红。
        case .awaitingSystemSettings: LightAnchorTheme.warning
        case .notDetermined, .none: LightAnchorTheme.mutedInk
        case .unavailable: LightAnchorTheme.warning
        }
    }

    /// 还能自己发起的才给按钮。已拒绝 / 受限只能去系统设置，再弹一次也没用。
    private func shouldShowGrant(for status: PrivacyPermissionStatus?) -> Bool {
        status == .notDetermined || status == .awaitingSystemSettings
    }

    private func grantButtonTitle(for status: PrivacyPermissionStatus?) -> String {
        status == .awaitingSystemSettings ? tr("system_settings") : tr("grant")
    }

    private func shouldShowSettings(for status: PrivacyPermissionStatus?) -> Bool {
        status == .denied || status == .restricted
    }
}

struct JSONDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
