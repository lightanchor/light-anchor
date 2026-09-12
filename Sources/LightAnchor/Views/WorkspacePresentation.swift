import SwiftUI

/// The macOS workspace routes attention and operational tools through one
/// split-view selection instead of duplicating the same tabs in every page.
/// 没有「等待」这一格：等结果的事不住在单独一页，它就是稍后清单上
/// 「等着别人」那一组——等待不是一个你要去看的地方，是一个到期会来找你的东西。
enum WorkspaceDestination: String, CaseIterable, Identifiable, Hashable {
    case now
    case later
    case environments
    case review
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: tr("now")
        case .later: tr("later")
        case .environments: tr("environments")
        case .review: tr("review_2")
        case .chat: tr("chat")
        }
    }

    var subtitle: String {
        switch self {
        case .now: ""
        case .later: tr("new_items_held_until_you_re")
        case .environments: tr("set_the_scene_up")
        case .review: tr("see_what_actually_worked")
        case .chat: tr("ask_your_memory")
        }
    }

    var isAttention: Bool {
        switch self {
        case .now, .later: true
        case .environments, .review, .chat: false
        }
    }

    var navigationTitle: String { title }
}

enum LaterScope: String, CaseIterable, Identifiable, Hashable {
    case inbox
    case references
    case archived

    var id: String { rawValue }

    /// 样机 .segsoft 的档位名。归档是历史查阅，不是工作流档位——
    /// 有它才能兑现「历史通过搜索和归档访问」，收件箱和资料仍是仅有的两条工作流。
    var title: String {
        switch self {
        case .inbox: tr("inbox")
        case .references: tr("reference")
        case .archived: tr("archive")
        }
    }

    var iconName: String {
        switch self {
        case .inbox: "tray"
        case .references: "books.vertical"
        case .archived: "archivebox"
        }
    }

    var emptyTitle: String {
        switch self {
        case .inbox: tr("nothing_new_yet")
        case .references: tr("no_reference_yet")
        case .archived: tr("nothing_archived_yet")
        }
    }

    var emptyDetail: String {
        switch self {
        case .inbox: tr("capture_text_a_link_a_file")
        case .references: tr("items_you_file_as_reference_stay")
        case .archived: tr("everything_you_archive_lands_here_restore")
        }
    }
}

struct WorkspaceSearchResult: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case target
        case capture
        case waiting
        case scene
    }

    /// 行首蓝点形态（样机 .srrow .sdot）：进行中/等待虚线/宜绿就绪/灰点。
    enum Dot: Hashable {
        case active
        case waiting
        case ready
        case ended
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let destination: WorkspaceDestination
    let dot: Dot
    /// kind == .target 时指向目标本体：点击结果要在中心区域打开回顾。
    let targetID: UUID?
    /// kind == .scene 时指向精确的历史现场，而不是笼统地打开该目标最新现场。
    let sceneSnapshotID: UUID?
    /// 稍后页内的目的档位（资料/归档的捕获要落到对应档，而不是收件箱）。
    let laterScope: LaterScope?

    init(
        stableID: String,
        kind: Kind,
        title: String,
        subtitle: String,
        destination: WorkspaceDestination,
        dot: Dot = .ended,
        targetID: UUID? = nil,
        sceneSnapshotID: UUID? = nil,
        laterScope: LaterScope? = nil
    ) {
        id = stableID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
        self.dot = dot
        self.targetID = targetID
        self.sceneSnapshotID = sceneSnapshotID
        self.laterScope = laterScope
    }
}

enum UserFacingCopy {
    static let currentWork = tr("current_work_2")
    static let startWork = tr("start_something")
    static let capture = tr("capture")
    static let captureIdea = tr("capture_a_thought")
    static let finishWork = tr("finish_this")
    static let waitForResult = tr("wait_for_a_result")
    static let later = tr("later")
    static let settings = tr("settings")
    static let quit = tr("quit")
    static let save = tr("save")
    static let cancel = tr("cancel")
    static let close = tr("close")
    static let done = tr("done")
    static let delete = tr("delete")
    static let archive = tr("archive")
    static let discard = tr("discard")

