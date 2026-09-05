import AppKit
import Combine
import Foundation
import SwiftUI

/// The three user-facing choices. The selected mode is persisted; the resolved
/// theme is calculated separately so automatic mode can follow the system
/// appearance without rebuilding any of the app's views.
enum LightAnchorThemeMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: tr("auto")
        case .light: tr("light")
        case .dark: tr("dark")
        }
    }

    var detail: String {
        switch self {
        case .automatic: tr("follow_the_system_between_light_and")
        case .light: tr("always_use_the_warm_light_interface")
        case .dark: tr("always_use_the_dark_interface")
        }
    }

    var fixedTheme: LightAnchorResolvedTheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum LightAnchorResolvedTheme: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: tr("light")
        case .dark: tr("dark")
        }
    }

    var preferredColorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

struct LightAnchorRGBA: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Native color parsing used by the design token palette. It intentionally
/// accepts only the token formats we support so malformed values never get
/// silently interpreted as a platform-dependent color.
enum LightAnchorColorMath {
    static let defaultHex = "#5BA7CE"

    static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard (raw.count == 3 || raw.count == 4 || raw.count == 6 || raw.count == 8),
              raw.allSatisfy(\.isHexDigit)
        else { return nil }
        let uppercased = raw.uppercased()
        if uppercased.count == 3 || uppercased.count == 4 {
            return "#" + uppercased.map { "\($0)\($0)" }.joined()
        }
        return "#" + uppercased
    }

    static func components(for value: String) -> LightAnchorRGBA? {
        if let hex = normalizedHex(value) {
            let raw = String(hex.dropFirst())
            guard let number = UInt64(raw, radix: 16) else { return nil }
            let alpha = raw.count == 8 ? Double(number & 0xFF) / 255 : 1
            let rgb = raw.count == 8 ? number >> 8 : number
            return LightAnchorRGBA(
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                alpha: alpha
            )
        }

        return oklchComponents(for: value)
    }

    static func oklchComponents(for value: String) -> LightAnchorRGBA? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("oklch(") else { return nil }
        guard let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close else {
            return nil
        }

        let body = String(trimmed[trimmed.index(after: open)..<close])
            .replacingOccurrences(of: "/", with: " / ")
        let parts = body.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," }
        guard parts.count >= 3 else { return nil }

        guard let lightness = parseComponent(String(parts[0]), percentageScale: 100),
              let chroma = parseComponent(String(parts[1]), percentageScale: 0.4),
              let hue = parseHue(String(parts[2]))
        else { return nil }

        var alpha = 1.0
        if let slashIndex = parts.firstIndex(of: "/"), parts.count > slashIndex + 1 {
            guard let parsedAlpha = parseComponent(String(parts[slashIndex + 1]), percentageScale: 100) else {
                return nil
            }
            alpha = parsedAlpha
        }

        return convertOKLCHToSRGB(
            lightness: min(max(lightness, 0), 1),
            chroma: max(chroma, 0),
            hueDegrees: hue,
            alpha: min(max(alpha, 0), 1)
        )
    }

    private static func parseComponent(_ value: String, percentageScale: Double) -> Double? {
        if value.lowercased() == "none" { return 0 }
        if value.hasSuffix("%") {
            guard let number = Double(value.dropLast()) else { return nil }
            return number / 100 * (percentageScale == 100 ? 1 : percentageScale)
        }
        return Double(value)
    }

    private static func parseHue(_ value: String) -> Double? {
        if value.lowercased() == "none" { return 0 }
        if value.lowercased().hasSuffix("deg") {
            return Double(value.dropLast(3))
        }
        return Double(value)
    }

    private static func convertOKLCHToSRGB(
        lightness: Double,
        chroma: Double,
        hueDegrees: Double,
        alpha: Double
    ) -> LightAnchorRGBA {
        let radians = hueDegrees * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

        let linearRed = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let linearGreen = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let linearBlue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        return LightAnchorRGBA(
            red: gammaEncode(linearRed),
            green: gammaEncode(linearGreen),
            blue: gammaEncode(linearBlue),
            alpha: alpha
        )
    }

    private static func gammaEncode(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        if clamped <= 0.0031308 {
            return 12.92 * clamped
        }
        return 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

enum LightAnchorThemeRole: String, CaseIterable, Hashable, Sendable {
    case background
    case foreground
    case card
    case popover
    case muted
    case mutedForeground
    case primary
    case primaryForeground
    case accent
    case destructive
    case border
    case sidebar
    case sidebarAccent
    case sidebarBorder
    // r23「换一件事」舞台面板（docs/switch-work-redesign-r23-2026-09-04.html 定稿）专属色。
    case stagePanel
    case stageSidebar
    case stageLine
    case stageLineSoft
    case stageRowHover
    case stageMuted
    case stageFaint
    case stageAccentSoft
    case stageWash
    case brand
    case highlight
    case text1
    case text2
    case text3
    case text4
    case textRedBold
    case textBlue
    case textBlueBold
    case border100
    case border200
    case fill100
    case fill150
    case fill200
    case iconSoft400
    case iconDisabled100
    case iconDisabled300
    case iconSub600
    case iconAmber
    case errorDark
    case chart1
    case chart2
    case chart3
    case chart4
    case chart5
    case success
    case successBackground
    case warning
    case warningBackground
    case danger
    case dangerBackground
    case clear
}

/// A complete role palette for the Blue Dot design language. Token strings are
/// retained alongside resolved colors so tests and diagnostics can verify the
/// source design variables.
///
/// 设计基准：暖白 cozy 体系（蓝点视觉语言的定稿体系）。
/// 主色 #5BA7CE 承担填充与识别；文字级强调使用同族加深 #2F7099。
struct LightAnchorThemePalette {
    let theme: LightAnchorResolvedTheme
    private let tokenStrings: [String: String]
    private let tokenColors: [String: LightAnchorRGBA]

    init(theme: LightAnchorResolvedTheme) {
        self.theme = theme
        let tokens = Self.tokens(for: theme)
        tokenStrings = tokens
        tokenColors = tokens.reduce(into: [String: LightAnchorRGBA]()) { result, pair in
            if let color = LightAnchorColorMath.components(for: pair.value) {
                result[pair.key] = color
            }
        }
    }

    static let light = LightAnchorThemePalette(theme: .light)

    func token(_ name: String) -> String? {
        tokenStrings[name]
    }

    func color(for role: LightAnchorThemeRole) -> Color {
        let tokenName = Self.tokenName(for: role)
        guard let rgba = tokenColors[tokenName] else { return .clear }
        return Color(red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    private static func tokenName(for role: LightAnchorThemeRole) -> String {
        switch role {
        case .chart1: "chart-1"
        case .chart2: "chart-2"
        case .chart3: "chart-3"
        case .chart4: "chart-4"
        case .chart5: "chart-5"
        default: role.rawValue
        }
    }

    private static func tokens(for theme: LightAnchorResolvedTheme) -> [String: String] {
        switch theme {
        case .light: cozyLightTokens
        case .dark: cozyDarkTokens
        }
    }

    /// 暖白（浅色）：侧栏米白、内容奶油白、卡片纯白；天空蓝主色 + 宜绿 / 暖黄 / 暖红语义色。
    private static let cozyLightTokens: [String: String] = [
        "background": "#FBF8F3",
        "foreground": "#3B3644",
        "card": "#FFFFFF",
        "popover": "#FFFFFF",
        "primary": "#5BA7CE",
        "primaryForeground": "#FFFFFF",
        "muted": "#F3EFE7",
        "mutedForeground": "#6E6879",
        "accent": "#5BA7CE29",
        "destructive": "#B4524B",
        "border": "#E7E0D4",
        "sidebar": "#F5F1EA",
        "sidebarAccent": "#EBE4D8",
        "sidebarBorder": "#EEE8DD",
        // r23「换一件事」舞台面板：定稿 HTML :root 里的 --panel / --sb-bg / --line /
        // --line-soft / --row-hover / --muted / --faint / --accent-soft / --wash。
        "stagePanel": "#FDFCFA",
        "stageSidebar": "#F4F2ED",
        "stageLine": "#E7E4DD",
        "stageLineSoft": "#EFECE5",
        "stageRowHover": "#EDEAE3",
        "stageMuted": "#8B889C",
        "stageFaint": "#B6B3C2",
        "stageAccentSoft": "#8FC4DD",
        "stageWash": "#EAF3F8",
        "brand": "#5BA7CE",
        "highlight": "#F6E3AE",
        "text1": "#3B3644",
        "text2": "#6E6879",
        "text3": "#6E6879",
        "text4": "#ACA6B8",
        "textRedBold": "#8E3A34",
        "textBlue": "#2F7099",
        "textBlueBold": "#275E80",
        "border100": "#3B364414",
        "border200": "#3B364424",
        "fill100": "#3B36440A",
        "fill150": "#3B36441A",
        "fill200": "#3B364433",
        "iconSoft400": "#6E6879",
        "iconDisabled100": "#C3BECC",
        "iconDisabled300": "#9A94A6",
        "iconSub600": "#55505F",
        "iconAmber": "#F6E3AE",
        "errorDark": "#A84A43",
        "chart-1": "#5BA7CE",
        "chart-2": "#3E9B4F",
        "chart-3": "#2A7437",
        "chart-4": "#E8C26A",
        "chart-5": "#7E6112",
        "success": "#2A7437",
        "successBackground": "#3E9B4F",
        "warning": "#7E6112",
        "warningBackground": "#F6E3AE",
        "danger": "#A84A43",
        "dangerBackground": "#B4524B",
        "clear": "#00000000"
    ]

    /// 暖调深紫灰（深色）：不是冷蓝黑；主色提亮为 #79C0E6，按钮文字用深墨。
    private static let cozyDarkTokens: [String: String] = [
        "background": "#211E28",
        "foreground": "#ECE8F1",
        "card": "#2A2733",
        "popover": "#322E3C",
        "primary": "#79C0E6",
        "primaryForeground": "#142430",
        "muted": "#262330",
        "mutedForeground": "#A49DB0",
        "accent": "#79C0E624",
        "destructive": "#E08A80",
        "border": "#35313F",
        "sidebar": "#1C1922",
        "sidebarAccent": "#322E3C",
        "sidebarBorder": "#2E2A38",
        // r23 舞台面板（body.dark）。--wash 在深色下本来就是半透明的 rgba(121,192,230,.14)。
        "stagePanel": "#211F28",
        "stageSidebar": "#1B1A21",
        "stageLine": "#302E3A",
        "stageLineSoft": "#2A2833",
        "stageRowHover": "#282631",
        "stageMuted": "#A5A2B4",
        "stageFaint": "#6F6C80",
        "stageAccentSoft": "#5A9CC0",
        "stageWash": "#79C0E624",
        "brand": "#79C0E6",
        "highlight": "#E8C26A29",
        "text1": "#ECE8F1",
        "text2": "#A49DB0",
        "text3": "#A49DB0",
        "text4": "#746D82",
        "textRedBold": "#EFA79E",
        "textBlue": "#A8D6F2",
        "textBlueBold": "#C1E2F7",
        "border100": "#ECE8F114",
        "border200": "#ECE8F124",
        "fill100": "#ECE8F10A",
        "fill150": "#ECE8F11A",
        "fill200": "#ECE8F133",
        "iconSoft400": "#A49DB0",
        "iconDisabled100": "#5B5468",
        "iconDisabled300": "#746D82",
        "iconSub600": "#BEB8CA",
        "iconAmber": "#E8C26A",
        "errorDark": "#EFA79E",
        "chart-1": "#79C0E6",
        "chart-2": "#6DBF7C",
        "chart-3": "#8FD49B",
        "chart-4": "#E8C26A",
        "chart-5": "#D9A54E",
        "success": "#8FD49B",
        "successBackground": "#6DBF7C",
        "warning": "#E8C26A",
        "warningBackground": "#E8C26A29",
        "danger": "#EFA79E",
        "dangerBackground": "#E08A80",
        "clear": "#00000000"
    ]
}

struct LightAnchorThemeColor: ShapeStyle, Equatable, Sendable {
    let role: LightAnchorThemeRole
    private let alphaMultiplier: Double

    init(_ role: LightAnchorThemeRole, alphaMultiplier: Double = 1) {
        self.role = role
        self.alphaMultiplier = alphaMultiplier
    }

    static let clear = LightAnchorThemeColor(.clear)

    func opacity(_ opacity: Double) -> LightAnchorThemeColor {
        LightAnchorThemeColor(role, alphaMultiplier: alphaMultiplier * opacity)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.lightAnchorPalette.color(for: role)
            .opacity(alphaMultiplier)
    }
}

private struct LightAnchorPaletteKey: EnvironmentKey {
    static let defaultValue = LightAnchorThemePalette.light
}

extension EnvironmentValues {
    var lightAnchorPalette: LightAnchorThemePalette {
        get { self[LightAnchorPaletteKey.self] }
        set { self[LightAnchorPaletteKey.self] = newValue }
    }
}

extension View {
    func lightAnchorTheme(_ theme: LightAnchorResolvedTheme) -> some View {
        environment(\.lightAnchorPalette, LightAnchorThemePalette(theme: theme))
            .preferredColorScheme(theme.preferredColorScheme)
    }
}

@MainActor
final class LightAnchorThemeController: ObservableObject {
    nonisolated static let storageKey = "appearance.theme"
    static let defaultMode: LightAnchorThemeMode = .automatic

    @Published private(set) var mode: LightAnchorThemeMode
    @Published private(set) var resolvedTheme: LightAnchorResolvedTheme

    private let defaults: UserDefaults
    private let systemThemeProvider: () -> LightAnchorResolvedTheme
    private let notificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter?
    private var observers: [NSObjectProtocol] = []

    /// The system appearance, read from AppKit. Injected in tests.
    nonisolated static func systemAppearanceTheme() -> LightAnchorResolvedTheme {
        // 签名保持 nonisolated（它是 init 的默认实参，测试要能塞普通闭包），
        // 但 NSApplication.shared 在 macOS 15 SDK 上是主 actor 独占的。
        // 两个调用点都在 @MainActor 的本类里，assumeIsolated 不会踩空。
        MainActor.assumeIsolated {
            let appearance = NSApplication.shared.effectiveAppearance
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    init(
        defaults: UserDefaults = .standard,
        systemThemeProvider: @escaping () -> LightAnchorResolvedTheme = LightAnchorThemeController.systemAppearanceTheme,
        notificationCenter: NotificationCenter = .default,
        distributedNotificationCenter: NotificationCenter? = DistributedNotificationCenter.default(),
        startObserving: Bool = true
    ) {
        self.defaults = defaults
        self.systemThemeProvider = systemThemeProvider
        self.notificationCenter = notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        let storedMode = defaults.string(forKey: Self.storageKey).flatMap(LightAnchorThemeMode.init(rawValue:))
        let initialMode = storedMode ?? Self.defaultMode
        mode = initialMode
        resolvedTheme = initialMode.fixedTheme ?? systemThemeProvider()
        if startObserving {
            installObservers()
        }
    }

    func select(_ newMode: LightAnchorThemeMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Self.storageKey)
        refresh()
    }

    func refresh() {
        let nextTheme = mode.fixedTheme ?? systemThemeProvider()
        if resolvedTheme != nextTheme {
            resolvedTheme = nextTheme
        }
    }

    private func installObservers() {
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSWorkspace.didWakeNotification
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        // 系统外观切换没有进程内通知；AppKit 通过分布式通知广播。
        if let distributedNotificationCenter {
            observers.append(distributedNotificationCenter.addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }
}
