import SwiftUI

// MARK: - 悬浮动作组（Project AIRI 挂件式）
//
// 工具类动作（新建定时、录制过程）不占侧栏：右下角一枚收起的圆钮，
// 点开向上弹出一列工具，选完自动收回；展开/收起有弹簧动画。
// 录制中不靠小红点自证——状态自己长成一枚常驻胶囊（红点 + 时长 + 停止），
// 收起与否它都在，任何页面一眼可见。

struct WorkspaceToolCluster: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @State private var isExpanded = false
    @State private var showingScheduleEditor = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeSession: RecordingSession? {
        workspace.activeRecordingSession
    }

    private var clusterAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isExpanded {
                toolButton(
                    glyph: .alarmClock,
                    title: tr("add_a_schedule")
                ) {
                    showingScheduleEditor = true
                }
                .transition(toolTransition)

                if activeSession == nil {
                    toolButton(
                        glyph: .notebookPen,
                        title: tr("record_a_process")
                    ) {
                        _ = workspace.startManualRecording()
                    }
                    .transition(toolTransition)
                }
            }

            HStack(spacing: 8) {
                if let activeSession {
                    recordingPill(activeSession)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                clusterToggle
            }
        }
        .animation(clusterAnimation, value: isExpanded)
        .animation(clusterAnimation, value: activeSession?.id)
        .sheet(isPresented: $showingScheduleEditor) {
            ScheduledTaskEditorView(task: nil)
                .environmentObject(workspace)
        }
    }

    /// 工具从收起钮的位置里长出来：向下位移 + 淡入淡出。
    private var toolTransition: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    // MARK: 录制状态胶囊

    /// 录制中的常驻反馈：红点 + 「录制中 · 时长」+ 停止。暂停时红点转空心。
    private func recordingPill(_ session: RecordingSession) -> some View {
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
                Text(recordingStatusLine(session))
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

    private func recordingStatusLine(_ session: RecordingSession) -> String {
        if session.status == .paused {
            return tr("recording_paused")
        }
        let minutes = max(0, Int(Date().timeIntervalSince(session.startedAt) / 60))
        return String(format: tr("recording_for_duration"), UserFacingCopy.focusDuration(minutes))
    }

    // MARK: 收起 / 展开

    private var clusterToggle: some View {
        Button {
            isExpanded.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(LightAnchorTheme.elevatedSurface)
                    .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                Circle()
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
                LightAnchorIcon("chevron-up", size: 13)
                    .foregroundStyle(LightAnchorTheme.iconSubtle)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("tools"))
        .accessibilityValue(isExpanded ? tr("state_shown") : tr("state_hidden"))
        .help(tr("tools"))
    }

    private func toolButton(
        glyph: LightAnchorNavGlyph,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            isExpanded = false
            action()
        } label: {
            HStack(spacing: 7) {
                LightAnchorNavGlyphShape(glyph: glyph)
                    .stroke(style: StrokeStyle(
                        lineWidth: 1.75 * 14 / 24,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(LightAnchorTheme.controlFont(size: 12, weight: .medium))
            }
            .foregroundStyle(LightAnchorTheme.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