    static let noCurrentWorkMessage = tr("start_with_something_small_or_tuck")

    static func captureKind(_ kind: CaptureKind) -> String {
        switch kind {
        case .text: tr("text")
        case .voice: tr("voice")
        case .screenshot: tr("screenshot")
        case .link: tr("link")
        case .fileReference: tr("file")
        }
    }

    static func waitingState(_ state: AttentionEpisodeState) -> String {
        switch state {
        case .active: tr("active")
        case .paused: tr("paused")
        case .returning: tr("ready_to_return_2")
        case .ended: tr("ended")
        }
    }

    static func limitation(_ message: String) -> String {
        String(format: tr("some_content_couldn_t_be_restored"), message)
    }

    /// 专注时长的人话写法：一小时以内报分钟，以上拆成「7 小时 27 分」——
    /// 「447 分钟」逼用户自己心算。
    static func focusDuration(_ minutes: Int) -> String {
        let minutes = max(0, minutes)
        if minutes < 60 { return String(format: tr("min"), minutes) }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? String(format: tr("h"), hours)
            : String(format: tr("h_min"), hours, rest)
    }

    /// 「放下 X」的统一写法：刚放下 / 放下 X 分钟 / 放下 X 小时 X 分 / 放下 X 天。
    /// 超过一天还报时分会出现「放下 71 小时 56 分」这种没人这么说话的句子。
    static func setAsideAge(of date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return tr("set_aside_just_now") }
        if minutes < 1440 {
            return String(format: tr("set_aside_for"), focusDuration(minutes))
        }
        return String(
            format: tr("set_aside_for"),
            String(format: tr("days_plain"), minutes / 1440)
        )
    }

    /// 「已等 X」的统一写法。和上面的「放下 X」同构，但说的是另一回事：
    /// 放下的时长是「你多久没管它」，等待的时长是「结果多久没来」——
    /// 一个由你决定，一个不由你决定，这正是等待与稍后的分界。
    static func waitedAge(of date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return tr("waited_just_now") }
        if minutes < 1440 {
            return String(format: tr("waited_for"), focusDuration(minutes))
        }
        return String(
            format: tr("waited_for"),
            String(format: tr("days_plain"), minutes / 1440)
        )
    }

    /// 期限的倒计时写法。这个软件里别的数字都在**往上加**（放下 3 天、已等 5 天、
    /// 专注 47 分钟）——往上加的数字天生是死的，它只在描述过去。押了期限的要
    /// **倒着走**：还有 2 天 → 就是今天 → 过期 1 天。倒着走的数字自己会喊人，
    /// 扫一眼清单，哪条在逼你，不用读字就看得出来。
    static func dueCountdown(_ countdown: DueCountdown) -> String {
        if countdown.isToday { return tr("due_today") }
        if countdown.isOverdue {
            return String(
                format: countdown.daysOverdue == 1 ? tr("due_overdue_one") : tr("due_overdue"),
                countdown.daysOverdue
            )
        }
        return String(
            format: countdown.days == 1 ? tr("due_in_days_one") : tr("due_in_days"),
            countdown.days
        )
    }

    /// 期限那天的人话写法：今天/明天说名字，一周内说星期几，再远说日期。
    /// 到期那句话里必须有日期——「已等 5 天」只是陈述过去，「周五要用」才逼人。
    static func dueDayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = DueCountdown(due: date, now: now).days
        if days == 0 { return tr("due_day_today") }
        if days == 1 { return tr("due_day_tomorrow") }
        if (2...6).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// 「38 分钟前」式的相对时间（V7 元信息密度：分钟以下不显示秒）。
    /// 整句模板，不再用「前」后缀拼接：后缀前置的语言（西语 hace…）拼不出来，
    /// 违背「加新语言 = 加一个 .lproj 零代码」的承诺。
    static func relativeAge(of date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return tr("just_now") }
        if minutes < 60 { return String(format: tr("min_2"), minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: tr("h_2"), hours) }
        return String(format: tr("d"), hours / 24)
    }
}

