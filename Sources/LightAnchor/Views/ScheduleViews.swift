import SwiftUI

// MARK: - 定时（回顾页区块 + 编辑器）
//
// 定时没有自己的 tab：查看与管理都住在回顾页的「定时」区。
// 上半是即将到来的任务（新建/编辑/完成/删除），下半是触发历史的时间线——
// 每次触发一格，收到现场检查点的格子可以点开看当时的现场。

struct ScheduleReviewSection: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    /// 点开某次触发收到的现场（复用回顾页的历史现场查看）。
    let onOpenScene: (SceneSnapshot) -> Void

    @State private var editorContext: ScheduledTaskEditorContext?
    @State private var filterTaskID: UUID?
    @State private var scenesOnly = false

    private var timeline: ScheduleTimeline {
        ScheduleTimeline.make(
            from: workspace.snapshot,
            filterTaskID: filterTaskID,
            scenesOnly: scenesOnly
        )
    }

    /// 筛选菜单里的任务：触发史和排定中出现过的都算（含已删任务的历史标题）。
    private var filterableTasks: [(id: UUID, title: String)] {
        var seen = Set<UUID>()
        var tasks: [(UUID, String)] = []
        for task in workspace.snapshot.upcomingScheduledTasks where seen.insert(task.id).inserted {
            tasks.append((task.id, task.title))
        }
        for fire in workspace.snapshot.allScheduledFires where seen.insert(fire.taskID).inserted {
            tasks.append((fire.taskID, fire.taskTitle))
        }
        return tasks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                LightAnchorSectionLabel(tr("schedule"))
                Spacer(minLength: 12)
                if !timeline.pastEntries.isEmpty || filterTaskID != nil || scenesOnly {
                    filterMenu
                }
                Button(tr("add_a_schedule")) {
                    editorContext = ScheduledTaskEditorContext(task: nil)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
            }
            .padding(.bottom, 14)

            if timeline.upcomingDays.isEmpty && timeline.pastEntries.isEmpty {
                LightAnchorInfoStrip(
                    title: tr("nothing_scheduled_yet"),
                    detail: tr("set_a_one_off_alarm_or"),
                    icon: "calendar-clock"
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(timeline.upcomingDays) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            LightAnchorSectionLabel(day.title)
                            LightAnchorListPanel {
                                ForEach(day.entries) { entry in
                                    upcomingRow(entry)
                                    if entry.id != day.entries.last?.id {
                                        LightAnchorRowSeparator()
                                    }
                                }
                            }
                        }
                    }

                    if !timeline.pastEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            LightAnchorSectionLabel(tr("already_reminded"))
                            LightAnchorListPanel {
                                ForEach(timeline.pastEntries) { entry in
                                    firedRow(entry)
                                    if entry.id != timeline.pastEntries.last?.id {
                                        LightAnchorRowSeparator()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editorContext) { context in
            ScheduledTaskEditorView(task: context.task)
                .environmentObject(workspace)
        }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filterTaskID = nil
            } label: {
                menuLabel(tr("all_scheduled_tasks"), checked: filterTaskID == nil)
            }
            ForEach(filterableTasks, id: \.id) { task in
                Button {
                    filterTaskID = task.id
                } label: {
                    menuLabel(task.title, checked: filterTaskID == task.id)
                }
            }
            Divider()
            Button {
                scenesOnly.toggle()
            } label: {
                menuLabel(tr("only_fires_with_scenes"), checked: scenesOnly)
            }
        } label: {
            LightAnchorLabel(
                title: filterTaskID.flatMap { id in
                    filterableTasks.first { $0.id == id }?.title
                } ?? tr("all_scheduled_tasks"),
                icon: "sliders-horizontal",
                spacing: 5
            )
            .font(LightAnchorTheme.controlFont(size: 12))
            .foregroundStyle(LightAnchorTheme.mutedInk)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func menuLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            if checked { Image(systemName: "checkmark") }
            Text(title)
        }
    }

    private func upcomingRow(_ entry: ScheduleTimelineEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(upcomingMeta(entry))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 14)
            HStack(spacing: 6) {
                Button(tr("edit")) {
                    if let task = workspace.snapshot.scheduledTasks[entry.taskID] {
                        editorContext = ScheduledTaskEditorContext(task: task)
                    }
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                Button(UserFacingCopy.done) {
                    _ = workspace.completeScheduledTask(entry.taskID)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                Button(UserFacingCopy.delete, role: .destructive) {
                    _ = workspace.deleteScheduledTask(entry.taskID)
                }
                .buttonStyle(LightAnchorDestructiveQuietButtonStyle(compact: true))
            }
            .layoutPriority(1)
        }
        .lightAnchorListRow()
    }

    private func upcomingMeta(_ entry: ScheduleTimelineEntry) -> String {
        var parts = [entry.date.formatted(date: .omitted, time: .shortened)]
        if entry.repeatRule != .once {
            parts.append(entry.repeatRule.title)
        }
        if entry.collectsScene {
            parts.append(tr("will_collect_a_scene"))
        }
        if let calendarTitle = entry.calendarEventTitle, !calendarTitle.isEmpty {
            parts.append(String(format: tr("time_from_calendar_event"), calendarTitle))
        }
        if !entry.note.isEmpty {
            parts.append(entry.note)
        }
        return parts.joined(separator: " · ")
    }

    private func firedRow(_ entry: ScheduleTimelineEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title.isEmpty ? tr("deleted_scheduled_task") : entry.title)
                    .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.ink)
                Text(
                    lightAnchorFriendlyDateTime(entry.date)
                        + (entry.collectsScene ? " · " + tr("scene_attached") : "")
                )
                .font(LightAnchorTheme.supportingFont(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.faintInk)
            }
            Spacer(minLength: 14)
            if let sceneID = entry.sceneSnapshotID,
               let scene = workspace.snapshot.sceneSnapshots[sceneID] {
                Button(tr("view_the_scene")) {
                    onOpenScene(scene)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .layoutPriority(1)
            }
        }
        .lightAnchorListRow(.frost)
    }
}

