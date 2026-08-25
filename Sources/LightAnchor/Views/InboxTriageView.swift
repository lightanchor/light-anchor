import SwiftUI

/// 收件箱清理台：智能引擎逐条提议去向，用户勾选后一次应用。
/// 只提议，不代办——没勾选的一条也不动。
struct InboxTriageSheet: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss

    @State private var proposals: [InboxTriageProposal] = []
    @State private var summaries: [UUID: InboxTriageItem] = [:]
    @State private var included: Set<UUID> = []
    @State private var isLoading = true
    @State private var isApplying = false

    private var actionableProposals: [InboxTriageProposal] {
        proposals.filter { $0.action != .keep }
    }

    private var selectedCount: Int {
        actionableProposals.filter { included.contains($0.captureID) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("inbox"),
                title: tr("ai_tidy_up"),
                subtitle: tr("proposals_item_by_item_only_checked"),
                icon: "tray"
            )

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(tr("reading_inbox"))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if proposals.isEmpty {
                LightAnchorEmptyState(
                    title: tr("inbox_is_empty"),
                    detail: tr("nothing_to_tidy_up")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(proposals) { proposal in
                            proposalRow(proposal)
                            if proposal.captureID != proposals.last?.captureID {
                                LightAnchorRowSeparator()
                            }
                        }
                    }
                    .background(
                        LightAnchorTheme.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
                    }
                }
            }

            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(selectedCount > 0
                       ? String(
                           format: selectedCount == 1 ? tr("apply_n_items_one") : tr("apply_n_items"),
                           selectedCount
                       )
                       // 原来借了 "apps"（应用程序）当动词，英文渲染成名词 "Apps"。
                       : tr("apply_verb")) {
                    apply()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(isLoading || isApplying || selectedCount == 0)
            }
        }
        .padding(24)
        .frame(width: 600, height: 540)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .onAppear { load() }
    }

    // MARK: - 行

    private func proposalRow(_ proposal: InboxTriageProposal) -> some View {
        let item = summaries[proposal.captureID]
        let needsEpisode = proposal.action == .convertToWaiting && workspace.currentEpisode == nil
        let isActionable = proposal.action != .keep && !needsEpisode
        return HStack(alignment: .center, spacing: 12) {
            checkbox(for: proposal, isActionable: isActionable)

            VStack(alignment: .leading, spacing: 3) {
                Text(item?.summary ?? "")
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(1)
                Text(metaLine(for: proposal, item: item, needsEpisode: needsEpisode))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(proposal.action.title)
                .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                .foregroundStyle(chipInk(for: proposal.action))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    LightAnchorTheme.recessed,
                    in: Capsule(style: .continuous)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(proposal.action == .keep ? 0.62 : 1)
    }

    private func checkbox(for proposal: InboxTriageProposal, isActionable: Bool) -> some View {
        let isOn = included.contains(proposal.captureID) && isActionable
        return Button {
            guard isActionable else { return }
            if isOn {
                included.remove(proposal.captureID)
            } else {
                included.insert(proposal.captureID)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? LightAnchorTheme.accentInk : LightAnchorTheme.elevatedSurface)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isOn
                            ? LightAnchorTheme.accentInk.opacity(0.45)
                            : LightAnchorTheme.ink.opacity(0.13),
                        lineWidth: 1
                    )
                if isOn {
                    LightAnchorIcon("check", size: 11)
                        .foregroundStyle(LightAnchorTheme.onAction)
                }
            }
            .frame(width: 18, height: 18)
            // 可见勾选框保持 18pt，命中区外扩到 26pt（底线 24pt）。
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .opacity(isActionable ? 1 : 0.35)
        .accessibilityLabel(tr("apply_this_suggestion"))
        // 勾选状态只画不说，旁白核对不了勾了哪些，点「应用 N 项」等于盲签。
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func metaLine(
        for proposal: InboxTriageProposal,
        item: InboxTriageItem?,
        needsEpisode: Bool
    ) -> String {
        var parts: [String] = []
        if let item {
            parts.append(item.kind.title)
            parts.append(
                item.ageDays == 0
                    ? tr("today")
                    : String(format: tr("n_days_ago"), item.ageDays)
            )
        }
        if !proposal.reason.isEmpty {
            parts.append(proposal.reason)
        }
        if needsEpisode {
            parts.append(tr("needs_a_current_task_before_converting"))
        }
        return parts.joined(separator: " · ")
    }

    private func chipInk(for action: InboxTriageAction) -> LightAnchorThemeColor {
        switch action {
        case .startTarget: LightAnchorTheme.accentInk
        case .convertToWaiting: LightAnchorTheme.warning
        case .saveReference: LightAnchorTheme.ink
        case .archive: LightAnchorTheme.mutedInk
        case .keep: LightAnchorTheme.faintInk
        }
    }

    // MARK: - 数据

    private func load() {
        let items = workspace.makeInboxTriageItems()
        summaries = Dictionary(uniqueKeysWithValues: items.map { ($0.captureID, $0) })
        guard !items.isEmpty else {
            isLoading = false
            return
        }
        let engine = workspace.intelligenceEngine
        let recentTargets = workspace.recentTargetNames
        Task { @MainActor in
            let result = await engine.triageInbox(items: items, recentTargets: recentTargets)
            // 引擎必须与输入一一对应；不满足就退回启发式（不猜去向，一律「先留着」）。
            if result.count == items.count {
                proposals = result
            } else {
                proposals = await HeuristicIntelligenceEngine()
                    .triageInbox(items: items, recentTargets: recentTargets)
            }
            let hasEpisode = workspace.currentEpisode != nil
            included = Set(
                proposals
                    .filter { $0.action != .keep }
                    .filter { hasEpisode || $0.action != .convertToWaiting }
                    .map(\.captureID)
            )
            isLoading = false
        }
    }

    private func apply() {
        isApplying = true
        let accepted = actionableProposals.filter { included.contains($0.captureID) }
        let outcome = workspace.applyInboxTriageProposals(accepted)
        dismiss()
        var message = String(
            format: outcome.applied == 1
                ? tr("applied_n_triage_suggestions_one") : tr("applied_n_triage_suggestions"),
            outcome.applied
        )
        if outcome.skipped > 0 {
            message += String(
                format: outcome.skipped == 1
                    ? tr("another_n_items_couldn_t_be_applied_one")
                    : tr("another_n_items_couldn_t_be_applied"),
                outcome.skipped
            )
        }
        workspace.presentNotice(message)
    }
}
