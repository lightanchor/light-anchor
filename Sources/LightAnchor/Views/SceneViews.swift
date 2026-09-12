import SwiftUI

import AppKit

// MARK: - 剪贴板复写条与截图行（重返面板和回顾卡共用）

/// 剪贴板 · 复写条（设计稿 docs/design/clipboard-history-row-2026-09-03.html 丁案）。
/// 这段事里复制过的文字按「连续做事的一段」一张纸，放下再回来是新的一张，纸与纸
/// 之间真的撕开（半圆齿边），撕口一句放下了多久。等宽字，命令 / 路径 / 代码最好读。
/// 头一张的第一行就是放下那一刻手上的那条，放回常显；其余行 hover 现身。
/// 放下那一刻没读到剪贴板、这段事也没复制过时整块不出现。
struct SceneClipboardStrips: View {
    let snapshot: SceneSnapshot
    @EnvironmentObject private var workspace: AttentionWorkspace
    @State private var strips: [ClipboardStrip] = []
    @State private var isExpanded = false

    /// 收起时只露头一张纸的前几行；再多就折成「再看 N 行」。
    private static let collapsedLineLimit = 4

    private struct RefreshKey: Equatable {
        let snapshotID: UUID
        let clipboardText: String
        let revision: Int
    }

    var body: some View {
        if workspace.hasClipboardContent(snapshot) {
            content
                .task(id: RefreshKey(
                    snapshotID: snapshot.id,
                    clipboardText: snapshot.clipboardText,
                    revision: workspace.clipboardHistoryRevision
                )) {
                    strips = workspace.clipboardStrips(for: snapshot)
                }
        }
    }

    private var lineCount: Int { strips.reduce(0) { $0 + $1.entries.count } }

    /// 收起：头一张纸截到上限，其余纸不画。展开：全画。
    private var visibleStrips: [ClipboardStrip] {
        guard !isExpanded, lineCount > Self.collapsedLineLimit, let head = strips.first else {
            return strips
        }
        return [ClipboardStrip(
            entries: Array(head.entries.prefix(Self.collapsedLineLimit)),
            pauseAfter: nil
        )]
    }

    private var hiddenLineCount: Int {
        lineCount - visibleStrips.reduce(0) { $0 + $1.entries.count }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("clipboard_strip_title"))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Spacer(minLength: 8)
                Text(String(format: tr("clipboard_strip_lines"), lineCount))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .monospacedDigit()
            }

            ForEach(Array(visibleStrips.enumerated()), id: \.element.id) { index, strip in
                if index > 0, let pause = strip.pauseAfter {
                    tearLabel(pause: pause)
                }
                ClipboardStripView(
                    strip: strip,
                    isHead: index == 0,
                    tornTop: index > 0,
                    tornBottom: index < visibleStrips.count - 1
                )
            }

            if hiddenLineCount > 0 || isExpanded, lineCount > Self.collapsedLineLimit {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded
                        ? tr("clipboard_strip_collapse")
                        : String(format: tr("clipboard_strip_show_more"), hiddenLineCount))
                        .font(LightAnchorTheme.supportingFont(size: 11))
                        .foregroundStyle(LightAnchorTheme.faintInk)
                        .padding(.leading, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 撕口之间的一句：两侧虚线夹着「放下了 42 分钟」。
    private func tearLabel(pause: TimeInterval) -> some View {
        let minutes = Int(pause / 60)
        let duration = minutes < 1 ? tr("under_a_minute") : UserFacingCopy.focusDuration(minutes)
        return HStack(spacing: 10) {
            tearDash
            Text(String(format: tr("clipboard_strip_set_down_for"), duration))
                .font(LightAnchorTheme.supportingFont(size: 11))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .fixedSize()
            tearDash
        }
        .padding(.horizontal, 14)
    }

    private var tearDash: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay {
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 10_000, y: 0))
                }
                .stroke(LightAnchorTheme.hairlineBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .clipped()
            }
    }
}

/// 一张复写纸：左缘一道竹签（头一张是蓝点的蓝；设计层禁阴影，稿里的蓝影不落地），
/// 行是 时刻 · 文字 · 来源 · 放回。
struct ClipboardStripView: View {
    let strip: ClipboardStrip
    let isHead: Bool
    let tornTop: Bool
    let tornBottom: Bool