enum LightAnchorDesign {
    static let workspaceHorizontalPadding: CGFloat = 30
    static let workspaceContentInset: CGFloat = 28
    static let surfaceRadius: CGFloat = 14
    static let radiusRow: CGFloat = 11
    static let radiusCard: CGFloat = 14
    static let radiusHero: CGFloat = 16
    static let sidebarWidth: CGFloat = 226

    // 「收进蓝点」（收起侧栏）的呼吸带几何——和样机同一组数：
    // 红绿灯已由窗口 chrome 排到中心 y=22、x=22/42/62。
    /// 收起后内容岛顶部让出的米白高度（红绿灯 + 蓝点铭牌住在这条带里）。
    static let anchorStripHeight: CGFloat = 44
    /// 呼吸带控件（收起钮/蓝点铭牌）的左缘：红绿灯簇（止于 68）右侧，
    /// 铭牌里的蓝点中心正好落在样机的 x=88。
    static let anchorPlateLeading: CGFloat = 75
    /// 控件相对安全区顶的位移：抵掉 28pt 标题栏安全区后，
    /// 30 高的控件中心对齐红绿灯中心线（窗顶下 22pt）。
    static let anchorStripControlOffsetY: CGFloat = -21

    static var primary: LightAnchorThemeColor {
        LightAnchorTheme.accentInk
    }
    static var accentInk: LightAnchorThemeColor { LightAnchorTheme.accentInk }
    static var waiting: LightAnchorThemeColor { LightAnchorTheme.warning }
    static var success: LightAnchorThemeColor { LightAnchorTheme.success }
    static var danger: LightAnchorThemeColor { LightAnchorTheme.danger }
}

/// A flat, bordered group for settings and operational tools. The border and
/// surface shift provide hierarchy without adding another floating layer.
struct LightAnchorSettingsSection<Content: View>: View {
    let title: String
    let detail: String?
    let icon: String?
    private let content: Content

    init(
        title: String,
        detail: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon {
                    LightAnchorIcon(icon, size: 15)
                        .foregroundStyle(LightAnchorTheme.iconSubtle)
                }
                Text(title)
                    .font(LightAnchorTheme.headingFont())
                    .foregroundStyle(LightAnchorTheme.ink)
                Spacer(minLength: 8)
            }

            if let detail {
                Text(detail)
                    .font(LightAnchorTheme.supportingFont())
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lightAnchorShell(radius: LightAnchorDesign.surfaceRadius, padding: 16)
    }
}