/// 编辑器按打开瞬间的任务钉住（.sheet(item:)）；nil 表示新建。
struct ScheduledTaskEditorContext: Identifiable {
    let task: ScheduledTask?

    var id: UUID { task?.id ?? UUID() }
}

// MARK: - 新建 / 编辑定时任务

struct ScheduledTaskEditorView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    /// nil = 新建。
    let task: ScheduledTask?

    @State private var title = ""
    @State private var note = ""
    @State private var fireAt = Date().addingTimeInterval(3600)
    @State private var repeatRule: ScheduledTaskRepeatRule = .once
    @State private var collectSceneOnFire = false
    @State private var calendarEventID: String?
    @State private var calendarEventTitle: String?
    @State private var calendarAccessGranted = CalendarEventReader.hasFullAccess
    @State private var calendarEvents: [CalendarEventSummary] = []
    @State private var calendarRequestFailed = false

    init(task: ScheduledTask?) {
        self.task = task
        if let task {
            _title = State(initialValue: task.title)
            _note = State(initialValue: task.note)
            _fireAt = State(initialValue: task.fireAt)
            _repeatRule = State(initialValue: task.repeatRule)
            _collectSceneOnFire = State(initialValue: task.collectSceneOnFire)
            _calendarEventID = State(initialValue: task.calendarEventID)
            _calendarEventTitle = State(initialValue: task.calendarEventTitle)
        }
    }

    private var isEditing: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LightAnchorSheetHeader(
                eyebrow: tr("schedule"),
                title: isEditing ? tr("edit_schedule") : tr("add_a_schedule"),
                subtitle: tr("it_comes_to_find_you"),
                icon: "calendar-clock"
            )

            LightAnchorSettingsSection(
                title: tr("what_to_do_then"),
                detail: tr("phrase_it_so_future_you"),
                icon: "pencil"
            ) {
                TextField(tr("e_g_get_back_to_the"), text: $title)
                    .textFieldStyle(LightAnchorTextFieldStyle())
                TextField(tr("note_optional"), text: $note)
                    .textFieldStyle(LightAnchorTextFieldStyle())
            }

            LightAnchorSettingsSection(
                title: tr("when_it_fires"),
                detail: tr("one_off_alarms_finish_after_firing"),
                icon: "clock"
            ) {
                HStack {
                    Text(tr("fire_time"))
                        .font(LightAnchorTheme.controlFont())
                    Spacer()
                    LightAnchorDateField(tr("fire_time"), selection: $fireAt, in: Date()...)
                }
                LightAnchorChoiceField(
                    tr("repeat"),
                    selection: $repeatRule,
                    options: ScheduledTaskRepeatRule.allCases,
                    titleForValue: { $0.title }
                )
                calendarPickerRow
            }

            LightAnchorSettingsSection(
                title: tr("collect_the_scene"),
                detail: tr("each_fire_collects_a_checkpoint"),
                icon: "scan"
            ) {
                Toggle(isOn: $collectSceneOnFire) {
                    Text(tr("collect_a_scene_when_it_fires"))
                        .font(LightAnchorTheme.controlFont())
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            LightAnchorSheetActionBar {
                Button(tr("cancel")) { dismiss() }
                    .buttonStyle(LightAnchorQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? UserFacingCopy.save : tr("add_a_schedule")) {
                    save()
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LightAnchorDesign.workspaceContentInset)
        .frame(width: 600)
        .background(LightAnchorTheme.windowBackground)
        .foregroundStyle(LightAnchorTheme.ink)
    }

    /// 「从日历选时间」一行：未授权先给授权按钮；授权后是一颗事件菜单。
    @ViewBuilder
    private var calendarPickerRow: some View {
        HStack {
            Text(tr("pick_from_calendar"))
                .font(LightAnchorTheme.controlFont())
            Spacer()
            if calendarAccessGranted {
                Menu {
                    if calendarEvents.isEmpty {
                        Button(tr("no_upcoming_events")) {}
                            .disabled(true)
                    }
                    ForEach(calendarEvents) { event in
                        Button {
                            fireAt = event.startDate
                            calendarEventID = event.id
                            calendarEventTitle = event.title
                        } label: {
                            Text("\(lightAnchorFriendlyDateTime(event.startDate))  \(event.title)")
                        }
                    }
                } label: {
                    LightAnchorLabel(
                        title: calendarEventTitle ?? tr("pick_a_calendar_event"),
                        icon: "calendar",
                        spacing: 6
                    )
                    .font(LightAnchorTheme.controlFont())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onAppear { calendarEvents = CalendarEventReader().upcomingEvents() }
            } else {
                Button(calendarRequestFailed ? tr("calendar_access_denied") : tr("allow_calendar_access")) {
                    Task {
                        let granted = await CalendarEventReader().requestAccess()
                        calendarAccessGranted = granted
                        calendarRequestFailed = !granted
                        if granted {
                            calendarEvents = CalendarEventReader().upcomingEvents()
                        }
                    }
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .disabled(calendarRequestFailed)
            }
        }
    }

    private func save() {
        if var updated = task {
            updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.fireAt = fireAt
            updated.repeatRule = repeatRule
            updated.collectSceneOnFire = collectSceneOnFire
            updated.calendarEventID = calendarEventID
            updated.calendarEventTitle = calendarEventTitle
            guard workspace.updateScheduledTask(updated) else { return }
        } else {
            guard workspace.createScheduledTask(
                title: title,
                note: note,
                fireAt: fireAt,
                repeatRule: repeatRule,
                collectSceneOnFire: collectSceneOnFire,
                calendarEventID: calendarEventID,
                calendarEventTitle: calendarEventTitle
            ) != nil else { return }
        }
        dismiss()
    }
}
