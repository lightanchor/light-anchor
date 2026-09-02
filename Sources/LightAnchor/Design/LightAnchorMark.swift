import AppKit
import CoreGraphics
import SwiftUI

/// 品牌标记「蜜芽方块」：一块圆角软方墩，右上角浮着一枚蓝点。
///
/// 方墩恒定不变，蓝点承担状态（要求 6：形态即状态）——菜单栏里无论当前是
/// 哪种状态，用户都能靠方墩认出这是轻锚。应用图标上方墩是蜜色、点是蓝色；
/// 菜单栏是单色 template，靠形状区分。
///
/// 这个文件只依赖 AppKit / CoreGraphics / SwiftUI（取连续圆角路径），
/// `Scripts/make-brand-assets.swift` 会连同它一起编译，应用图标、SVG logo
/// 和菜单栏图标因此共用同一套几何，不会各自漂移。
enum LightAnchorMarkState: String, CaseIterable, Sendable {
    /// 实心点：正在进行中。
    case active
    /// 双环：准备返回。
    case returning
    /// 点环：等待外部结果。
    case waiting
    /// 空心环：空闲或暂停。
    case idle
}

enum LightAnchorMark {

    // MARK: - 设计网格

    /// 常量都写在 24 单位的设计网格里，y 轴向下（和设计稿一致）。渲染时统一
    /// 换算，调用方只给一个目标矩形。
    static let squareRect = CGRect(x: 2.6, y: 8.2, width: 14.6, height: 12.6)
    static let squareCornerRadius: CGFloat = 5
    /// 蓝点的外缘半径：四种状态共用，保证形态切换时视觉直径不跳动。
    static let dotCenter = CGPoint(x: 19.4, y: 5)
    static let dotOuterRadius: CGFloat = 4.6
    /// 双环状态里的内实心点。
    static let innerDotRadius: CGFloat = 1.4
    /// 点环的点数。
    static let waitingDotCount = 7
    /// 环的描边宽度按半径走：纯平块面风格里环也要厚，细线会和方墩失衡。
    static var ringStroke: CGFloat { dotOuterRadius * 0.42 }

    /// 品牌固定色（与 Scripts/make-brand-assets.swift 的 Brand 一致）：
    /// 蜜色和蓝点在浅色深色底上都成立，标记不换色。
    static let brandHoneyColor = CGColor(
        red: 0xF3 / 255, green: 0xD0 / 255, blue: 0x7F / 255, alpha: 1
    )
    static let brandBlueColor = CGColor(
        red: 0x5B / 255, green: 0xA7 / 255, blue: 0xCE / 255, alpha: 1
    )

    /// 标记的外接框，用于等比适配到目标矩形。
    static var bounds: CGRect {
        squareRect.union(CGRect(
            x: dotCenter.x - dotOuterRadius,
            y: dotCenter.y - dotOuterRadius,
            width: dotOuterRadius * 2,
            height: dotOuterRadius * 2
        ))
    }

    /// 方墩用 `.continuous` 连续圆角，和 macOS 图标的圆角是同一种曲率。
    static var squarePath: CGPath {
        Path(roundedRect: squareRect, cornerRadius: squareCornerRadius, style: .continuous).cgPath
    }

    // MARK: - 绘制

    /// 把标记等比居中画进 `box`。`box` 用调用方的坐标系，函数内部自己翻转 y。
    /// 应用图标传两种颜色；菜单栏 template 图传同一种。
    static func draw(
        _ state: LightAnchorMarkState,
        in context: CGContext,
        fitting box: CGRect,
        shape shapeColor: CGColor,
        dot dotColor: CGColor
    ) {
        let source = bounds
        let scale = min(box.width / source.width, box.height / source.height)
        guard scale > 0 else { return }

        context.saveGState()
        context.translateBy(x: box.midX, y: box.midY)
        // y 向下的设计坐标 → CoreGraphics 的 y 向上坐标。
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -source.midX, y: -source.midY)

        context.setFillColor(shapeColor)
        context.addPath(squarePath)
        context.fillPath()

        context.setFillColor(dotColor)
        context.setStrokeColor(dotColor)
        context.setLineCap(.round)
        drawDot(state, in: context)

        context.restoreGState()
    }

    static func draw(
        _ state: LightAnchorMarkState,
        in context: CGContext,
        fitting box: CGRect,
        color: CGColor
    ) {
        draw(state, in: context, fitting: box, shape: color, dot: color)
    }

    private static func drawDot(_ state: LightAnchorMarkState, in context: CGContext) {
        let stroke = ringStroke
        let ringRadius = dotOuterRadius - stroke / 2
        context.setLineWidth(stroke)

        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(
                x: dotCenter.x - radius,
                y: dotCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }

        switch state {
        case .active:
            context.fillEllipse(in: circle(dotOuterRadius))
        case .returning:
            context.strokeEllipse(in: circle(ringRadius))
            context.fillEllipse(in: circle(innerDotRadius))
        case .waiting:
            // 圆点环：0 长度的虚线段配圆头描边，得到间距均匀的小圆点。
            context.saveGState()
            context.setLineDash(phase: 0, lengths: [0.001, 2 * .pi * ringRadius / CGFloat(waitingDotCount)])
            context.beginPath()
            context.addArc(
                center: dotCenter,
                radius: ringRadius,
                startAngle: .pi / 2,
                endAngle: .pi / 2 + 2 * .pi,
                clockwise: false
            )
            context.strokePath()
            context.restoreGState()
        case .idle:
            context.strokeEllipse(in: circle(ringRadius))
        }
    }

    // MARK: - 菜单栏

    /// 四种形态的图标缓存。菜单栏标签每次场景更新都会重新求值，重画
    /// 位图会把这个开销压在主线程上——图标只有四种，画一次留着用。
    @MainActor
    private static var statusItemImageCache: [LightAnchorMarkState: NSImage] = [:]

    @MainActor
    static func cachedStatusItemImage(_ state: LightAnchorMarkState) -> NSImage {
        if let cached = statusItemImageCache[state] { return cached }
        let image = statusItemImage(state)
        statusItemImageCache[state] = image
        return image
    }

    /// 菜单栏状态项图标。
    ///
    /// 返回 template 图像：菜单栏的前景色、深色外观和高亮状态由系统反色，
    /// 我们不自己上色——菜单栏里的方墩和点都是当前菜单栏文字色。
    static func statusItemImage(_ state: LightAnchorMarkState) -> NSImage {
        let pointSize: CGFloat = 18
        let liveHeight: CGFloat = 14
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = liveHeight / bounds.height
            let width = bounds.width * scale
            let box = CGRect(
                x: rect.midX - width / 2,
                y: rect.midY - liveHeight / 2,
                width: width,
                height: liveHeight
            )
            draw(state, in: context, fitting: box, color: NSColor.black.cgColor)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.menuBarAccessibilityDescription
        return image
    }
}

extension LightAnchorMarkState {

    var menuBarAccessibilityDescription: String {
        switch self {
        case .active: tr("light_anchor_active")
        case .returning: tr("light_anchor_ready_to_return")
        case .waiting: tr("light_anchor_waiting")
        case .idle: tr("light_anchor_idle")
        }
    }
}