struct LightAnchorInfoStrip: View {
    let title: String
    let detail: String
    let icon: String
    var tint: LightAnchorThemeColor = LightAnchorTheme.iconSubtle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LightAnchorIcon(icon, size: 15)
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LightAnchorTheme.interfaceFont(size: 12, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                Text(detail)
                    .font(LightAnchorTheme.interfaceFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

struct LightAnchorEmptyState: View {
    let markState: LightAnchorMarkState
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        markState: LightAnchorMarkState = .idle,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.markState = markState
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        // 居中构图：幽灵预览 + 标题 + 说明 + 动作。
        // 图标、抽象几何、品牌标记四版全被否——空状态不再「画东西」，
        // 改成内容本身的淡影预告（成熟软件的做法）：三行渐隐的占位卡，
        // 示意「你的条目将来长在这里」。
        VStack(spacing: 0) {
            LightAnchorEmptyGhostRows(markState: markState)
                .padding(.bottom, 20)

            Text(title)
                .font(LightAnchorTheme.headingFont())
                .foregroundStyle(LightAnchorTheme.ink)
                .padding(.bottom, 4)
            Text(detail)
                .font(LightAnchorTheme.interfaceFont(size: 12))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LightAnchorRaisedButtonStyle(compact: true))
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.vertical, 28)
    }
}

struct LightAnchorSheetHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LightAnchorTheme.subtleFill)
                LightAnchorIcon(icon, size: 16)
                    .foregroundStyle(LightAnchorTheme.iconSubtle)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow.uppercased())
                    .font(LightAnchorTheme.labelFont(size: 11, weight: .bold))
                    .tracking(0.75)
                    .foregroundStyle(LightAnchorTheme.secondaryInk)
                Text(title)
                    .font(LightAnchorTheme.interfaceFont(size: 19, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                Text(subtitle)
                    .font(LightAnchorTheme.interfaceFont(size: 12))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LightAnchorSheetActionBar<Content: View>: View {
    private let content: Content
    /// 内容自己撑满整行（比如把删除钮顶到左缘、确认钮留在右缘）时关掉
    /// 前导 Spacer：两股弹性会平分余量，左缘那颗按钮反而被推到半路。
    private let fillsWidth: Bool

    init(fillsWidth: Bool = false, @ViewBuilder content: () -> Content) {
        self.fillsWidth = fillsWidth
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 11) {
            Divider()
                .foregroundStyle(LightAnchorTheme.hairlineBorder)
            HStack(spacing: 8) {
                if !fillsWidth {
                    Spacer(minLength: 8)
                }
                content
            }
        }
        .padding(.top, 2)
    }
}

/// 大号计时（页面视觉锚）：44pt 细体数字 + 12pt 单位小字。
/// 超过一小时拆成「7 小时 27 分」，单位与数字逐段基线对齐。
struct LightAnchorFocusReadout: View {
    let minutes: Int
    /// 追加在末尾的小字说明（如「累计」）。
    var caption: String? = nil

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            let clamped = max(0, minutes)
            if clamped >= 60 {
                number("\(clamped / 60)")
                unit(tr("unit_hours_short"))
                if clamped % 60 > 0 {
                    number("\(clamped % 60)")
                    unit(tr("unit_minutes_short"))
                }
            } else {
                number("\(clamped)")
                unit(tr("unit_minutes_full"))
            }
            if let caption {
                unit(caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [UserFacingCopy.focusDuration(minutes), caption]
                .compactMap { $0 }
                .joined(separator: " ")
        )
    }

    private func number(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 44, weight: .ultraLight))
            .monospacedDigit()
            .foregroundStyle(LightAnchorTheme.ink)
    }

    private func unit(_ text: String) -> some View {
        Text(text)
            .font(LightAnchorTheme.supportingFont(size: 12))
            .foregroundStyle(LightAnchorTheme.faintInk)
    }
}

/// 品牌标记视图：把「蜜芽方块」（蜜色软方墩 + 品牌蓝点）画进任意尺寸。
/// 与应用图标、菜单栏图标共用 LightAnchorMark 的同一套几何。
struct LightAnchorMarkView: View {
    var state: LightAnchorMarkState = .active

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                // Canvas 的 CG 坐标 y 向下；LightAnchorMark.draw 期望
                // y 向上的经典 CG 坐标，先翻一次。
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                LightAnchorMark.draw(
                    state,
                    in: cg,
                    fitting: CGRect(origin: .zero, size: size),
                    shape: LightAnchorMark.brandHoneyColor,
                    dot: LightAnchorMark.brandBlueColor
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// 「现在」页大空状态的视觉：一张工作卡的幽灵预告——虚线边白卡里
/// 摆着蓝点、标题条和两枚按钮位的淡影，示意「你正在做的事会住在这里」。
/// （同心环、轨道卫星、品牌标记几版「画出来的图」都被否；空状态
/// 直接预告内容本身的形状，天然和软件同风格。）
struct LightAnchorEmptyIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LightAnchorTheme.primary.opacity(0.5))
                    .frame(width: 10, height: 10)
                Capsule()
                    .fill(LightAnchorTheme.recessed)
                    .frame(width: 66, height: 7)
                Spacer(minLength: 0)
                // 右上计时位。
                Capsule()
                    .fill(LightAnchorTheme.recessed)
                    .frame(width: 44, height: 9)
            }
            // 标题位。
            Capsule()
                .fill(LightAnchorTheme.recessed)
                .frame(width: 172, height: 10)
            // 动作位：一枚水洗蓝主按钮影 + 一枚安静按钮影。
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LightAnchorTheme.accentWash)
                    .frame(width: 72, height: 22)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LightAnchorTheme.recessed)
                    .frame(width: 72, height: 22)
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(
            LightAnchorTheme.surface.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            // 虚线边：空位的通用语言。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LightAnchorTheme.subtleBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        .accessibilityHidden(true)
    }
}

