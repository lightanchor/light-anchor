import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - 接入方品牌标识
//
// 「一看就知道是谁」：本机装了对方应用就直接用系统里的真实图标
// （NSWorkspace / 应用资源）；没有桌面应用的（PI、dsh）用内嵌的
// 官方矢量标（BrandMarkAssets）；都拿不到时才落到手绘记号兜底。

enum IntegrationBrand: String, CaseIterable {
    case claudeCode
    case codex
    case pi
    case dsh
    case terminal

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "PI"
        case .dsh: "dsh"
        case .terminal: tr("terminal_zsh")
        }
    }

    /// 从自动等待项推断品牌。correlationID 前缀由我们的接入脚本控制，
    /// 是最稳的依据；认不出的第三方 agent 不硬贴牌子。
    static func forAutoWait(_ waiting: WaitingItem) -> IntegrationBrand? {
        guard waiting.monitor?.eventAutoManaged == true else { return nil }
        let correlation = waiting.monitor?.eventCorrelationID ?? ""
        if correlation.hasPrefix("claude-") { return .claudeCode }
        if correlation.hasPrefix("codex-") { return .codex }
        if correlation.hasPrefix("pi-") { return .pi }
        if correlation.hasPrefix("dsh-") { return .dsh }
        if waiting.kind == .command { return .terminal }
        return nil
    }
}

struct IntegrationBrandIcon: View {
    let brand: IntegrationBrand
    var size: CGFloat = 22
    /// 旁边有品牌名文字时是装饰（默认）；图标是「这来自哪个工具」唯一来源时
    /// （等待行），传 false 让旁白读得到品牌名。
    var isDecorative = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            #if os(macOS)
            if let icon = BrandApplicationIcons.icon(for: brand, darkVariant: colorScheme == .dark) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                drawnGlyph
            }
            #else
            drawnGlyph
            #endif
        }
        .frame(width: size, height: size)
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(isDecorative ? "" : brand.title)
    }

    /// 矢量兜底：装在与真实图标同体量的圆角瓦片里，密度上不打架。
    /// 品牌本色取自 Design 层的 LightAnchorBrandPalette，不随主题变化。
    @ViewBuilder
    private var drawnGlyph: some View {
        switch brand {
        case .claudeCode:
            glyphTile(background: LightAnchorBrandPalette.claudeCream) {
                ClaudeSunburstShape()
                    .fill(LightAnchorBrandPalette.claudeCoral)
                    .padding(size * 0.18)
            }
        case .codex:
            // Codex 官方形态：蓝紫渐变的花云 + 白色 >_ 提示符。
            glyphTile(background: LightAnchorBrandPalette.codexPaper) {
                ZStack {
                    BlossomCloudShape()
                        .fill(LightAnchorBrandPalette.codexGradient)
                        .padding(size * 0.1)
                    Text(">_")
                        .font(.system(size: size * 0.3, weight: .heavy, design: .monospaced))
                        .foregroundStyle(LightAnchorBrandPalette.codexPaper)
                        .offset(y: -size * 0.01)
                }
            }
        case .pi:
            glyphTile(background: LightAnchorBrandPalette.piSlate) {
                Text("π")
                    .font(.system(size: size * 0.56, weight: .semibold, design: .serif))
                    .foregroundStyle(LightAnchorBrandPalette.codexPaper)
                    .offset(y: -size * 0.02)
            }
        case .dsh:
            // DeepSeek 的品牌蓝鲸。
            glyphTile(background: LightAnchorBrandPalette.codexPaper) {
                DeepSeekWhaleShape()
                    .fill(LightAnchorBrandPalette.deepseekBlue)
                    .padding(size * 0.14)
            }
        case .terminal:
            glyphTile(background: LightAnchorTheme.ink) {
                Text(">_")
                    .font(.system(size: size * 0.42, weight: .bold, design: .monospaced))
                    .foregroundStyle(LightAnchorTheme.surface)
            }
        }
    }

    private func glyphTile(
        background: some ShapeStyle,
        @ViewBuilder content: () -> some View
    ) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(background)
            .overlay(content())
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 0.5)
            }
    }
}

#if os(macOS)
/// 真实应用图标的查找与缓存（NSWorkspace / 应用资源的读取不便宜）。
/// 只在主线程用（SwiftUI 视图渲染路径），缓存无需加锁。
@MainActor
enum BrandApplicationIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for brand: IntegrationBrand, darkVariant: Bool) -> NSImage? {
        let key = "\(brand.rawValue)-\(darkVariant ? "dark" : "light")"
        if let cached = cache[key] { return cached }
        let icon = lookUp(brand, darkVariant: darkVariant)
        cache[key] = icon
        return icon
    }

    private static func lookUp(_ brand: IntegrationBrand, darkVariant: Bool) -> NSImage? {
        switch brand {
        case .terminal:
            // 系统终端图标人人认识。按 bundle ID 查（路径随系统版本会挪）。
            return applicationIcon(bundleIdentifier: "com.apple.Terminal")
                ?? applicationIcon(atPath: "/System/Applications/Utilities/Terminal.app")
                ?? applicationIcon(atPath: "/System/Applications/Terminal.app")
        case .claudeCode:
            // 装了 Claude 桌面版就用它的真实图标。
            return applicationIcon(bundleIdentifier: "com.anthropic.claudefordesktop")
        case .codex:
            // Codex 桌面端（bundle id com.openai.codex）的资源里带专门的
            // Codex 标（分明暗两版）；app.icns 是 ChatGPT 自己的图标，不能用。
            return codexResourceIcon(darkVariant: darkVariant)
        case .pi:
            // pi 官方 favicon（BrandMarkAssets 内嵌 SVG）。
            return BrandMarkAssets.piTileImage()
        case .dsh:
            // DeepSeek 官方鲸标合成白砖（BrandMarkAssets 内嵌 SVG）。
            return BrandMarkAssets.deepseekTileImage()
        }
    }

    private static func codexResourceIcon(darkVariant: Bool) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else { return nil }
        let resources = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let candidates = darkVariant
            ? ["icon-codex-dark-color.png", "icon-codex-light.png"]
            : ["icon-codex-light.png", "icon-codex-dark-color.png"]
        for name in candidates {
            let url = resources.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }
        return applicationIcon(atPath: url.path)
    }

    private static func applicationIcon(atPath path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }
}
#endif

