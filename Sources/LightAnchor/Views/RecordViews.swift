import SwiftUI
import AppKit

// MARK: - 过程记录（回顾页区块 + 详情）
//
// 记录不是人写的：这里列出的每一份都是软件对一段过程的自动留痕。
// 详情里能看到完整 trace（时间 + 动作），并让引擎生成两种成稿：
// 给人看的复盘文档 / 给 AI 执行的 SKILL.md，可复制、可导出。

struct RecordingReviewSection: View {
    @EnvironmentObject private var workspace: AttentionWorkspace

    @State private var detailContext: RecordingDetailContext?

    private var sessions: [RecordingSession] {
        workspace.snapshot.allRecordingSessions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                LightAnchorSectionLabel(tr("records"))
                Spacer(minLength: 12)
                if workspace.activeRecordingSession == nil {
                    Button(tr("record_a_process")) {
                        _ = workspace.startManualRecording()
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                }
            }
            .padding(.bottom, 14)

            if sessions.isEmpty {
                LightAnchorInfoStrip(
                    title: tr("no_records_yet"),
                    detail: tr("recording_section_intro"),
                    icon: "file-text"
                )
            } else {
                LightAnchorListPanel {
                    ForEach(sessions) { session in
                        RecordingRow(session: session) {
                            detailContext = RecordingDetailContext(sessionID: session.id)
                        }
                        .environmentObject(workspace)
                        if session.id != sessions.last?.id {
                            LightAnchorRowSeparator()
                        }
                    }
                }
            }
        }
        .sheet(item: $detailContext) { context in
            RecordingDetailView(sessionID: context.sessionID)
                .environmentObject(workspace)
        }
    }
}

private struct RecordingDetailContext: Identifiable {
    let sessionID: UUID

    var id: UUID { sessionID }
}

private struct RecordingRow: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let session: RecordingSession
    let onOpenDetail: () -> Void

    private var metaLine: String {
        var parts: [String] = []
        switch session.status {
        case .recording: parts.append(tr("recording_now"))
        case .paused: parts.append(tr("recording_paused"))
        case .finished:
            parts.append(lightAnchorFriendlyDateTime(session.startedAt))
            parts.append(String(format: tr("n_trace_entries"), session.entryCount))
        }
        if !session.markdown.isEmpty {
            parts.append(session.style.title)
        }
        if !session.composedBy.isEmpty {
            parts.append(String(format: tr("composed_by_engine"), session.composedBy))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if session.isActive {
                // 在录指示：红点常亮，一眼可见。
                Circle()
                    .fill(LightAnchorDesign.danger)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(tr("recording_now"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? tr("untitled_record") : session.title)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine)
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 14)

            HStack(spacing: 6) {
                if session.isActive {
                    Button(tr("stop_process_recording")) {
                        _ = workspace.stopRecording()
                    }
                    .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                }
                Button(tr("recording_detail")) { onOpenDetail() }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                Button(UserFacingCopy.delete, role: .destructive) {
                    _ = workspace.deleteRecordingSession(session.id)
                }
                .buttonStyle(LightAnchorDestructiveQuietButtonStyle(compact: true))
            }
            .layoutPriority(1)
        }
        .lightAnchorListRow(session.isActive ? .found : .plain)
    }
}

// MARK: - 详情（trace 时间线 + 生成成稿 + 导出）

