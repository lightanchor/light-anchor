import SwiftUI

/// 设置 → 更新：签名更新清单的检查开关与手动检查。
struct UpdateSettingsView: View {
    @AppStorage("lightanchor.updateChecksEnabled") private var updateChecksEnabled = false
    @AppStorage("lightanchor.updateManifestURL") private var updateManifestURL = ""
    @AppStorage("lightanchor.updatePublicKeyPath") private var updatePublicKeyPath = ""
    @AppStorage("lightanchor.updateLastCheckedAt") private var updateLastCheckedAt = 0.0
    @State private var updateMessage = ""
    @State private var isCheckingUpdate = false

    // 信任锚随构建内置时（正式包），公钥路径字段既不显示也不参与验证；
    // 只有没有内置公钥的开发构建才保留路径字段作为开发者退路。
    private let embeddedPublicKeyData = ReleaseTrust.embeddedPublicKeyData
    private var usesEmbeddedPublicKey: Bool { embeddedPublicKeyData != nil }
    // 写死的正式清单地址一旦定下，就不再让用户改地址。
    private var usesDefaultManifestURL: Bool { ReleaseTrust.defaultManifestURL != nil }

    var body: some View {
        // 样机 setbody：组标签 + 白卡行式，与外观页同一套组件。
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupLabel(tr("updates"))
                settingsCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            title: tr("check_for_signed_updates_periodically"),
                            detail: usesEmbeddedPublicKey
                                ? tr("only_signed_manifests_are_accepted_key_built_in")
                                : tr("only_signed_manifests_are_accepted_you")
                        ) {
                            Toggle("", isOn: $updateChecksEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(tr("check_for_signed_updates_periodically"))
                        }
                        if updateChecksEnabled {
                            if !usesDefaultManifestURL || !usesEmbeddedPublicKey {
                                VStack(spacing: 8) {
                                    if !usesDefaultManifestURL {
                                        TextField(tr("https_url_of_the_update_manifest"), text: $updateManifestURL)
                                            .textFieldStyle(LightAnchorTextFieldStyle())
                                    }
                                    if !usesEmbeddedPublicKey {
                                        TextField(tr("rsa_public_key_file_path"), text: $updatePublicKeyPath)
                                            .textFieldStyle(LightAnchorTextFieldStyle())
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.bottom, 13)
                            }
                            settingsRowDivider
                            settingsRow(
                                title: updateMessage.isEmpty ? tr("manual_check") : updateMessage,
                                detail: nil
                            ) {
                                Button(isCheckingUpdate ? tr("checking") : tr("check_for_updates_now")) {
                                    checkForUpdate(force: true)
                                }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                                .disabled(isCheckingUpdate)
                            }
                        }
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 26, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .task {
            checkForUpdate(force: false)
        }
    }

    private func checkForUpdate(force: Bool) {
        guard updateChecksEnabled else { return }
        // 内置信任锚优先：有内置公钥时无视用户填写的路径；写死的正式地址优先于用户地址。
        let embeddedKeyURL = ReleaseTrust.embeddedPublicKeyURL
        let publicKeyURL = embeddedPublicKeyData != nil
            ? embeddedKeyURL
            : (updatePublicKeyPath.isEmpty ? nil : URL(fileURLWithPath: updatePublicKeyPath))
        let schedule = ReleaseUpdateSchedule(
            enabled: true,
            manifestURL: ReleaseTrust.defaultManifestURL ?? URL(string: updateManifestURL),
            publicKeyURL: publicKeyURL,
            lastCheckedAt: updateLastCheckedAt == 0
                ? nil
                : Date(timeIntervalSince1970: updateLastCheckedAt)
        )
        guard force || schedule.shouldCheck() else { return }
        guard let manifestURL = schedule.manifestURL,
              let publicKeyURL = schedule.publicKeyURL
        else {
            updateMessage = usesEmbeddedPublicKey
                ? tr("enter_the_update_url")
                : tr("enter_the_update_url_and_rsa")
            return
        }
        guard let publicKeyData = embeddedPublicKeyData
            ?? (try? Data(contentsOf: publicKeyURL))
        else {
            updateMessage = tr("couldn_t_read_the_rsa_public")
            return
        }

        isCheckingUpdate = true
        let checker = ReleaseUpdateChecker()
        Task.detached {
            do {
                let result = try checker.check(
                    manifestURL: manifestURL,
                    publicKeyData: publicKeyData
                )
                await MainActor.run {
                    updateLastCheckedAt = result.checkedAt.timeIntervalSince1970
                    updateMessage = result.isNewer
                        ? String(
                            format: tr("found_a_new_version"),
                            result.manifest.version,
                            result.manifest.build
                          )
                        : tr("already_up_to_date")
                    isCheckingUpdate = false
                }
            } catch {
                await MainActor.run {
                    updateLastCheckedAt = Date().timeIntervalSince1970
                    updateMessage = error.localizedDescription
                    isCheckingUpdate = false
                }
            }
        }
    }

}