/// 列表页空状态的幽灵预览：三行渐隐的占位卡。首行点位跟着页面语义走
/// （等待页 = 点环，其余 = 水洗蓝点），第二行给一点蜜色呼应。
struct LightAnchorEmptyGhostRows: View {
    var markState: LightAnchorMarkState = .idle

    var body: some View {
        VStack(spacing: 7) {
            ghostRow(leadingDot: primaryDot, opacity: 1)
            ghostRow(leadingDot: AnyView(honeyDot), opacity: 0.55)
            ghostRow(leadingDot: AnyView(faintDot), opacity: 0.28)
        }
        .frame(width: 288)
        .accessibilityHidden(true)
    }

    private var primaryDot: AnyView {
        if markState == .waiting {
            // 等待页：首行点位用虚线点环，和蓝点状态语言一致。
            AnyView(
                Circle()
                    .stroke(
                        LightAnchorTheme.primary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.6, dash: [1.6, 2.4])
                    )
                    .frame(width: 9, height: 9)
            )
        } else {
            AnyView(
                Circle()
                    .fill(LightAnchorTheme.primary.opacity(0.5))
                    .frame(width: 9, height: 9)
            )
        }
    }

    private var honeyDot: some View {
        Circle()
            .fill(LightAnchorTheme.chartYellow.opacity(0.6))
            .frame(width: 9, height: 9)
    }

    private var faintDot: some View {
        Circle()
            .fill(LightAnchorTheme.recessed)
            .frame(width: 9, height: 9)
    }

    private func ghostRow(leadingDot: AnyView, opacity: Double) -> some View {
        HStack(spacing: 10) {
            leadingDot
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(LightAnchorTheme.recessed)
                    .frame(width: 124, height: 7)
                Capsule()
                    .fill(LightAnchorTheme.recessed)
                    .frame(width: 78, height: 6)
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(LightAnchorTheme.recessed)
                .frame(width: 34, height: 7)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
        .opacity(opacity)
    }
}

extension CaptureKind {
    var iconName: String {
        switch self {
        case .text: "text.cursor"
        case .voice: "mic"
        case .screenshot: "viewfinder"
        case .link: "link"
        case .fileReference: "doc"
        }
    }

    var accentColor: LightAnchorThemeColor {
        switch self {
        case .text: LightAnchorTheme.chartWarm
        case .voice: LightAnchorTheme.chartAmber
        case .screenshot: LightAnchorTheme.chartYellow
        case .link: LightAnchorTheme.highlight
        case .fileReference: LightAnchorTheme.iconSubtle
        }
    }
}

extension SceneItemKind {
    var iconName: String {
        switch self {
        case .file: "doc"
        case .link: "globe"
        case .terminal: "terminal"
        case .application: "app.dashed"
        }
    }
}

// MARK: - 列表页组件（样机 .readout / .segsoft / .listpanel / .row / .grouphead）