struct RecordingDetailView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID

    @State private var title = ""
    @State private var style: RecordingStyle = .guide
    @State private var markdown = ""
    @State private var entries: [RecordingEntry] = []
    @State private var isComposing = false
    @State private var composeError: String?

    /// 详情一次最多铺多少条 trace（都是短行，200 条内滚动没有压力）。
    private static let displayedEntryLimit = 200

    private var session: RecordingSession? {
        workspace.snapshot.recordingSessions[sessionID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LightAnchorSheetHeader(
                eyebrow: tr("records"),
                title: tr("recording_detail"),
                subtitle: tr("recording_detail_subtitle"),
                icon: "file-text"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LightAnchorSettingsSection(
                        title: tr("what_this_record_is"),
                        detail: nil,
                        icon: "pencil"
                    ) {
                        TextField(tr("record_title_placeholder"), text: $title)
                            .textFieldStyle(LightAnchorTextFieldStyle())
                    }

                    LightAnchorSettingsSection(
                        title: tr("trace_timeline"),
                        detail: String(format: tr("n_trace_entries"), entries.count),
                        icon: "clock"
                    ) {
                        if entries.isEmpty {
                            Text(tr("this_recording_has_no_entries"))
                                .font(LightAnchorTheme.supportingFont())
                                .foregroundStyle(LightAnchorTheme.faintInk)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(entries.prefix(Self.displayedEntryLimit)) { entry in
                                    traceRow(entry)
                                }
                                if entries.count > Self.displayedEntryLimit {
                                    Text(String(
                                        format: tr("n_more_entries_omitted"),
                                        entries.count - Self.displayedEntryLimit
                                    ))
                                    .font(LightAnchorTheme.supportingFont(size: 11))
                                    .foregroundStyle(LightAnchorTheme.faintInk)
                                }
                            }
                        }
                    }

                    LightAnchorSettingsSection(
                        title: tr("composed_markdown"),
                        detail: composeDetail,
                        icon: "sparkles"
                    ) {
                        LightAnchorChoiceField(
                            tr("record_audience"),
                            selection: $style,
                            options: RecordingStyle.allCases,
                            titleForValue: { $0.title }
                        )
                        Text(style.explanation)
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(isComposing ? tr("composing") : tr("compose_with_ai")) {
                                compose()
                            }
                            .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                            .disabled(isComposing || entries.isEmpty)
                            if isComposing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Spacer(minLength: 8)
                            if !markdown.isEmpty {
                                Button(tr("copy_markdown")) {
                                    RecordingExport.copy(markdown: markdown)
                                }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                                Button(tr("export_file")) {
                                    RecordingExport.saveToFile(
                                        markdown: markdown,
                                        fileName: style.exportFileName(for: title)
                                    )
                                }
                                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                            }
                        }
                        if let composeError {
                            Text(composeError)
                                .font(LightAnchorTheme.supportingFont())
                                .foregroundStyle(LightAnchorTheme.error)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !markdown.isEmpty || isComposing {
                            markdownEditor
                        }
                    }
                }
            }
            .frame(maxHeight: 540)

            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(UserFacingCopy.save) {
                    _ = workspace.updateRecordingSession(
                        sessionID,
                        title: title,
                        markdown: markdown
                    )
                    dismiss()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 680)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
        .onAppear {
            guard let session else { return }
            title = session.title
            style = session.style
            markdown = session.markdown
            entries = workspace.recordingEntries(for: sessionID)
        }
    }

    private var composeDetail: String? {
        guard let session, !session.composedBy.isEmpty else {
            return tr("compose_turns_the_trace_into")
        }
        return String(format: tr("composed_by_engine"), session.composedBy)
    }

    private func traceRow(_ entry: RecordingEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(LightAnchorTheme.supportingFont(size: 11))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.faintInk)
                .frame(width: 44, alignment: .leading)
            Text(entry.kind.title)
                .font(LightAnchorTheme.labelFont(size: 10.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(
                    LightAnchorTheme.recessed,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(LightAnchorTheme.supportingFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineLimit(2)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(LightAnchorTheme.supportingFont(size: 11))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var markdownEditor: some View {
        TextEditor(text: $markdown)
            .font(LightAnchorTheme.bodyFont(size: 12.5))
            .foregroundStyle(LightAnchorTheme.ink)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 180)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            }
    }

    /// AI 整理：先把标题改动落盘（成稿要用它），成稿写回本地编辑区。
    private func compose() {
        _ = workspace.updateRecordingSession(sessionID, title: title)
        isComposing = true
        composeError = nil
        Task {
            if let composed = await workspace.composeRecordingMarkdown(sessionID, style: style) {
                markdown = composed.markdown
            } else {
                composeError = workspace.lastError ?? tr("compose_failed_please_retry")
                workspace.clearError()
            }
            isComposing = false
        }
    }
}

// MARK: - 导出与复制

enum RecordingExport {
    @MainActor
    static func copy(markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    @MainActor
    static func saveToFile(markdown: String, fileName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