// MARK: - 矢量品牌记号

/// Claude 的珊瑚色星芒：中心向外的一圈锥形射线。
struct ClaudeSunburstShape: Shape {
    var rayCount = 11

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.16
        // 射线根部的半宽（弧度）：根宽尖细，读作星芒而不是齿轮。
        let halfWidth = .pi / Double(rayCount) * 0.42

        for index in 0..<rayCount {
            let angle = (Double(index) / Double(rayCount)) * 2 * .pi - .pi / 2
            let tip = CGPoint(
                x: center.x + cos(angle) * outer,
                y: center.y + sin(angle) * outer
            )
            let baseLeft = CGPoint(
                x: center.x + cos(angle - halfWidth) * inner,
                y: center.y + sin(angle - halfWidth) * inner
            )
            let baseRight = CGPoint(
                x: center.x + cos(angle + halfWidth) * inner,
                y: center.y + sin(angle + halfWidth) * inner
            )
            path.move(to: baseLeft)
            path.addLine(to: tip)
            path.addLine(to: baseRight)
            path.closeSubpath()
        }
        return path
    }
}

/// Codex 记号的花云轮廓：一圈圆瓣叠出的云朵/花形剪影。
struct BlossomCloudShape: Shape {
    var petalCount = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let petalRadius = outer * 0.42
        let orbit = outer - petalRadius

        // 中心圆补满花瓣之间的缝。
        path.addEllipse(in: CGRect(
            x: center.x - orbit - petalRadius * 0.4,
            y: center.y - orbit - petalRadius * 0.4,
            width: (orbit + petalRadius * 0.4) * 2,
            height: (orbit + petalRadius * 0.4) * 2
        ))
        for index in 0..<petalCount {
            let angle = (Double(index) / Double(petalCount)) * 2 * .pi - .pi / 2
            let petalCenter = CGPoint(
                x: center.x + cos(angle) * orbit,
                y: center.y + sin(angle) * orbit
            )
            path.addEllipse(in: CGRect(
                x: petalCenter.x - petalRadius,
                y: petalCenter.y - petalRadius,
                width: petalRadius * 2,
                height: petalRadius * 2
            ))
        }
        return path
    }
}

/// DeepSeek 的蓝鲸剪影：一道圆背的身躯 + 上扬的尾鳍。
struct DeepSeekWhaleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY

        // 身躯：从头部（左）沿圆背到尾根。
        path.move(to: CGPoint(x: x + w * 0.04, y: y + h * 0.58))
        path.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.16),
            control1: CGPoint(x: x + w * 0.04, y: y + h * 0.3),
            control2: CGPoint(x: x + w * 0.24, y: y + h * 0.16)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.72, y: y + h * 0.4),
            control1: CGPoint(x: x + w * 0.62, y: y + h * 0.16),
            control2: CGPoint(x: x + w * 0.68, y: y + h * 0.28)
        )
        // 尾鳍上叶：上扬扫出。
        path.addCurve(
            to: CGPoint(x: x + w * 0.97, y: y + h * 0.2),
            control1: CGPoint(x: x + w * 0.78, y: y + h * 0.32),
            control2: CGPoint(x: x + w * 0.88, y: y + h * 0.22)
        )
        // 叉口收回。
        path.addCurve(
            to: CGPoint(x: x + w * 0.84, y: y + h * 0.48),
            control1: CGPoint(x: x + w * 0.95, y: y + h * 0.32),
            control2: CGPoint(x: x + w * 0.9, y: y + h * 0.42)
        )
        // 尾鳍下叶：再扫出。
        path.addCurve(
            to: CGPoint(x: x + w * 0.95, y: y + h * 0.68),
            control1: CGPoint(x: x + w * 0.9, y: y + h * 0.54),
            control2: CGPoint(x: x + w * 0.94, y: y + h * 0.6)
        )
        // 回到尾根下缘。
        path.addCurve(
            to: CGPoint(x: x + w * 0.7, y: y + h * 0.6),
            control1: CGPoint(x: x + w * 0.88, y: y + h * 0.72),
            control2: CGPoint(x: x + w * 0.76, y: y + h * 0.68)
        )
        // 腹线回到头部。
        path.addCurve(
            to: CGPoint(x: x + w * 0.28, y: y + h * 0.72),
            control1: CGPoint(x: x + w * 0.58, y: y + h * 0.74),
            control2: CGPoint(x: x + w * 0.42, y: y + h * 0.76)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.04, y: y + h * 0.58),
            control1: CGPoint(x: x + w * 0.14, y: y + h * 0.68),
            control2: CGPoint(x: x + w * 0.05, y: y + h * 0.62)
        )
        path.closeSubpath()
        return path
    }
}
