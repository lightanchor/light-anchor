import SwiftUI

// 版本快照设置组的专用视图（视觉稿 docs/version-snapshots-2026-09-10.html）：
// 时间线行、GitHub 描边图标、以及两屏结构化确认对话框。
// .alert 装不下目标卡/出机清单，这两屏用 LightAnchorSettingsDialog 落。

/// GitHub 官方标志（octicons mark-github，填充剪影）。
/// 源 SVG：Support/Icons/octicons/mark-github-24.svg（MIT License，GitHub）。
/// Lucide 的描边 octocat 辨识度不够，品牌位用官方填充标。
struct GitHubMarkIcon: View {
    var size: CGFloat = 15

    var body: some View {
        GitHubMarkShape()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 24×24 视框的填充路径，颜色交给 foregroundStyle。
struct GitHubMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 10.226, y: 17.284))
        p.addCurve(to: CGPoint(x: 5.172, y: 12.028), control1: CGPoint(x: 7.261, y: 16.924), control2: CGPoint(x: 5.172, y: 14.791))
        p.addCurve(to: CGPoint(x: 6.250, y: 8.884), control1: CGPoint(x: 5.172, y: 10.905), control2: CGPoint(x: 5.576, y: 9.692))
        p.addCurve(to: CGPoint(x: 6.340, y: 5.919), control1: CGPoint(x: 5.958, y: 8.143), control2: CGPoint(x: 6.003, y: 6.570))
        p.addCurve(to: CGPoint(x: 9.170, y: 6.929), control1: CGPoint(x: 7.238, y: 5.807), control2: CGPoint(x: 8.451, y: 6.279))
        p.addCurve(to: CGPoint(x: 12.023, y: 6.525), control1: CGPoint(x: 10.023, y: 6.660), control2: CGPoint(x: 10.922, y: 6.525))
        p.addCurve(to: CGPoint(x: 14.830, y: 6.907), control1: CGPoint(x: 13.123, y: 6.525), control2: CGPoint(x: 14.022, y: 6.660))
        p.addCurve(to: CGPoint(x: 17.660, y: 5.919), control1: CGPoint(x: 15.526, y: 6.278), control2: CGPoint(x: 16.762, y: 5.807))
        p.addCurve(to: CGPoint(x: 17.727, y: 8.861), control1: CGPoint(x: 17.975, y: 6.525), control2: CGPoint(x: 18.020, y: 8.098))
        p.addCurve(to: CGPoint(x: 18.828, y: 12.028), control1: CGPoint(x: 18.447, y: 9.715), control2: CGPoint(x: 18.828, y: 10.861))
        p.addCurve(to: CGPoint(x: 13.730, y: 17.262), control1: CGPoint(x: 18.828, y: 14.791), control2: CGPoint(x: 16.739, y: 16.880))
        p.addCurve(to: CGPoint(x: 15.010, y: 20.069), control1: CGPoint(x: 14.493, y: 17.756), control2: CGPoint(x: 15.010, y: 18.834))
        p.addLine(to: CGPoint(x: 15.010, y: 22.405))
        p.addCurve(to: CGPoint(x: 16.245, y: 23.191), control1: CGPoint(x: 15.010, y: 23.079), control2: CGPoint(x: 15.571, y: 23.461))
        p.addCurve(to: CGPoint(x: 23.500, y: 12.545), control1: CGPoint(x: 20.311, y: 21.641), control2: CGPoint(x: 23.500, y: 17.576))
        p.addCurve(to: CGPoint(x: 11.978, y: 1.000), control1: CGPoint(x: 23.500, y: 6.188), control2: CGPoint(x: 18.334, y: 1.000))
        p.addCurve(to: CGPoint(x: 0.500, y: 12.545), control1: CGPoint(x: 5.620, y: 1.000), control2: CGPoint(x: 0.500, y: 6.188))
        p.addCurve(to: CGPoint(x: 7.935, y: 23.214), control1: CGPoint(x: 0.500, y: 17.531), control2: CGPoint(x: 3.667, y: 21.665))
        p.addCurve(to: CGPoint(x: 9.125, y: 22.428), control1: CGPoint(x: 8.541, y: 23.439), control2: CGPoint(x: 9.125, y: 23.034))
        p.addLine(to: CGPoint(x: 9.125, y: 20.630))
        p.addCurve(to: CGPoint(x: 8.047, y: 20.854), control1: CGPoint(x: 8.783, y: 20.773), control2: CGPoint(x: 8.417, y: 20.849))
        p.addCurve(to: CGPoint(x: 5.060, y: 18.541), control1: CGPoint(x: 6.564, y: 20.854), control2: CGPoint(x: 5.688, y: 20.046))
        p.addCurve(to: CGPoint(x: 4.026, y: 17.508), control1: CGPoint(x: 4.813, y: 17.934), control2: CGPoint(x: 4.543, y: 17.575))
        p.addCurve(to: CGPoint(x: 3.667, y: 17.238), control1: CGPoint(x: 3.756, y: 17.485), control2: CGPoint(x: 3.667, y: 17.373))
        p.addCurve(to: CGPoint(x: 4.565, y: 16.767), control1: CGPoint(x: 3.667, y: 16.968), control2: CGPoint(x: 4.117, y: 16.767))
        p.addCurve(to: CGPoint(x: 6.362, y: 18.002), control1: CGPoint(x: 5.217, y: 16.767), control2: CGPoint(x: 5.778, y: 17.171))
        p.addCurve(to: CGPoint(x: 7.845, y: 18.945), control1: CGPoint(x: 6.812, y: 18.653), control2: CGPoint(x: 7.283, y: 18.945))
        p.addCurve(to: CGPoint(x: 9.282, y: 18.226), control1: CGPoint(x: 8.406, y: 18.945), control2: CGPoint(x: 8.765, y: 18.743))
        p.addCurve(to: CGPoint(x: 10.226, y: 17.283), control1: CGPoint(x: 9.664, y: 17.845), control2: CGPoint(x: 9.956, y: 17.508))
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// 快照时间线的一行（视觉稿 .snap）：说明 + 时刻，hover 才露「回到这一刻」。
/// 按钮始终占位只调透明度，避免 hover 时整行右移。
struct SnapshotTimelineRow: View {
    let snapshot: LightAnchorSnapshot
    /// 最新一条用实心主色 + 水洗环，与历史点区分（视觉稿 .snap:first-of-type .dot）。
    let isLatest: Bool
    let onRestore: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isLatest {
                    Circle()
                        .fill(LightAnchorTheme.accentWash)
                        .frame(width: 12, height: 12)
                }
                Circle()
                    .fill(isLatest ? LightAnchorTheme.primaryAction : LightAnchorTheme.accentWash)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 12, height: 12)
            Text(snapshot.subject)
                .font(LightAnchorTheme.interfaceFont(size: 13, weight: .medium))
                .foregroundStyle(LightAnchorTheme.secondaryInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(tr("restore_snapshot"), action: onRestore)
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            Text(snapshot.date, format: .dateTime.hour().minute())
                .font(LightAnchorTheme.supportingFont(size: 11.5))
                .foregroundStyle(LightAnchorTheme.faintInk)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background(isHovered ? LightAnchorTheme.subtleFill : LightAnchorTheme.subtleFill.opacity(0))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// 时间线的分组：同一天一个组，标签「今天 / 昨天 / 9月8日 周二」。
struct SnapshotDayGroup: Identifiable {
    let id: TimeInterval
    let label: String
    var snapshots: [LightAnchorSnapshot]
}

enum SnapshotDayGrouping {
    /// snapshots 必须已按时间从新到旧排好（`GitSnapshotService.history` 的输出）。
    static func groups(
        for snapshots: [LightAnchorSnapshot],
        calendar: Calendar = .current
    ) -> [SnapshotDayGroup] {
        var result: [SnapshotDayGroup] = []
        for snapshot in snapshots {
            let dayStart = calendar.startOfDay(for: snapshot.date)
            if let last = result.last, last.id == dayStart.timeIntervalSince1970 {
                result[result.count - 1].snapshots.append(snapshot)
            } else {
                result.append(SnapshotDayGroup(
                    id: dayStart.timeIntervalSince1970,
                    label: label(for: snapshot.date, calendar: calendar),
                    snapshots: [snapshot]
                ))
            }
        }
        return result
    }

    static func label(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return tr("today") }
        if calendar.isDateInYesterday(date) { return tr("yesterday") }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).weekday(.abbreviated))
    }
}

/// 设置页轻量模态（视觉稿 .dlg）：压暗背板 + 居中卡片。
/// 只用于「回到这一刻」与「首次推送」两屏结构化确认，其余确认仍是 .alert。
struct LightAnchorSettingsDialog<Content: View>: View {
    let title: String
    let cancelTitle: String
    let confirmTitle: String
    var width: CGFloat = 400
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LightAnchorStageDim(colorScheme: colorScheme)
            // 压暗层自身不拦截点击，补一层透明拦截：点背板不 dismiss，
            // 也不许点到背后的设置行（与 .alert 行为一致）。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(LightAnchorTheme.interfaceFont(size: 16, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .padding(.bottom, 10)
                content()
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(cancelTitle, action: onCancel)
                        .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(LightAnchorPrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 18)
            }
            .padding(EdgeInsets(top: 22, leading: 22, bottom: 16, trailing: 22))
            .frame(width: width)
            .background(LightAnchorTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        }
    }
}