/// 样机 .readout：15/650 眉题 + 12.5 灰说明 + 右侧计数（数字文字蓝）。
struct LightAnchorReadout<Trailing: View>: View {
    let eyebrow: String
    let status: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ eyebrow: String, status: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.eyebrow = eyebrow
        self.status = status
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(eyebrow)
                .font(LightAnchorTheme.interfaceFont(size: 15, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(status)
                .font(LightAnchorTheme.supportingFont(size: 12.5))
                .foregroundStyle(LightAnchorTheme.mutedInk)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 14, trailing: 2))
    }
}

extension LightAnchorReadout where Trailing == EmptyView {
    init(_ eyebrow: String, status: String) {
        self.init(eyebrow, status: status) { EmptyView() }
    }
}

/// readout 右侧的「N 项」计数（数字文字蓝）。
/// 「3 项」式的单值计数。原来还有一个「可返回 3 · 等结果中 2」的多段初始化器，
/// 只有等待页在用；等待并进稍后之后那种读数没有了（分组自己报数）。
struct LightAnchorReadoutCount: View {
    let value: Int
    let unit: String

    init(_ value: Int, unit: String? = nil) {
        self.value = value
        self.unit = unit ?? tr("unit_items")
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.accentInk)
            if !unit.isEmpty {
                Text(unit)
                    .font(LightAnchorTheme.supportingFont(size: 12.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
            }
        }
    }
}

/// 样机 .segsoft：凹陷小药盒分段，选中 = 白卡 + 浅影。
struct LightAnchorSegSoft<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                LightAnchorSegSoftButton(
                    title: title(option),
                    isSelected: option == selection
                ) {
                    selection = option
                }
            }
        }
        .padding(3)
        .background(
            LightAnchorTheme.recessed,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(LightAnchorTheme.sidebarHairline, lineWidth: 1)
        }
        // 不带外边距：组件自带的 bottom 14 曾把胶囊重心抬得比同行标签高 7pt
        // （HStack 居中对齐的是「带垫的框」），行距和对齐都交给调用处。
        .accessibilityElement(children: .contain)
    }
}

private struct LightAnchorSegSoftButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LightAnchorTheme.controlFont(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(
                    isSelected || isHovered ? LightAnchorTheme.ink : LightAnchorTheme.mutedInk
                )
                .padding(.horizontal, 14)
                .frame(height: 25)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LightAnchorTheme.surface)
                            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 样机 .listpanel：白卡（圆角 14 + 发丝边 + 浅影），铺满可用宽度
/// （随窗口变化，不写死），行之间由 LightAnchorRowSeparator 画内缩发丝线。
struct LightAnchorListPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 样机 .row + .row::before：行间内缩 18 的发丝线。
struct LightAnchorRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(LightAnchorTheme.hairlineBorder.opacity(0.7))
            .frame(height: 1)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }
}

enum LightAnchorListRowVariant {
    case plain
    /// 样机 .row.found：水洗蓝底 + 左缘蓝条（选中/命中）。
    case found
    /// 样机 .row.frost：整行 55% 透明，悬停回到 85%。
    case frost
}

/// 样机 .row 外衣：padding 12/18、悬停 recess、found/frost 变体。
struct LightAnchorListRowChrome: ViewModifier {
    var variant: LightAnchorListRowVariant = .plain

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if variant == .found {
                    Rectangle().fill(LightAnchorTheme.accentWash)
                } else if isHovered {
                    Rectangle().fill(LightAnchorTheme.recessed)
                }
            }
            .overlay(alignment: .leading) {
                if variant == .found {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(LightAnchorTheme.primary)
                        .frame(width: 2)
                        .padding(.vertical, 12)
                }
            }
            .opacity(variant == .frost ? (isHovered ? 0.85 : 0.55) : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovered)
    }
}

extension View {
    func lightAnchorListRow(_ variant: LightAnchorListRowVariant = .plain) -> some View {
        modifier(LightAnchorListRowChrome(variant: variant))
    }
}

