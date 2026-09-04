import SwiftUI

// MARK: - 工具组 + 录制状态胶囊
//
// 工具类动作（新建定时、录制过程）不占侧栏，也不悬浮右下角（用户定：
// 挂件挡内容、离工具行太远）——直接以图标住进岛工具行，悬停有文字提示，
// 与右侧常用三键（捕获/搜索/现场舱）之间用一道竖线分组。
// 录制中不靠小红点自证——状态自己长成一枚常驻胶囊（红点 + 时长 + 停止），
// 仍悬浮右下角，任何页面一眼可见；没在录制时右下角空无一物。

/// 岛工具行里的工具组：新建定时、录制过程，两枚细线图标钮。
struct WorkspaceToolbarTools: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @State private var showingScheduleEditor = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                showingScheduleEditor = true
            } label: {
                toolGlyph(.alarmClock)
            }
            .buttonStyle(LightAnchorToolbarIconButtonStyle())
            .help(tr("add_a_schedule"))
            .accessibilityLabel(tr("add_a_schedule"))

            Button {
                _ = workspace.startManualRecording()
            } label: {
                toolGlyph(.notebookPen)
            }
            .buttonStyle(LightAnchorToolbarIconButtonStyle())
            // 录制中不能再开一份：置灰；停止住在右下角的状态胶囊上。
            .disabled(workspace.activeRecordingSession != nil)
            .help(tr("record_a_process"))
            .accessibilityLabel(tr("record_a_process"))
        }
        .sheet(isPresented: $showingScheduleEditor) {
            ScheduledTaskEditorView(task: nil)
                .environmentObject(workspace)
        }
    }

    /// Lucide 细线字形按侧栏同款画法收进 16pt，配得上邻位 14pt 的 SF 符号。
    private func toolGlyph(_ glyph: LightAnchorNavGlyph) -> some View {
        LightAnchorNavGlyphShape(glyph: glyph)
            .stroke(style: StrokeStyle(
                lineWidth: 1.75 * 16 / 24,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: 16, height: 16)
    }
}

/// 录制状态胶囊：红点 + 「录制中 · 时长」+ 停止。暂停时红点转空心。
/// 只在有录制会话时出现，右下角悬浮，任何页面一眼可见。
struct WorkspaceRecordingPill: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let session = workspace.activeRecordingSession {
                pill(session)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82),
            value: workspace.activeRecordingSession?.id
        )
    }

    private func pill(_ session: RecordingSession) -> some View {
        HStack(spacing: 8) {
            if session.status == .paused {
                Circle()
                    .strokeBorder(LightAnchorDesign.danger, lineWidth: 2)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(LightAnchorDesign.danger)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(statusLine(session))
                    .font(LightAnchorTheme.controlFont(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.ink)
                if !session.title.isEmpty {
                    Text(session.title)
                        .font(LightAnchorTheme.supportingFont(size: 10.5))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }

            Button(tr("stop_process_recording")) {
                _ = workspace.stopRecording()
            }
            .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            LightAnchorTheme.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LightAnchorDesign.danger.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }

    private func statusLine(_ session: RecordingSession) -> String {
        if session.status == .paused {
            return tr("recording_paused")
        }
        let minutes = max(0, Int(Date().timeIntervalSince(session.startedAt) / 60))
        return String(format: tr("recording_for_duration"), UserFacingCopy.focusDuration(minutes))
    }
}
