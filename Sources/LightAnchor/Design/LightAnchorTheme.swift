import AppKit
import SwiftUI

/// 第三方品牌本色（接入方的产品记号）：品牌色不随主题变化，
/// 在浅色和深色下都保持原样，否则就不是「人家的图标」了。
enum LightAnchorBrandPalette {
    /// Claude 的珊瑚橙与奶油底。
    static let claudeCoral = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let claudeCream = Color(red: 240 / 255, green: 238 / 255, blue: 230 / 255)
    /// OpenAI/Codex 的白标；花云记号用的蓝紫渐变。
    static let codexPaper = Color.white
    static let codexGradient = LinearGradient(
        colors: [
            Color(red: 139 / 255, green: 124 / 255, blue: 246 / 255),
            Color(red: 59 / 255, green: 55 / 255, blue: 230 / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// PI 的记号底色（青灰板岩）。
    static let piSlate = Color(red: 47 / 255, green: 111 / 255, blue: 109 / 255)
    /// DeepSeek 的品牌蓝。
    static let deepseekBlue = Color(red: 77 / 255, green: 107 / 255, blue: 254 / 255)
}

enum LightAnchorTheme {

    static let primary = LightAnchorThemeColor(.brand)
    static let border = LightAnchorThemeColor(.border)

    /// 正文一律用系统字体。只有对齐本身携带信息的值（时间、ID、路径）才走
    /// `monoFont`。
    static func monoFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let windowBackground = LightAnchorThemeColor(.background)
    static let sidebarBackground = LightAnchorThemeColor(.sidebar)
    static let sidebarSelection = LightAnchorThemeColor(.sidebarAccent)
    static let sidebarHairline = LightAnchorThemeColor(.sidebarBorder)
    static let contentBackground = LightAnchorThemeColor(.background)
    static let surface = LightAnchorThemeColor(.card)
    static let elevatedSurface = LightAnchorThemeColor(.popover)
    static let recessed = LightAnchorThemeColor(.muted)
    static let ink = LightAnchorThemeColor(.text1)
    static let secondaryInk = LightAnchorThemeColor(.text2)
    static let mutedInk = LightAnchorThemeColor(.mutedForeground)
    static let faintInk = LightAnchorThemeColor(.text3)
    static let disabledInk = LightAnchorThemeColor(.text4)
    static let dangerText = LightAnchorThemeColor(.textRedBold)
    static let interactionSoft = LightAnchorThemeColor(.accent)
    static let highlight = LightAnchorThemeColor(.highlight)
    static let subtleFill = LightAnchorThemeColor(.fill100)
    static let hoverFill = LightAnchorThemeColor(.fill150)
    static let selectedFill = LightAnchorThemeColor(.fill200)
    static let hairlineBorder = LightAnchorThemeColor(.border100)
    static let subtleBorder = LightAnchorThemeColor(.border200)
    static let iconSoft = LightAnchorThemeColor(.iconSoft400)
    static let iconDisabled = LightAnchorThemeColor(.iconDisabled100)
    static let iconDisabledStrong = LightAnchorThemeColor(.iconDisabled300)
    static let iconSubtle = LightAnchorThemeColor(.iconSub600)
    static let iconAmber = LightAnchorThemeColor(.iconAmber)
    static let error = LightAnchorThemeColor(.errorDark)
    static let chartWarm = LightAnchorThemeColor(.chart1)
    static let chartCool = LightAnchorThemeColor(.chart2)
    static let chartDeep = LightAnchorThemeColor(.chart3)
    static let chartYellow = LightAnchorThemeColor(.chart4)
    static let chartAmber = LightAnchorThemeColor(.chart5)
    static let warning = LightAnchorThemeColor(.warning)
    static let warningBackground = LightAnchorThemeColor(.warningBackground)
    static let success = chartDeep
    static let successBackground = chartCool
    /// 宜绿本色（#3E9B4F）：徽章与点，文字请用 success（加深档）。
    static let successBadge = LightAnchorThemeColor(.successBackground)
    static let danger = LightAnchorThemeColor(.danger)
    static let dangerBackground = LightAnchorThemeColor(.dangerBackground)
    static let primaryText = LightAnchorThemeColor(.primary)
    static let primaryAction = LightAnchorThemeColor(.primary)
    static let onAction = LightAnchorThemeColor(.primaryForeground)

    /// 文字级强调：主色 #5BA7CE 的加深档（textBlue），用于链接、状态文字、
    /// 计数等需要 4.5:1 对比度的文字。主色本身只做填充与识别。
    static let accentInk = LightAnchorThemeColor(.textBlue)
    static let accentInkStrong = LightAnchorThemeColor(.textBlueBold)
    /// 主色识别点/水洗底（accent 角色 = #5BA7CE 16% 透明）。
    static let accentWash = LightAnchorThemeColor(.accent)

    static func interfaceFont(size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func labelFont(size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // Semantic text roles keep reading hierarchy stable across workspace,
    // settings, and editor surfaces. Display type remains available for the
    // few intentionally expressive empty states.
    static func titleFont(size: CGFloat = 25, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func headingFont(size: CGFloat = 14, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func bodyFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func supportingFont(size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func controlFont(size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

}

struct LightAnchorIcon: View {
    let name: String
    var size: CGFloat = 18

    init(_ name: String, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    var body: some View {
        let systemName = LightAnchorSystemIcon.name(for: name) ?? name
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
            Image(nsImage: configuredTemplate(image))
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private func configuredTemplate(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }
}

enum LightAnchorSystemIcon {
    private static let mapping: [String: String] = [
        "alert-triangle": "exclamationmark.triangle",
        "app-window": "app.dashed",
        "archive": "archivebox",
        "arrow-up": "arrow.up",
        "arrow-up-right": "arrow.up.right",
        "bell": "bell",
        "bookmark": "bookmark",
        "brain-circuit": "sparkles",
        "cable": "link",
        "check": "checkmark",
        "circle-check": "checkmark.circle",
        "checkmark-circle-fill": "checkmark.circle.fill",
        "check-circle": "checkmark.circle",
        "circle-dot": "scope",
        "circle-x": "xmark.circle.fill",
        "circle-pause": "pause.circle",
        "circle-play": "play.circle",
        "circle-slash": "nosign",
        "circle-stop": "stop.circle",
        "clock-3": "clock.arrow.circlepath",
        "corner-down-left": "arrow.turn.down.left",
        "copy": "doc.on.doc",
        "database": "externaldrive",
        "download": "arrow.down.circle",
        "ellipsis": "ellipsis",
        "eye-off": "eye.slash",
        "calendar": "calendar",
        "calendar-days": "calendar",
        "calendar-clock": "calendar.badge.clock",
        "chevron-down": "chevron.down",
        "chevron-up-down": "chevron.up.chevron.down",
        "chevron-left": "chevron.left",
        "chevron-right": "chevron.right",
        "chevron-up": "chevron.up",
        "circle-arrow-down": "arrow.down.circle",
        "circle-help": "questionmark.circle",
        "cloud": "cloud",
        "code-2": "curlybraces",
        "cpu": "cpu",
        "doc": "doc",
        "file-output": "arrow.up.doc",
        "external-link": "arrow.up.right.square",
        "file": "doc",
        "file-down": "arrow.down.doc",
        "file-text": "doc.text",
        "file-heart": "heart.text.square",
        "file-up": "arrow.up.doc",
        "focus": "scope",
        "flask-conical": "flask",
        "globe": "globe",
        "globe-2": "globe",
        "hammer": "hammer",
        "hourglass": "hourglass",
        "inbox": "tray",
        "info": "info.circle",
        "layers": "rectangle.stack",
        "link": "link",
        "lock-keyhole": "lock",
        "message-circle-reply": "arrowshape.turn.up.left.circle",
        "message-circle": "bubble.left",
        "mic": "mic",
        "moon": "moon",
        "palette": "paintpalette",
        "panels-top-left": "macwindow.on.rectangle",
        "pencil": "pencil",
        "plus": "plus",
        "play": "play",
        "package-check": "shippingbox.and.arrow.backward",
        "refresh-cw": "arrow.clockwise",
        "rotate-ccw": "arrow.uturn.backward.circle",
        "scan": "viewfinder",
        "search": "magnifyingglass",
        "send": "paperplane",
        "settings": "gearshape",
        "sidebar-trailing": "sidebar.right",
        "shield-alert": "exclamationmark.shield",
        "shield-check": "checkmark.shield",
        "sliders-horizontal": "slider.horizontal.3",
        "sparkles": "sparkles",
        "square-terminal": "terminal",
        "terminal": "terminal",
        "sticky-note": "note.text",
        "smartphone": "iphone",
        "text-cursor-input": "text.cursor",
        "trash-2": "trash",
        "tray": "tray",
        "undo-2": "arrow.uturn.backward.circle",
        "x": "xmark",
        "info-circle": "info.circle"
    ]

    static func name(for iconID: String) -> String? {
        guard let systemName = mapping[iconID],
              NSImage(systemSymbolName: systemName, accessibilityDescription: nil) != nil
        else { return nil }
        return systemName
    }
}

struct LightAnchorLabel: View {
    let title: String
    let icon: String
    var spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            LightAnchorIcon(icon)
            Text(title)
        }
    }
}

/// 蓝点的五种几何形态：状态用形状区分，不用图形隐喻（Blue Dot 设计语言核心）。
enum LightAnchorStatusDotForm: Equatable {
    /// 实心 · 光环呼吸
    case active
    /// 空心圆环
    case paused
    /// 虚线圆环（暖色）
    case waiting
    /// 双环
    case returning
    /// 灰点
    case ended

    init(_ state: AttentionEpisodeState) {
        switch state {
        case .active: self = .active
        case .paused: self = .paused
        case .waiting: self = .waiting
        case .returning: self = .returning
        case .ended: self = .ended
        }
    }
}

/// 呼吸光环：CABasicAnimation 交给渲染服务器执行——SwiftUI 的
/// 无限循环状态动画会让主线程每帧打点（空转 20%+），
/// 动 frame 更是逐帧全窗重排直到无响应。
struct LightAnchorBreathingHalo: NSViewRepresentable {
    /// 光环静止直径；呼吸时放大到 peakScale 倍。
    var diameter: CGFloat
    var peakScale: CGFloat
    var opacity: CGFloat
    var animated: Bool

    @Environment(\.lightAnchorPalette) private var palette

    func makeNSView(context: Context) -> HaloView {
        HaloView()
    }

    func updateNSView(_ view: HaloView, context: Context) {
        view.configure(
            color: NSColor(palette.color(for: .primary)),
            diameter: diameter,
            peakScale: peakScale,
            opacity: opacity,
            animated: animated
        )
    }

    final class HaloView: NSView {
        private struct Config: Equatable {
            var color: NSColor
            var diameter: CGFloat
            var peakScale: CGFloat
            var opacity: CGFloat
            var animated: Bool
        }

        private let halo = CALayer()
        private var animated = false
        private var peakScale: CGFloat = 1
        private var appliedConfig: Config?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(halo)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            color: NSColor,
            diameter: CGFloat,
            peakScale: CGFloat,
            opacity: CGFloat,
            animated: Bool
        ) {
            // updateNSView 必须幂等：参数没变就什么都不做。release 构建下
            // 每次都 needsLayout + 重挂动画会形成 更新→布局→更新 的死循环
            // （空状态页主线程 95%+ 直到无响应）。
            let config = Config(
                color: color,
                diameter: diameter,
                peakScale: peakScale,
                opacity: opacity,
                animated: animated
            )
            guard config != appliedConfig else { return }
            appliedConfig = config
            halo.backgroundColor = color.withAlphaComponent(opacity).cgColor
            halo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            halo.cornerRadius = diameter / 2
            self.peakScale = peakScale
            self.animated = animated
            needsLayout = true
            applyAnimation()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            halo.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAnimation()
        }

        private func applyAnimation() {
            halo.removeAnimation(forKey: "breathe")
            halo.removeAnimation(forKey: "breathe-fade")
            guard animated, window != nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = peakScale
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.5
            for animation in [scale, fade] {
                animation.duration = 4.5
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.autoreverses = true
                animation.repeatCount = .infinity
            }
            halo.add(scale, forKey: "breathe")
            halo.add(fade, forKey: "breathe-fade")
        }
    }
}

struct LightAnchorStatusDot: View {
    let form: LightAnchorStatusDotForm
    var size: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ form: LightAnchorStatusDotForm, size: CGFloat = 9) {
        self.form = form
        self.size = size
    }

    init(_ state: AttentionEpisodeState, size: CGFloat = 9) {
        self.form = LightAnchorStatusDotForm(state)
        self.size = size
    }

    var body: some View {
        ZStack {
            switch form {
            case .active:
                // 光环呼吸：点本身不缩放，外圈水洗光环缓慢扩散收拢。
                LightAnchorBreathingHalo(
                    diameter: size + 6,
                    peakScale: (size + 12) / (size + 6),
                    opacity: 0.18,
                    animated: !reduceMotion
                )
                Circle()
                    .fill(LightAnchorTheme.primary)
                    .frame(width: size, height: size)
            case .paused:
                Circle()
                    .strokeBorder(LightAnchorTheme.primary, lineWidth: 2)
                    .frame(width: size + 1, height: size + 1)
            case .waiting:
                Circle()
                    .stroke(
                        LightAnchorTheme.warning,
                        style: StrokeStyle(lineWidth: 2, dash: [2.4, 2.4])
                    )
                    .frame(width: size, height: size)
            case .returning:
                Circle()
                    .strokeBorder(LightAnchorTheme.primary.opacity(0.45), lineWidth: 1)
                    .frame(width: size + 8, height: size + 8)
                Circle()
                    .strokeBorder(LightAnchorTheme.primary, lineWidth: 2)
                    .frame(width: size + 1, height: size + 1)
            case .ended:
                Circle()
                    .fill(LightAnchorTheme.faintInk)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size + 12, height: size + 12)
        .accessibilityHidden(true)
    }
}

struct LightAnchorIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 36)
            .controlSize(.regular)
            .foregroundStyle(
                !isEnabled
                    ? LightAnchorTheme.iconDisabled
                    : (configuration.isPressed
                        ? LightAnchorTheme.primaryText
                        : LightAnchorTheme.iconSoft)
            )
            .background(
                configuration.isPressed ? LightAnchorTheme.interactionSoft : LightAnchorThemeColor.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 工具栏图标按钮：无描边软填充，悬停/选中为主色水洗（V7 · 暖白规范）。
/// 悬停软填充（样机各处 :hover { background: var(--pill-hover) } 的通用件，
/// 过渡统一 .15s）。放在控件自身背景之下，选中/按压态照常压过它。
struct LightAnchorHoverFillModifier: ViewModifier {
    var cornerRadius: CGFloat
    var isActive = true

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if isActive && isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LightAnchorTheme.hoverFill)
                }
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

extension View {
    func lightAnchorHoverFill(cornerRadius: CGFloat, isActive: Bool = true) -> some View {
        modifier(LightAnchorHoverFillModifier(cornerRadius: cornerRadius, isActive: isActive))
    }
}

struct LightAnchorToolbarIconButtonStyle: ButtonStyle {
    let isSelected: Bool

    init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .controlSize(.regular)
            .foregroundStyle(
                isSelected
                    ? LightAnchorTheme.accentInk
                    : (configuration.isPressed || isHovered ? LightAnchorTheme.ink : LightAnchorTheme.iconSoft)
            )
            .background(
                isSelected || configuration.isPressed
                    ? LightAnchorTheme.accentWash
                    : (isHovered ? LightAnchorTheme.hoverFill : LightAnchorThemeColor.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LightAnchorPrimaryButtonStyle: ButtonStyle {
    /// 样机 .btn.sm：27 高 / 12.5 字号 / 圆角 8（菜单栏浮窗等紧凑场合）。
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LightAnchorTheme.controlFont(size: compact ? 12.5 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 27 : 32)
            .controlSize(.regular)
            .foregroundStyle(LightAnchorTheme.onAction)
            .background(
                LightAnchorTheme.primaryAction,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
            )
            // 样机 --shadow-blue：主按钮带一层淡蓝投影。
            .shadow(color: .init(red: 91/255, green: 167/255, blue: 206/255).opacity(0.40), radius: 4, y: 2)
            .brightness(isHovered && isEnabled ? 0.05 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.4)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LightAnchorQuietButtonStyle: ButtonStyle {
    /// 样机 .btn.sm：27 高 / 12.5 字号 / 圆角 8（菜单栏浮窗等紧凑场合）。
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LightAnchorTheme.controlFont(size: compact ? 12.5 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 14)
            .frame(minHeight: compact ? 27 : 32)
            .controlSize(.regular)
            .foregroundStyle(isEnabled ? LightAnchorTheme.ink : LightAnchorTheme.disabledInk)
            .background(
                configuration.isPressed
                    ? LightAnchorTheme.selectedFill.opacity(0.5)
                    : (isHovered ? LightAnchorTheme.sidebarSelection : LightAnchorTheme.recessed),
                in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A destructive action should remain discoverable without visually breaking
/// the current-work surface. Confirmation still carries the destructive role.
struct LightAnchorDestructiveQuietButtonStyle: ButtonStyle {
    /// 样机 .btn.sm.danger。
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LightAnchorTheme.controlFont(size: compact ? 12.5 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 13)
            .frame(minHeight: compact ? 27 : 32)
            .controlSize(.regular)
            .foregroundStyle(isEnabled ? LightAnchorTheme.error : LightAnchorTheme.disabledInk)
            // 和安静按钮同一副底座（凹陷米灰），悬停转危险色水洗——
            // 纯红字浮在卡面上看起来不像按钮。
            .background(
                configuration.isPressed || isHovered
                    ? LightAnchorTheme.error.opacity(configuration.isPressed ? 0.12 : 0.09)
                    : LightAnchorTheme.recessed,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 完成/就绪类动作：宜绿水洗底 + 加深绿文字——与「恢复现场 →」的
/// 水洗+着色文字同一语言（实底绿+投影被否：跳出整体风格）。
struct LightAnchorSuccessButtonStyle: ButtonStyle {
    /// 样机 .btn.sm：27 高 / 12.5 字号 / 圆角 8（菜单栏浮窗等紧凑场合）。
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LightAnchorTheme.controlFont(size: compact ? 12.5 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 27 : 32)
            .controlSize(.regular)
            .foregroundStyle(LightAnchorTheme.success)
            .background(
                LightAnchorTheme.successBadge.opacity(isHovered && isEnabled ? 0.26 : 0.16),
                in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.4)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 凸起白面按钮（样机 .segsoft button.on 的语言）：白卡底 + 发丝描边 +
/// 浅影。用在凹陷米灰的容器里——安静按钮的凹陷底在那儿会隐形。
struct LightAnchorRaisedButtonStyle: ButtonStyle {
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LightAnchorTheme.controlFont(size: compact ? 12.5 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 14)
            .frame(minHeight: compact ? 27 : 32)
            .controlSize(.regular)
            .foregroundStyle(isEnabled ? LightAnchorTheme.ink : LightAnchorTheme.disabledInk)
            .background(
                isHovered ? LightAnchorTheme.elevatedSurface : LightAnchorTheme.surface,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LightAnchorInlineButtonStyle: ButtonStyle {
    var tint: LightAnchorThemeColor = LightAnchorTheme.secondaryInk
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LightAnchorTheme.controlFont(size: 12, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .controlSize(.regular)
            .foregroundStyle(
                isEnabled
                    ? (isHovered ? LightAnchorTheme.ink : tint)
                    : LightAnchorTheme.iconDisabledStrong
            )
            .background(
                configuration.isPressed || isHovered
                    ? LightAnchorTheme.hoverFill
                    : LightAnchorThemeColor.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// SwiftUI 只在主线程调用样式的 _body；@preconcurrency 让 MainActor
// 实现满足这个非隔离的协议要求。
struct LightAnchorTextFieldStyle: @preconcurrency TextFieldStyle {
    @MainActor func _body(configuration: TextField<Self._Label>) -> some View {
        LightAnchorInputChrome {
            configuration
                .textFieldStyle(.plain)
                .font(LightAnchorTheme.bodyFont())
        }
    }
}

/// 输入框外衣：白底 + 描边让「这里可以输入」一眼可辨（凹陷米灰
/// 会和普通说明文字混在一起），聚焦时描边转主色承担焦点环语义。
private struct LightAnchorInputChrome<Content: View>: View {
    private let content: Content
    @FocusState private var isFocused: Bool

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .focused($isFocused)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isFocused ? LightAnchorTheme.primary : LightAnchorTheme.subtleBorder,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// 组合输入框（NSComboBox 的角色）：既能直接键入，也能从右缘的
/// 系统菜单里挑一个建议值填进来。用于「模型 ID」这类
/// 常见值有列表、少见值靠手输的字段——不再让用户在
/// 「下拉框」和「手动输入」两种形态之间来回切换。
struct LightAnchorComboField: View {
    private let placeholder: String
    @Binding private var text: String
    private let suggestions: [String]
    @FocusState private var isFocused: Bool

    init(_ placeholder: String, text: Binding<String>, suggestions: [String]) {
        self.placeholder = placeholder
        _text = text
        self.suggestions = suggestions
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(LightAnchorTheme.bodyFont())
                .focused($isFocused)

            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            text = suggestion
                        } label: {
                            if suggestion == text {
                                LightAnchorLabel(title: suggestion, icon: "check")
                            } else {
                                Text(suggestion)
                            }
                        }
                    }
                } label: {
                    // 22×18 而不是 22×22：多出的 4pt 会把这个输入框顶得比
                    // 同一张弹窗里别的输入框高一截。
                    LightAnchorIcon("chevron-up-down", size: 12)
                        .foregroundStyle(LightAnchorTheme.iconSoft)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(tr("pick_from_suggestions"))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            LightAnchorTheme.elevatedSurface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? LightAnchorTheme.primary : LightAnchorTheme.subtleBorder,
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

struct LightAnchorSelectionOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

struct LightAnchorChoiceField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [LightAnchorSelectionOption<Value>]
    let iconForValue: (Value) -> String?

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        titleForValue: @escaping (Value) -> String,
        iconForValue: @escaping (Value) -> String? = { _ in nil }
    ) {
        self.title = title
        _selection = selection
        self.options = options.map {
            LightAnchorSelectionOption(value: $0, title: titleForValue($0))
        }
        self.iconForValue = iconForValue
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(LightAnchorTheme.controlFont())
                .foregroundStyle(LightAnchorTheme.ink)
                .frame(minWidth: 54, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(options) { option in
                    let isSelected = option.value == selection

                    Button {
                        selection = option.value
                    } label: {
                        HStack(spacing: 6) {
                            if let icon = iconForValue(option.value) {
                                LightAnchorIcon(icon, size: 13)
                            }
                            Text(option.title)
                                .lineLimit(1)
                        }
                        .font(
                            LightAnchorTheme.controlFont(
                                size: 12,
                                weight: isSelected ? .semibold : .regular
                            )
                        )
                        .foregroundStyle(
                            isSelected ? LightAnchorTheme.accentInk : LightAnchorTheme.mutedInk
                        )
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.horizontal, 8)
                        .background(
                            isSelected ? LightAnchorTheme.elevatedSurface : LightAnchorThemeColor.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(
                LightAnchorTheme.recessed,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// 下拉选择行：左标题 + 右侧弹出按钮。点开的是系统原生菜单
/// （NSMenu：可滚动、可键盘选、带勾选），不再自绘浮窗。
/// `embedded: true` 时只渲染触发器本体（无左标题、不铺满整行），
/// 供 settingsRow 一类自带标题的行容器嵌用。
struct LightAnchorSelectField<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [LightAnchorSelectionOption<Value>]
    let embedded: Bool
    @State private var isHovered = false

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        titleForValue: @escaping (Value) -> String,
        embedded: Bool = false
    ) {
        self.title = title
        _selection = selection
        self.options = options.map {
            LightAnchorSelectionOption(value: $0, title: titleForValue($0))
        }
        self.embedded = embedded
    }

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? ""
    }

    var body: some View {
        if embedded {
            menuControl
        } else {
            HStack(spacing: 12) {
                Text(title)
                    .font(LightAnchorTheme.controlFont())
                    .foregroundStyle(LightAnchorTheme.ink)

                Spacer(minLength: 12)

                menuControl
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            // 不再给容器重复挂 label：menuControl 自带同名 label+value，
            // 双挂会让旁白巡航连听两遍标题。
        }
    }

    private var menuControl: some View {
        Menu {
                Picker(title, selection: $selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 8) {
                    Text(selectedTitle)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // 系统弹出按钮的上下双箭头：告诉用户「这里可以选」。
                    LightAnchorIcon("chevron-up-down", size: 12)
                        .foregroundStyle(LightAnchorTheme.iconSoft)
                }
                .font(LightAnchorTheme.controlFont())
                .foregroundStyle(LightAnchorTheme.ink)
                .padding(.horizontal, 10)
                .frame(minWidth: 176, idealWidth: 220, maxWidth: 260, minHeight: 34, alignment: .leading)
                .background(
                    LightAnchorTheme.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isHovered
                                ? LightAnchorTheme.primaryText.opacity(0.38)
                                : LightAnchorTheme.primaryText.opacity(0.18),
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .accessibilityLabel(title)
            .accessibilityValue(selectedTitle)
    }
}

struct LightAnchorOverflowAction {
    let title: String
    let icon: String
    let isDestructive: Bool
    let action: () -> Void

    var systemIconName: String {
        LightAnchorSystemIcon.name(for: icon) ?? icon
    }

    init(
        title: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.action = action
    }
}

struct LightAnchorOverflowMenu: View {
    let help: String
    let actions: [LightAnchorOverflowAction]

    init(
        help: String = tr("more_actions"),
        actions: [LightAnchorOverflowAction]
    ) {
        self.help = help
        self.actions = actions
    }

    var body: some View {
        Menu {
            ForEach(actions.indices, id: \.self) { index in
                let action = actions[index]
                Button(role: action.isDestructive ? .destructive : nil, action: action.action) {
                    Label(action.title, systemImage: action.systemIconName)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LightAnchorTheme.iconSoft)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

struct LightAnchorDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, 8)
        } label: {
            Text(title)
                .font(LightAnchorTheme.interfaceFont(size: 12, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.mutedInk)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
    }
}

/// 「今天 14:30」「明天 09:00」，其余日子退回「8月24日 14:30」。
/// 日期字段的按钮文字与等待弹窗的「提醒时间：…」共用一套口吻。
func lightAnchorFriendlyDateTime(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) {
        return String(format: tr("today_at_time"), time)
    }
    if Calendar.current.isDateInTomorrow(date) {
        return String(format: tr("tomorrow_at_time"), time)
    }
    return date.formatted(date: .abbreviated, time: .shortened)
}

/// 日期时间字段：与下拉字段同一副外衣的胶囊按钮，点开日历 + 时间浮窗。
/// 日历用系统的（表现好），时间不再用裸的 NSDatePicker 步进框——
/// 铁灰边框和暖白卡面格格不入，改成与下拉字段同款的时/分弹出菜单。
struct LightAnchorDateField: View {
    let title: String
    @Binding var selection: Date
    let range: PartialRangeFrom<Date>?

    @State private var isExpanded = false
    @State private var isHovered = false
    /// 月历当前翻到的月份（每次打开面板时回到所选日期所在月）。
    @State private var displayedMonth = Date()

    init(
        _ title: String,
        selection: Binding<Date>,
        in range: PartialRangeFrom<Date>? = nil
    ) {
        self.title = title
        _selection = selection
        self.range = range
    }

    private var formattedSelection: String {
        lightAnchorFriendlyDateTime(selection)
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                LightAnchorIcon("calendar-clock", size: 14)
                    .foregroundStyle(LightAnchorTheme.iconSoft)
                Text(formattedSelection)
                    .font(LightAnchorTheme.controlFont())
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(LightAnchorTheme.ink)
                LightAnchorIcon("chevron-up-down", size: 11)
                    .foregroundStyle(LightAnchorTheme.iconSoft)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovered || isExpanded
                            ? LightAnchorTheme.primaryText.opacity(0.38)
                            : LightAnchorTheme.primaryText.opacity(0.18),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
            pickerPanel
                // 浮窗默认的系统灰材质和暖白卡面不搭，换成主题面色。
                .presentationBackground(LightAnchorTheme.surface)
        }
        .onAppear { if debugAutoExpand { isExpanded = true } }
        .accessibilityLabel(title)
        .accessibilityValue(formattedSelection)
    }

    private var pickerPanel: some View {
        // 整个面板自绘：系统的 graphical DatePicker 自带一套字体、间距和
        // 选中色，怎么调 tint 都嵌不进暖白卡面；月历画起来不大，索性全按
        // 主题令牌来。
        VStack(alignment: .leading, spacing: 10) {
            monthHeader
            weekdayHeader
            dayGrid

            Divider()

            HStack(spacing: 8) {
                Text(tr("time"))
                    .font(LightAnchorTheme.controlFont())
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                Spacer(minLength: 8)
                timeComponentMenu(
                    values: Array(0...23),
                    selected: selectedHour,
                    accessibilityTitle: tr("hour")
                ) { setTime(hour: $0) }
                Text(":")
                    .font(LightAnchorTheme.controlFont())
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                timeComponentMenu(
                    values: minuteOptions,
                    selected: selectedMinute,
                    accessibilityTitle: tr("minute")
                ) { setTime(minute: $0) }
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { displayedMonth = Self.startOfMonth(selection) }
    }

    /// 调试后门（截图/验收用）：出现即自动展开浮窗。
    private var debugAutoExpand: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LIGHTANCHOR_DEBUG_DATE_POPOVER"] == "1"
        #else
        false
        #endif
    }

    // MARK: - 月历

    private static let calendar = Calendar.current
    private static let gridColumns = Array(
        repeating: GridItem(.fixed(30), spacing: 2),
        count: 7
    )

    private static func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                .font(LightAnchorTheme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
            Spacer(minLength: 8)
            monthStepButton(icon: "chevron-left", label: tr("previous_month"), step: -1)
                .disabled(!canStepBack)
            monthStepButton(icon: "chevron-right", label: tr("next_month"), step: 1)
        }
    }

    private func monthStepButton(icon: String, label: String, step: Int) -> some View {
        Button {
            if let next = Self.calendar.date(byAdding: .month, value: step, to: displayedMonth) {
                displayedMonth = Self.startOfMonth(next)
            }
        } label: {
            LightAnchorIcon(icon, size: 12)
        }
        .buttonStyle(LightAnchorInlineButtonStyle())
        .accessibilityLabel(label)
    }

    /// 允许选择的下限所在月份之前不用翻过去——那里没有可选的日子。
    private var canStepBack: Bool {
        guard let range else { return true }
        return displayedMonth > Self.startOfMonth(range.lowerBound)
    }

    /// 周首随系统日历设置（周一或周日起）。
    private var orderedWeekdaySymbols: [String] {
        let symbols = Self.calendar.veryShortStandaloneWeekdaySymbols
        let first = Self.calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 2) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(LightAnchorTheme.supportingFont(size: 10.5))
                    .foregroundStyle(LightAnchorTheme.faintInk)
                    .frame(width: 30, height: 18)
            }
        }
        .accessibilityHidden(true)
    }

    /// 月初前的空位 + 当月每一天。
    private var dayCells: [Date?] {
        let calendar = Self.calendar
        let leading = (calendar.component(.weekday, from: displayedMonth)
            - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
        let days = (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: displayedMonth)
        }
        return Array(repeating: nil, count: leading) + days
    }

    private var dayGrid: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 2) {
            ForEach(Array(dayCells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(width: 30, height: 28)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = Self.calendar
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        let isDisabled = range.map { day < calendar.startOfDay(for: $0.lowerBound) } ?? false

        return Button {
            pickDay(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(LightAnchorTheme.interfaceFont(size: 12, weight: isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    isSelected
                        ? LightAnchorTheme.onAction
                        : (isDisabled ? LightAnchorTheme.faintInk : LightAnchorTheme.ink)
                )
                .frame(width: 30, height: 28)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LightAnchorTheme.accentInk)
                    } else if isToday {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(LightAnchorTheme.accentInk.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(day.formatted(date: .long, time: .omitted))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 换日子保留已选的时分；落在下限之前就贴到下限。
    private func pickDay(_ day: Date) {
        let calendar = Self.calendar
        var next = calendar.date(
            bySettingHour: selectedHour,
            minute: selectedMinute,
            second: 0,
            of: day
        ) ?? day
        if let range, next < range.lowerBound {
            next = range.lowerBound
        }
        selection = next
    }

    // MARK: - 时/分弹出菜单

    private var selectedHour: Int { Calendar.current.component(.hour, from: selection) }
    private var selectedMinute: Int { Calendar.current.component(.minute, from: selection) }

    /// 分钟按 5 分钟一档；当前值不在档上时插进去，别让选中项凭空消失。
    private var minuteOptions: [Int] {
        var values = Set(stride(from: 0, through: 55, by: 5))
        values.insert(selectedMinute)
        return values.sorted()
    }

    private func setTime(hour: Int? = nil, minute: Int? = nil) {
        var next = Calendar.current.date(
            bySettingHour: hour ?? selectedHour,
            minute: minute ?? selectedMinute,
            second: 0,
            of: selection
        ) ?? selection
        if let range, next < range.lowerBound {
            next = range.lowerBound
        }
        selection = next
    }

    private func timeComponentMenu(
        values: [Int],
        selected: Int,
        accessibilityTitle: String,
        onPick: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            Picker(accessibilityTitle, selection: Binding(get: { selected }, set: onPick)) {
                ForEach(values, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(String(format: "%02d", selected))
                    .font(LightAnchorTheme.controlFont())
                    .monospacedDigit()
                    .foregroundStyle(LightAnchorTheme.ink)
                LightAnchorIcon("chevron-up-down", size: 10)
                    .foregroundStyle(LightAnchorTheme.iconSoft)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 52, minHeight: 28)
            .background(
                LightAnchorTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(LightAnchorTheme.primaryText.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(String(format: "%02d", selected))
    }
}

struct LightAnchorShellModifier: ViewModifier {
    let radius: CGFloat
    let padding: CGFloat
    let tint: LightAnchorThemeColor?
    let recessed: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background(LightAnchorSurfaceFill(shape: shape, tint: tint, recessed: recessed))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    (recessed ? LightAnchorTheme.subtleBorder : LightAnchorTheme.hairlineBorder)
                        .opacity(recessed ? 0.8 : 1),
                    lineWidth: 1
                )
            }
            // 唯一允许的卡片投影：多层低透明度，浮而不腻（V7 精修规范）。
            .shadow(color: .black.opacity(recessed ? 0 : 0.04), radius: 1, y: 1)
            .shadow(color: .black.opacity(recessed ? 0 : 0.05), radius: 11, y: 4)
    }
}

private struct LightAnchorSurfaceFill<S: Shape>: View {
    let shape: S
    let tint: LightAnchorThemeColor?
    let recessed: Bool

    var body: some View {
        let base = recessed ? LightAnchorTheme.recessed : LightAnchorTheme.surface
        ZStack {
            shape.fill(base)
            if let tint {
                shape.fill(tint.opacity(recessed ? 0.04 : 0.07))
            }
        }
    }
}

extension View {
    func lightAnchorShell(
        radius: CGFloat = 16,
        padding: CGFloat = 20,
        tint: LightAnchorThemeColor? = nil
    ) -> some View {
        modifier(LightAnchorShellModifier(radius: radius, padding: padding, tint: tint, recessed: false))
    }

    func lightAnchorRecessed(radius: CGFloat = 10, padding: CGFloat = 16) -> some View {
        modifier(LightAnchorShellModifier(radius: radius, padding: padding, tint: nil, recessed: true))
    }

    func lightAnchorPanel(
        radius: CGFloat = 16,
        recessed: Bool = false,
        tint: LightAnchorThemeColor? = nil
    ) -> some View {
        modifier(LightAnchorShellModifier(radius: radius, padding: 0, tint: tint, recessed: recessed))
    }
}

extension NSColor {
    convenience init(hex value: String) {
        let components = LightAnchorColorMath.components(for: value)
            ?? LightAnchorColorMath.components(for: LightAnchorColorMath.defaultHex)!
        self.init(
            calibratedRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.alpha
        )
    }
}

extension Color {
    init(hex value: String) {
        let components = LightAnchorColorMath.components(for: value)
            ?? LightAnchorColorMath.components(for: LightAnchorColorMath.defaultHex)!
        self.init(red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
    }

    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