/// 侧栏导航图标：Lucide 细线单色。彩色家族已废弃——六个色各不相同太花，
/// macOS 原生侧栏（Finder/Mail）也是单色，层级靠选中行的底色而不是靠图标变色。
/// 颜色跟随 foregroundStyle，由调用方按选中态给（选中转正文墨、未选暖灰）。
/// 五个字形都是正面平视、密度相近——等轴测的 3D 盒子（package/box/container）
/// 混进来会散，别换。隐喻：对焦框=现在、工具箱=稍后、
/// 积木块=环境、倒转时钟=使用回顾、圆气泡=对话。
struct LightAnchorDestinationIcon: View {
    let destination: WorkspaceDestination
    var size: CGFloat = 17
    /// 24 网格里的线宽。Lucide 原稿是 2，侧栏收细到 1.75 才配得上 13.5pt 的标签。
    var lineWidth: CGFloat = 1.75

    var body: some View {
        LightAnchorNavGlyphShape(glyph: Self.glyph(for: destination))
            .stroke(
                style: StrokeStyle(
                    lineWidth: lineWidth * size / 24,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func glyph(for destination: WorkspaceDestination) -> LightAnchorNavGlyph {
        switch destination {
        case .now: .focus
        case .later: .toolCase
        case .environments: .blocks
        case .review: .rotateCcwClock
        case .chat: .messageCircle
        }
    }
}

/// 把 24 网格的字形等比放进给定矩形。单独抽成 Shape 才能用 SwiftUI 原生的
/// .stroke——描边宽度和端点样式交给 StrokeStyle，颜色交给 foregroundStyle。
struct LightAnchorNavGlyphShape: Shape {
    let glyph: LightAnchorNavGlyph

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return glyph.path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// 标签小胶囊（#名字）：选中 = 水洗蓝底 + 文字蓝，未选 = 凹陷米灰。
struct LightAnchorTagChip: View {
    let tag: String
    var isSelected = false
    var action: (() -> Void)? = nil

    var body: some View {
        let label = Text(tag)
            .font(LightAnchorTheme.controlFont(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? LightAnchorTheme.accentInk : LightAnchorTheme.mutedInk)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                isSelected ? LightAnchorTheme.accentWash : LightAnchorTheme.recessed,
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? LightAnchorThemeColor.clear : LightAnchorTheme.sidebarHairline,
                        lineWidth: 1
                    )
            }
            .contentShape(Capsule(style: .continuous))
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            label
        }
    }
}

/// 标签选择弹窗：敲一个新名字回车添加，或点选已有标签。
struct LightAnchorTagPicker: View {
    @Binding var selected: [String]
    let knownTags: [String]

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// 已选里可能有还没保存进任何捕获的新标签——合并显示。
    private var options: [String] {
        var seen = Set<String>()
        return (selected + knownTags).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(tr("new_tag_press_return"), text: $draft)
                .textFieldStyle(LightAnchorTextFieldStyle())
                .focused($fieldFocused)
                .onSubmit(addDraft)

            if options.isEmpty {
                Text(tr("no_tags_yet_type_a_name"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(options, id: \.self) { tag in
                        LightAnchorTagChip(
                            tag: "#\(tag)",
                            isSelected: selected.contains(tag)
                        ) {
                            if selected.contains(tag) {
                                selected.removeAll { $0 == tag }
                            } else {
                                selected.append(tag)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear { fieldFocused = true }
    }

    private func addDraft() {
        guard let tag = CaptureItem.normalizedTags([draft]).first else { return }
        if !selected.contains(tag) {
            selected.append(tag)
        }
        draft = ""
    }
}

/// 中性组标签（样机 .setgroup-label 语感）：12.5/550 淡墨，
/// 用于 listpanel 之上不需要语义色的分组名。
/// 不带下边距：在「标签 + 控件」的组头行里，自带垫会让居中对齐
/// 对到「带垫的框」上，文字视觉上沉下去；行距由调用处统一给。
struct LightAnchorSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(LightAnchorTheme.interfaceFont(size: 12.5, weight: .medium))
            .foregroundStyle(LightAnchorTheme.faintInk)
            .padding(.leading, 2)
    }
}
