#if os(macOS)
import AppKit
import SwiftUI

enum LightAnchorWindowChrome: Equatable {
    case workspace
    case capture
    case settings
}

struct LightAnchorWindowConfigurator: NSViewRepresentable {
    let chrome: LightAnchorWindowChrome
    @Environment(\.lightAnchorPalette) private var palette

    func makeNSView(context: Context) -> LightAnchorWindowProbe {
        let nsView = LightAnchorWindowProbe(chrome: chrome)
        nsView.palette = palette
        nsView.applyChrome()
        return nsView
    }

    func updateNSView(_ nsView: LightAnchorWindowProbe, context: Context) {
        nsView.chrome = chrome
        nsView.palette = palette
        nsView.applyChrome()
    }
}

@MainActor
final class LightAnchorWindowProbe: NSView {
    var chrome: LightAnchorWindowChrome
    var palette = LightAnchorThemePalette.light

    /// V7 窗顶呼吸带的红绿灯几何：中心线在窗顶下 22pt（原生 28pt 标题栏里
    /// 是 14pt，视觉上挤着窗顶边），水平中心 22/42/62（间距 20）。
    private static let trafficLightCenterFromTop: CGFloat = 22
    private static let trafficLightFirstCenterX: CGFloat = 22
    private static let trafficLightSpacing: CGFloat = 20
    private static let trafficLightTypes: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton
    ]

    private var trafficLightObserversInstalled = false

    init(chrome: LightAnchorWindowChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }

    func applyChrome() {
        guard let window else { return }

        switch chrome {
        case .workspace:
            // The workspace intentionally keeps the standard title bar and
            // toolbar so macOS window controls, split-view commands and
            // keyboard navigation remain discoverable.
            // V7.1：不要原生标题栏——标题栏完全透明并让内容全尺寸铺满，
            // 红绿灯与工具按钮直接浮在暖米白上，顶部没有任何灰条或分隔线。
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.toolbarStyle = .unifiedCompact
            window.title = ""
            window.styleMask.insert([.closable, .miniaturizable, .resizable])
            [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ].forEach { button in
                window.standardWindowButton(button)?.isHidden = false
            }
            window.backgroundColor = NSColor(palette.color(for: .sidebar))
            window.isOpaque = true
            window.hasShadow = true
            installTrafficLightObserversIfNeeded()
            repositionTrafficLights()
        case .settings:
            // 样机 setwin：暖色标头自带「设置」标题与药丸标签行，
            // 原生标题栏做成透明全尺寸，红绿灯直接浮在暖米白上。
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.title = tr("settings")
            window.toolbar = nil
            window.backgroundColor = NSColor(palette.color(for: .sidebar))
            window.isOpaque = true
            window.hasShadow = true
        case .capture:
            window.title = tr("capture")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = nil
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.styleMask.remove([.miniaturizable, .resizable])
            // 样机的捕获窗没有窗口按钮：esc / 取消 即关闭。
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.level = .floating
            window.isOpaque = true
            window.backgroundColor = NSColor(palette.color(for: .background))
            window.hasShadow = true
        }

    }

    // MARK: - 红绿灯对齐 V7 呼吸带

    /// 把三颗红绿灯排到样机几何（幂等：目标位是绝对值，重复调用不漂移）。
    /// 全屏时按钮归系统的自动隐藏条管，不动。
    private func repositionTrafficLights() {
        guard chrome == .workspace, let window,
              !window.styleMask.contains(.fullScreen) else { return }
        for (index, type) in Self.trafficLightTypes.enumerated() {
            guard let button = window.standardWindowButton(type),
                  let container = button.superview else { continue }
            let size = button.frame.size
            let centerX = Self.trafficLightFirstCenterX + CGFloat(index) * Self.trafficLightSpacing
            let origin = NSPoint(
                x: centerX - size.width / 2,
                y: container.bounds.height - Self.trafficLightCenterFromTop - size.height / 2
            )
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }

    /// AppKit 在窗口尺寸/激活等布局时会把按钮排回原生位置，
    /// 监听按钮 frame 变化，等它排完再覆盖回样机位。
    private func installTrafficLightObserversIfNeeded() {
        guard chrome == .workspace, !trafficLightObserversInstalled, let window else { return }
        trafficLightObserversInstalled = true
        for type in Self.trafficLightTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(trafficLightLayoutChanged),
                name: NSView.frameDidChangeNotification,
                object: button
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(trafficLightLayoutChanged),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @objc private func trafficLightLayoutChanged(_ note: Notification) {
        // 让 AppKit 先把这轮布局做完，我们再覆盖；目标位相同则不写，
        // 所以不会和 frameDidChange 互相触发成环。
        Task { @MainActor [weak self] in
            self?.repositionTrafficLights()
        }
    }
}
#endif