    @State private var hoveredID: UUID?
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(strip.entries.enumerated()), id: \.element.id) { index, entry in
                line(entry, isCurrent: isHead && index == 0)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, tornTop ? 12 : (isHead ? 10 : 8))
        .padding(.bottom, tornBottom ? 12 : 8)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isHead ? AnyShapeStyle(LightAnchorTheme.primary) : AnyShapeStyle(LightAnchorTheme.faintInk.opacity(0.6)))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .background {
            TornStripShape(tornTop: tornTop, tornBottom: tornBottom)
                .stroke(LightAnchorTheme.hairlineBorder, lineWidth: 1)
        }
    }

    private func line(_ entry: ClipboardHistoryEntry, isCurrent: Bool) -> some View {
        let isCopied = copiedID == entry.id
        let showsPutBack = isCurrent || hoveredID == entry.id || isCopied
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(LightAnchorTheme.monoFont(size: 10.5))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
            Text(entry.text)
                .font(LightAnchorTheme.monoFont(size: isCurrent ? 13 : 12))
                .foregroundStyle(LightAnchorTheme.ink)
                .lineLimit(isCurrent ? 3 : 1)
                .truncationMode(.tail)
                .help(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isCurrent, !entry.sourceApplication.isEmpty {
                Text(entry.sourceApplication)
                    .font(LightAnchorTheme.supportingFont(size: 10.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
            }
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.text, forType: .string)
                copiedID = entry.id
            } label: {
                Text(isCopied ? tr("put_back") : tr("put_back_short"))
                    .font(LightAnchorTheme.controlFont(size: 11, weight: .medium))
                    .foregroundStyle(LightAnchorTheme.accentInk)
            }
            .buttonStyle(.plain)
            .disabled(isCopied)
            .opacity(showsPutBack ? 1 : 0)
            .accessibilityLabel(tr("put_back_on_clipboard"))
        }
        .padding(.vertical, isCurrent ? 3 : 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
        }
    }
}

/// 复写纸的边：直角圆 3；被撕开的那一边是一排半圆齿（间距 12，齿半径 4.5）。
/// 半圆用三次贝塞尔近似，绕开 addArc 在翻转坐标系里的方向歧义。
struct TornStripShape: Shape {
    var tornTop: Bool
    var tornBottom: Bool

    private static let cornerRadius: CGFloat = 3
    private static let pitch: CGFloat = 12
    private static let notchRadius: CGFloat = 4.5
    /// 半圆的贝塞尔控制点伸出量（≈ 4/3 · r）。
    private static let bulge: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = Self.cornerRadius
        let notchCount = max(0, Int(rect.width / Self.pitch))
        let inset = (rect.width - CGFloat(notchCount) * Self.pitch) / 2
        func notchCenterX(_ index: Int) -> CGFloat {
            rect.minX + inset + Self.pitch / 2 + CGFloat(index) * Self.pitch
        }

        // 上边：从左到右。
        if tornTop {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            for index in 0..<notchCount {
                let cx = notchCenterX(index)
                path.addLine(to: CGPoint(x: cx - Self.notchRadius, y: rect.minY))
                path.addCurve(
                    to: CGPoint(x: cx + Self.notchRadius, y: rect.minY),
                    control1: CGPoint(x: cx - Self.notchRadius, y: rect.minY + Self.bulge),
                    control2: CGPoint(x: cx + Self.notchRadius, y: rect.minY + Self.bulge)
                )
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // 右边。
        path.addLine(to: CGPoint(x: rect.maxX, y: tornBottom ? rect.maxY : rect.maxY - r))

        // 下边：从右到左。
        if tornBottom {
            for index in stride(from: notchCount - 1, through: 0, by: -1) {
                let cx = notchCenterX(index)
                path.addLine(to: CGPoint(x: cx + Self.notchRadius, y: rect.maxY))
                path.addCurve(
                    to: CGPoint(x: cx - Self.notchRadius, y: rect.maxY),
                    control1: CGPoint(x: cx + Self.notchRadius, y: rect.maxY - Self.bulge),
                    control2: CGPoint(x: cx - Self.notchRadius, y: rect.maxY - Self.bulge)
                )
            }
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        }

        // 左边回到起点。
        path.closeSubpath()
        return path
    }
}

/// 采集瞬间的桌面截图缩略图，点击用系统看图打开。文件不在了就整行不显示。
struct SceneScreenshotRow: View {
    let assetURL: URL?

    private var availableURL: URL? {
        guard let assetURL,
              FileManager.default.fileExists(atPath: assetURL.path)
        else { return nil }
        return assetURL
    }

    var body: some View {
        if let url = availableURL, let image = NSImage(contentsOf: url) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LightAnchorTheme.subtleBorder.opacity(0.72), lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("desktop_when_you_switched_away"))
                            .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                        Text(tr("click_to_view_full_size"))
                            .font(LightAnchorTheme.supportingFont(size: 11))
                            .foregroundStyle(LightAnchorTheme.faintInk)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LightAnchorTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(tr("view_the_desktop_screenshot_from_when"))
        }
    }
}

// MARK: - 现场条目行

struct SceneItemRow: View {
    let item: SceneItem
    var isTucked: Bool = false
    var onAddBack: (() -> Void)? = nil
    /// 手动剔除（现场卡 / 「已放下」确认卡）：现场里不需要的条目由用户删。
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            SceneItemIconView(item: item, isTucked: isTucked)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(LightAnchorTheme.bodyFont(size: 13, weight: .medium))
                    .foregroundStyle(isTucked ? LightAnchorTheme.faintInk : LightAnchorTheme.ink)
                    .lineLimit(1)
                    // 被截的是文件名/网址尾部，tooltip 留住完整值。
                    .help(item.title)
                if !item.sourceApplication.isEmpty || !item.detail.isEmpty {
                    HStack(spacing: 4) {
                        if !item.sourceApplication.isEmpty {
                            Text(item.sourceApplication)
                        }
                        if !item.sourceApplication.isEmpty && !item.detail.isEmpty {
                            Text("·")
                        }
                        if !item.detail.isEmpty {
                            Text(item.detail)
                        }
                    }
                    .font(LightAnchorTheme.supportingFont(size: 11))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .lineLimit(1)
                    .help([item.sourceApplication, item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }

            Spacer()

            if isTucked, let onAddBack {
                Button {
                    onAddBack()
                } label: {
                    LightAnchorIcon("plus", size: 14)
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                .help(tr("add_back_to_scene"))
                .accessibilityLabel(tr("add_back_to_scene"))
            }

            if let onRemove {
                Button {
                    onRemove()
                } label: {
                    LightAnchorIcon("x", size: 13)
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
                .help(tr("remove_from_scene"))
                .accessibilityLabel(tr("remove_from_scene"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 白面行也要说圆角语言：直角白条在米灰卡里是全应用唯一的方角，扎眼。
        .background(
            isTucked ? LightAnchorThemeColor.clear : LightAnchorTheme.surface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

// MARK: - 「已放下」确认弹窗

/// 放下一件事（暂时放下 / 换一件事）后的确认 sheet（用户定：要弹窗形式）。
/// 内容按「放下这一刻要什么」组织：这段专注了多久（收个尾）、趁记忆
/// 还热写下「回来先看」、现场收了什么（点一样东西＝不带它走）。
///
/// 版式照「现在」页的定稿（docs/now-page-scrollrail-2026-09-09.html）：
/// 状态行 + 大标题 + 一句注，现场那两张卡与「东西在哪」那一节逐像素同源，
/// 主键是唯一一枚墨黑实心。没有米色凹槽底、没有眉标瓦片。
///
/// 弹窗在**放下那一刻**就出现，现场清单等采集落盘后自己长出来——
/// 等采完再弹，用户早已开始下一件事，那张卡看着就像凭空冒出来的。
struct RecentSetAsideSheet: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.dismiss) private var dismiss
    let info: AttentionWorkspace.RecentSetAside

    @State private var cueDraft = ""
    /// 打开时已有的「回来先看」（AI 草拟或早先写的）：没改就不写回。
    @State private var loadedCue = ""
    /// 弹窗的正事就是趁记忆热写这句话：打开即聚焦，写完回车就是「知道了」。
    @FocusState private var cueFocused: Bool

    /// 快照认目标读，不认打开弹窗时那一份 info：采集落盘后 workspace 一变，
    /// 这里就自己拿到新的那份。
    private var aside: AttentionWorkspace.RecentSetAside? {
        workspace.recentSetAside?.targetID == info.targetID ? workspace.recentSetAside : info
    }

    private var sceneSnapshot: SceneSnapshot? {
        guard let snapshotID = aside?.snapshotID else { return nil }
        return workspace.snapshot.sceneSnapshots[snapshotID]
    }

    /// 现场还在采：清单先空着，别拿上一段那份冒充这一段。
    private var isCollectingScene: Bool {
        aside?.snapshotID == nil
    }

    private var episode: AttentionEpisode? {
        workspace.snapshot.latestEpisode(of: info.targetID)
    }

    /// 这段的专注时长：0 分钟就不硬凑一句。
    private var focusLabel: String? {
        guard let episode else { return nil }
        let minutes = workspace.snapshot.focusMinutes(of: episode.id)
        guard minutes > 0 else { return nil }
        return UserFacingCopy.focusDuration(minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            cueBlock
            sceneSection
            LightAnchorSheetActionBar {
                Button(tr("got_it")) {
                    commitCue()
                    dismiss()
                }
                .buttonStyle(LightAnchorSolidButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        // 640 而不是原来的 480：清单网格在这个宽度上排得开两列，七八样东西
        // 一眼看全，不必先滚一遍才知道收了什么。
        .frame(width: 640)
        .onAppear {
            let cue = sceneSnapshot?.returnCue ?? episode?.returnCue ?? ""
            cueDraft = cue
            loadedCue = cue
            cueFocused = true
        }
        // AI 草拟的那句要等采集落盘才有：只在用户还没动笔时替他填上。
        .onChange(of: sceneSnapshot?.returnCue) { _, drafted in
            guard let drafted, !drafted.isEmpty, cueDraft.isEmpty else { return }
            cueDraft = drafted
            loadedCue = drafted
        }
        // Esc / 点外面关掉也不丢刚写的话。
        .onDisappear(perform: commitCue)
    }

    // MARK: - 头

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                LightAnchorStatusDot(LightAnchorStatusDotForm.paused, size: 9)
                Text(tr("set_aside_sheet_status"))
                    .font(LightAnchorTheme.bodyFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                if let focusLabel {
                    Circle()
                        .fill(LightAnchorTheme.iconDisabledStrong)
                        .frame(width: 3, height: 3)
                        .accessibilityHidden(true)
                    Text(String(format: tr("set_aside_sheet_focus"), focusLabel))
                        .font(LightAnchorTheme.supportingFont(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                }
            }
            Text(info.targetName)
                .font(LightAnchorTheme.titleFont(size: 22, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(tr("set_aside_sheet_meta"))
                .font(LightAnchorTheme.bodyFont(size: 13.5))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 回来先看

    /// 一块水洗蓝，和「现在」页上那块是同一件东西——这里是可写的那一面。
    private var cueBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(tr("look_at_this_first"))
                .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(LightAnchorTheme.accentInk)
            TextField(tr("what_to_look_at_first_2"), text: $cueDraft)
                .textFieldStyle(LightAnchorTextFieldStyle())
                .focused($cueFocused)
                .onSubmit {
                    commitCue()
                    dismiss()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            LightAnchorTheme.accentWash,
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                .strokeBorder(LightAnchorTheme.accentInk.opacity(0.18), lineWidth: 1)
        }
    }

    // MARK: - 现场

    @ViewBuilder
    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowChapterHead(
                title: tr("scene"),
                detail: sceneSnapshot.map { NowSceneSection.tallyLine(of: $0) }
                    ?? (isCollectingScene ? tr("set_aside_sheet_collecting") : "")
            ) {
                EmptyView()
            }

            if let snapshot = sceneSnapshot, !snapshot.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        NowThingsCard(snapshot: snapshot)
                            .environmentObject(workspace)
                        NowClipboardCard(snapshot: snapshot)
                            .environmentObject(workspace)
                    }
                    .padding(.vertical, 1)
                }
                // 320 放得下五六行不裁；再多从整行边界起卷。
                .frame(maxHeight: 320)
                .scrollIndicators(.never)
            } else if !isCollectingScene {
                Text(tr("set_aside_sheet_nothing_collected"))
                    .font(LightAnchorTheme.bodyFont(size: 13.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func commitCue() {
        let trimmed = cueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loadedCue else { return }
        // 段上的「回来先看」是这句话的家；现场快照是它的另一个落点，有就一起更新
        // （放下那一刻快照往往还没落盘，所以先写段，别把话丢了）。
        if let episode {
            _ = workspace.updateContext(for: episode.id, context: episode.context, returnCue: trimmed)
        }
        if let snapshot = sceneSnapshot {
            _ = workspace.updateSceneReturnCue(snapshot.id, returnCue: trimmed)
        }
        loadedCue = trimmed
    }
}

// MARK: - 现场条目图标

/// 线框图标坐进 17pt 圆角瓦片：与真实应用图标同一个剪影和尺寸，
/// 混排在同一列里天然对齐（裸线框和实心应用图标怎么调字号都对不齐）。
struct SceneGlyphTile: View {
    let name: String
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(LightAnchorTheme.recessed)
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            LightAnchorIcon(name, size: 11)
                .foregroundStyle(dimmed ? LightAnchorTheme.faintInk : LightAnchorTheme.mutedInk)
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

/// 现场条目的图标：能认出真实来源就用系统里的真图标——应用条目直接是
/// 应用图标，终端/网页跟来源应用走，文件用文件本身的图标；认不出（应用
/// 已卸载、演示数据等）退回同尺寸的线框瓦片。
private struct SceneItemIconView: View {
    let item: SceneItem
    var isTucked: Bool = false

    var body: some View {
        if let image = SceneItemIconResolver.icon(for: item) {
            // 17pt：应用图标自带内边距，画到 17 视觉上才和瓦片同一量级。
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .saturation(isTucked ? 0 : 1)
                .opacity(isTucked ? 0.55 : 1)
                .accessibilityHidden(true)
        } else {
            SceneGlyphTile(name: item.kind.iconName, dimmed: isTucked)
        }
    }
}

/// 只在主线程的视图渲染路径里被调用，缓存也就锚在 MainActor 上。
@MainActor
enum SceneItemIconResolver {
    /// 每分钟的 TimelineView 重渲染会反复走到这里，查一次记一次；
    /// NSCache 自己管内存压力下的淘汰。
    private static let cache = NSCache<NSString, NSImage>()
    /// 查过且没查到的键也要记住，否则每帧都去扫 runningApplications。
    private static var misses = Set<String>()

    static func icon(for item: SceneItem) -> NSImage? {
        let key = "\(item.kind.rawValue)|\(item.address)|\(item.sourceApplication)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        guard let image = resolve(item) else {
            misses.insert(key)
            return nil
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func resolve(_ item: SceneItem) -> NSImage? {
        let workspace = NSWorkspace.shared
        switch item.kind {
        case .application:
            if let url = workspace.urlForApplication(withBundleIdentifier: item.address) {
                return workspace.icon(forFile: url.path)
            }
            return appIcon(named: item.sourceApplication)
        case .terminal:
            return appIcon(named: item.sourceApplication)
        case .file:
            if let url = fileURL(from: item.address),
               FileManager.default.fileExists(atPath: url.path) {
                return workspace.icon(forFile: url.path)
            }
            return appIcon(named: item.sourceApplication)
        case .link:
            if let icon = appIcon(named: item.sourceApplication) { return icon }
            // 来源浏览器认不出时退而求其次：这个网址的默认打开方。
            if let url = URL(string: item.address),
               let handler = workspace.urlForApplication(toOpen: url) {
                return workspace.icon(forFile: handler.path)
            }
            return nil
        }
    }

    private static func fileURL(from address: String) -> URL? {
        if address.hasPrefix("file://") { return URL(string: address) }
        if address.hasPrefix("/") { return URL(fileURLWithPath: address) }
        return nil
    }

    /// 按来源应用名找图标：先在正在运行的应用里找（现场条目的来源多半
    /// 还开着，且 localizedName 与采集时记下的名字同源），退出了再去
    /// 常见安装位置按 .app 名兜底。
    private static func appIcon(named name: String) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return app.icon
        }
        for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                          "\(NSHomeDirectory())/Applications"] {
            let path = "\(directory)/\(trimmed).app"
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }
}

/// 现场按什么口径采：这件事自己的口径压过全局默认（全局默认在「智能」设置里）。
/// 章头上的一枚小字菜单——不是带框的下拉，跟邻位的「全不带 / 全带上」同一种嗓音。
struct NowSceneFilterLink: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let targetID: UUID
    @State private var hovered = false

    private var mode: SceneFilterMode {
        workspace.snapshot.targets[targetID]?.sceneFilterMode
            ?? workspace.intelligencePreferences.sceneFilterDefault
    }

    var body: some View {
        Menu {
            Picker(tr("scene_filter_2"), selection: Binding(
                get: { mode },
                set: { newMode in
                    guard newMode != mode else { return }
                    _ = workspace.updateSceneFilterMode(for: targetID, mode: newMode)
                    // 改了口径就照新口径再采一次，否则选了跟没选一样。只有手上
                    // 这件事能重采——翻着旧的一段时不该把那份历史现场覆盖掉。
                    guard let current = workspace.currentEpisode, current.targetID == targetID else { return }
                    Task { _ = await workspace.captureSceneSnapshot(for: current.id, refreshingContext: true) }
                }
            )) {
                ForEach(SceneFilterMode.allCases, id: \.self) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(mode.title)
                    .font(LightAnchorTheme.controlFont(size: 12.5, weight: .medium))
                LightAnchorIcon("chevron-down", size: 8)
            }
            .foregroundStyle(hovered ? LightAnchorTheme.ink : LightAnchorTheme.mutedInk)
            .lineLimit(1)
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(tr("scene_filter_2"))
        .accessibilityLabel(String(format: tr("scene_filter"), mode.title))
    }
}

// MARK: - 筛选模式切换

struct SceneFilterPicker: View {
    let mode: SceneFilterMode
    let onChange: (SceneFilterMode) -> Void
    @State private var selection: SceneFilterMode

    init(mode: SceneFilterMode, onChange: @escaping (SceneFilterMode) -> Void) {
        self.mode = mode
        self.onChange = onChange
        _selection = State(initialValue: mode)
    }

    var body: some View {
        // 铺满整行：标题贴左缘、控件贴右缘，与设置页其他 .setrow 对齐
        // （fixedSize 会让整行缩成一团浮在卡片中间）。
        LightAnchorSelectField(
            tr("filter_scene"),
            selection: $selection,
            options: SceneFilterMode.allCases,
            titleForValue: { $0.title }
        )
        .onChange(of: selection) { _, newValue in
            guard newValue != mode else { return }
            onChange(newValue)
        }
        .onChange(of: mode) { _, newValue in
            selection = newValue
        }
    }
}

// MARK: - 回场简报

/// 简报三行：你在哪 / 发生了什么 / 先做什么。
struct ReturnBriefingRows: View {
    let briefing: ReturnBriefing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(tr("where_you_were"), briefing.whereYouWere)
            row(tr("what_happened"), briefing.whatHappened)
            row(tr("first_step"), briefing.firstStep)
        }
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(LightAnchorTheme.supportingFont(size: 11, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .frame(width: 78, alignment: .leading)
            Text(text)
                .font(LightAnchorTheme.bodyFont(size: 13))
                .lineSpacing(3)
                .foregroundStyle(LightAnchorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 一键重返确认面板

/// 「重返现场」：铺回哪些东西由你逐条定。
///
/// 形态与「现在」页、「换一件事」的现场页同源（定稿 `now-page-scrollrail` /
/// `switch-work-redesign-r24`）：一句回场简报住在浅蓝块里，清单是一张白卡
/// （卡头报数与两枚全选，卡体是行首带记号的网格），剪贴板是一列复写行。
/// 被否过的形态不要回头：按类别分组的米灰凹槽、复选框、只能整类勾选。
struct SceneReturnPanel: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    let snapshot: SceneSnapshot
    /// 如果这次重返是为了解决一个等待结果，传入其 ID——恢复时会把等待标记为已解决并激活原 episode。
    var waitingID: UUID? = nil
    let onRestore: () -> Void
    let onCancel: () -> Void

    /// 这次不开的那些（逐条划掉，不再是整类勾选）。
    @State private var struckItemIDs: Set<UUID> = []
    @State private var staleness: [UUID: SceneItemStaleness] = [:]
    @State private var isRestoring = false
    @State private var briefing: ReturnBriefing?
    @State private var showingEnvironmentEditor = false
    @State private var strips: [ClipboardStrip] = []

    private var items: [SceneItem] { snapshot.restorableItems }
    private var reopening: Int { items.count - struckItemIDs.count }

    private var tally: String {
        NowSceneSection.displayOrder
            .compactMap { kind in
                let count = items.filter { $0.kind == kind }.count
                return count > 0 ? "\(kind.title) \(count)" : nil
            }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    guidance
                    itemsCard
                    clipboardCard
                    SceneScreenshotRow(assetURL: snapshot.screenshotAssetURL)
                    if staleness.values.contains(where: { $0.isActionable }) {
                        stalenessWarnings
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 2)
            }
            .scrollIndicators(.never)

            foot
        }
        .padding(EdgeInsets(top: 26, leading: 26, bottom: 20, trailing: 26))
        .frame(width: 620)
        .onAppear {
            if workspace.intelligencePreferences.checkSceneStaleness {
                staleness = SceneStalenessChecker.checkAll(items)
            }
            strips = workspace.hasClipboardContent(snapshot)
                ? workspace.clipboardStrips(for: snapshot)
                : []
            loadBriefing()
        }
        .sheet(isPresented: $showingEnvironmentEditor) {
            EnvironmentEditorView(
                profile: nil,
                draft: EnvironmentSnapshotBuilder.draft(from: snapshot)
            )
            .environmentObject(workspace)
        }
    }

    // MARK: 头

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("scene_snapshot"))
                .font(LightAnchorTheme.supportingFont(size: 10.5, weight: .semibold))
                .kerning(1.7)
                .foregroundStyle(LightAnchorTheme.accentInk)
            Text(tr("return_to_the_scene"))
                .font(LightAnchorTheme.interfaceFont(size: 18.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .padding(.top, 6)
            Text(String(
                format: tr("scene_return_meta"),
                snapshot.capturedAt.formatted(date: .omitted, time: .shortened),
                items.count,
                reopening,
                items.count - reopening
            ))
            .font(LightAnchorTheme.supportingFont(size: 13))
            .monospacedDigit()
            .foregroundStyle(LightAnchorTheme.mutedInk)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 一句话：回场简报，没有就是那句「回来先看」

    @ViewBuilder
    private var guidance: some View {
        if let briefing {
            washBlock { ReturnBriefingRows(briefing: briefing) }
        } else if !snapshot.returnCue.isEmpty {
            washBlock {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("look_at_this_first"))
                        .font(LightAnchorTheme.supportingFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(LightAnchorTheme.accentInk)
                    Text(snapshot.returnCue)
                        .font(LightAnchorTheme.bodyFont(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(LightAnchorTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func washBlock(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LightAnchorTheme.accentWash,
                in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LightAnchorDesign.radiusCard, style: .continuous)
                    .strokeBorder(LightAnchorTheme.accentInk.opacity(0.18), lineWidth: 1)
            }
    }

    // MARK: 清单

    private var itemsCard: some View {
        NowCard {
            Text(tr("switch_things_to_reopen"))
                .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
                .fixedSize()
            Text(tally.isEmpty
                ? String(format: tr("scene_tally_plain"), items.count, reopening)
                : String(format: tr("switch_scene_tally"), items.count, tally, tr("switch_kept_reopen"), reopening))
                .font(LightAnchorTheme.supportingFont(size: 12))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(tr("switch_hint_dont_open_it"))
                .font(LightAnchorTheme.supportingFont(size: 11.5))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .lineLimit(1)
                // 提示让位给右边两枚动作：挤不下先截提示，别把按钮挤成两行。
                .layoutPriority(-1)
            Button(tr("switch_restore_none")) { struckItemIDs = Set(items.map(\.id)) }
                .buttonStyle(LightAnchorInlineButtonStyle())
            Button(tr("switch_restore_all")) { struckItemIDs = [] }
                .buttonStyle(LightAnchorInlineButtonStyle())
        } content: {
            SceneThingsGrid(
                items: items,
                isOff: { struckItemIDs.contains($0.id) },
                placeText: { place(of: $0) },
                takeTitle: tr("switch_st_take_open"),
                dropTitle: tr("switch_st_skip"),
                toggle: { struckItemIDs.formSymmetricDifference([$0.id]) }
            )
            .padding(4)
        }
    }

    /// 位置那行：失效的说清为什么（文件没了 / 应用可能已卸载），
    /// 划掉的说「这次不开」，终端报命令，其余报来源。
    private func place(of item: SceneItem) -> String {
        if let stale = staleness[item.id], case .missing(let reason) = stale { return reason }
        if struckItemIDs.contains(item.id) { return tr("switch_st_skip_this_time") }
        if !item.detail.isEmpty { return item.detail }
        return item.sourceApplication
    }

    @ViewBuilder
    private var clipboardCard: some View {
        if !strips.isEmpty {
            NowCard {
                Text(tr("clipboard_then"))
                    .font(LightAnchorTheme.supportingFont(size: 12.5, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .fixedSize()
                Text(String(
                    format: tr("clipboard_count"),
                    strips.reduce(0) { $0 + $1.entries.count }
                ))
                .font(LightAnchorTheme.supportingFont(size: 12))
                .monospacedDigit()
                .foregroundStyle(LightAnchorTheme.mutedInk)
                Spacer(minLength: 8)
                Button(tr("clipboard_copy_all")) {
                    let text = strips.flatMap(\.entries).map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    workspace.presentNotice(tr("clipboard_all_copied"))
                }
                .buttonStyle(LightAnchorInlineButtonStyle())
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(strips.enumerated()), id: \.element.id) { index, strip in
                        if index > 0, let pause = strips[index - 1].pauseAfter {
                            NowClipboardGap(pause: pause)
                        }
                        ForEach(Array(strip.entries.enumerated()), id: \.element.id) { row, entry in
                            NowClipboardRow(entry: entry, isLatest: index == 0 && row == 0)
                                .environmentObject(workspace)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private var stalenessWarnings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                LightAnchorIcon("alert-triangle", size: 13)
                    .foregroundStyle(LightAnchorTheme.warning)
                Text(tr("some_of_it_may_have_changed"))
                    .font(LightAnchorTheme.supportingFont(size: 12, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
            }
            ForEach(items.filter { staleness[$0.id]?.isActionable == true }) { item in
                if case .missing(let reason)? = staleness[item.id] {
                    Text("\(item.title) · \(reason)")
                        .font(LightAnchorTheme.supportingFont(size: 11.5))
                        .foregroundStyle(LightAnchorTheme.mutedInk)
                        .padding(.leading, 21)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LightAnchorTheme.warningBackground.opacity(0.32),
            in: RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LightAnchorDesign.radiusRow, style: .continuous)
                .strokeBorder(LightAnchorTheme.warning.opacity(0.3), lineWidth: 1)
        }
    }

    // MARK: 脚

    private var foot: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LightAnchorTheme.hairlineBorder)
                .frame(height: 1)
                .padding(.top, 14)
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button(tr("cancel"), action: onCancel)
                    .buttonStyle(LightAnchorInlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if !EnvironmentSnapshotBuilder.draft(from: snapshot).actions.isEmpty {
                    Button(tr("save_as_environment")) { showingEnvironmentEditor = true }
                        .buttonStyle(LightAnchorInlineButtonStyle())
                        .help(tr("open_the_environment_editor_and_review"))
                }
                Button(action: performRestore) {
                    HStack(spacing: 6) {
                        if isRestoring { ProgressView().controlSize(.small) }
                        Text(isRestoring
                            ? tr("restoring")
                            : String(format: tr("scene_return_open_n"), reopening))
                    }
                }
                .buttonStyle(LightAnchorPrimaryButtonStyle())
                .disabled(isRestoring || reopening == 0)
            }
            .padding(.top, 13)
        }
    }

    /// 回场简报：启发式立即稿先出，模型稿回来后替换。
    private func loadBriefing() {
        guard let input = workspace.makeReturnBriefingInput(
            sceneSnapshot: snapshot,
            waitingID: waitingID
        ) else { return }
        let engine = workspace.intelligenceEngine
        Task { @MainActor in
            briefing = await HeuristicIntelligenceEngine().generateReturnBriefing(input)
            if let refined = await engine.generateReturnBriefing(input) {
                briefing = refined
            }
        }
    }

    private func performRestore() {
        isRestoring = true
        let report = workspace.restoreScene(
            snapshot.id,
            selectedItemIDs: Set(items.map(\.id)).subtracting(struckItemIDs),
            resolvingWaitingID: waitingID
        )
        isRestoring = false
        if report.hasIssues {
            workspace.presentNotice(UserFacingCopy.limitation(report.summary))
        } else if !report.summary.isEmpty {
            workspace.presentNotice(report.summary)
        }
        onRestore()
    }
}
