import XCTest
@testable import LightAnchor

/// WCAG 对比度（测试专用）：从渲染后的前景/背景对测量。
/// 曾住在 LightAnchorColorMath 里，生产代码不用它，搬来测试侧。
private extension LightAnchorColorMath {
    static func contrastRatio(foreground: String, background: String) -> Double? {
        guard let foreground = components(for: foreground),
              let background = components(for: background)
        else { return nil }

        func composite(_ foreground: LightAnchorRGBA, over background: LightAnchorRGBA) -> LightAnchorRGBA {
            let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
            guard alpha > 0 else { return LightAnchorRGBA(red: 0, green: 0, blue: 0, alpha: 0) }
            return LightAnchorRGBA(
                red: (foreground.red * foreground.alpha
                    + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
                green: (foreground.green * foreground.alpha
                    + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
                blue: (foreground.blue * foreground.alpha
                    + background.blue * background.alpha * (1 - foreground.alpha)) / alpha,
                alpha: alpha
            )
        }

        func linearize(_ value: Double) -> Double {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        func luminance(_ color: LightAnchorRGBA) -> Double {
            0.2126 * linearize(color.red)
                + 0.7152 * linearize(color.green)
                + 0.0722 * linearize(color.blue)
        }

        // Contrast is measured from the rendered pair. Palette surfaces are
        // opaque today, while several support-text tokens use alpha.
        let renderedBackground = composite(
            background,
            over: LightAnchorRGBA(red: 1, green: 1, blue: 1)
        )
        let renderedForeground = composite(foreground, over: renderedBackground)
        let foregroundLuminance = luminance(renderedForeground)
        let backgroundLuminance = luminance(renderedBackground)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

final class LightAnchorPaletteTests: XCTestCase {
    func testPaletteDefinesCozyLightAndDarkTokens() {
        let light = LightAnchorThemePalette(theme: .light)
        XCTAssertEqual(light.token("background"), "#FBF8F3")
        XCTAssertEqual(light.token("sidebar"), "#F5F1EA")
        XCTAssertEqual(light.token("card"), "#FFFFFF")
        XCTAssertEqual(light.token("primary"), "#5BA7CE")
        XCTAssertEqual(light.token("textBlue"), "#2F7099")
        XCTAssertEqual(light.token("sidebarAccent"), "#EBE4D8")
        XCTAssertEqual(light.token("border"), "#E7E0D4")
        XCTAssertEqual(light.token("highlight"), "#F6E3AE")
        XCTAssertEqual(light.token("successBackground"), "#3E9B4F")
        XCTAssertEqual(light.token("foreground"), "#3B3644")

        let dark = LightAnchorThemePalette(theme: .dark)
        XCTAssertEqual(dark.token("background"), "#211E28")
        XCTAssertEqual(dark.token("sidebar"), "#1C1922")
        XCTAssertEqual(dark.token("card"), "#2A2733")
        XCTAssertEqual(dark.token("primary"), "#79C0E6")
        XCTAssertEqual(dark.token("primaryForeground"), "#142430")
        XCTAssertEqual(dark.token("foreground"), "#ECE8F1")
    }

    func testNormalizesSupportedHexValuesForAssetParsing() {
        XCTAssertEqual(LightAnchorColorMath.normalizedHex("d96c52"), "#D96C52")
        XCTAssertEqual(LightAnchorColorMath.normalizedHex(" #3489b8 "), "#3489B8")
        XCTAssertEqual(LightAnchorColorMath.normalizedHex("#292c3308"), "#292C3308")
        XCTAssertEqual(LightAnchorColorMath.normalizedHex("#fff"), "#FFFFFF")
    }

    func testRejectsIncompleteAndInvalidHexValues() {
        XCTAssertNil(LightAnchorColorMath.normalizedHex("#FFFFF"))
        XCTAssertNil(LightAnchorColorMath.normalizedHex("#GGGGGG"))
        XCTAssertNil(LightAnchorColorMath.normalizedHex(""))
    }

    func testParsesHexAlphaAndOKLCHTokens() throws {
        let alpha = try XCTUnwrap(LightAnchorColorMath.components(for: "#292c3308"))
        XCTAssertEqual(alpha.red, 0x29 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(alpha.green, 0x2C / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(alpha.blue, 0x33 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(alpha.alpha, 0x08 / 255.0, accuracy: 0.000_001)

        let neutral = try XCTUnwrap(
            LightAnchorColorMath.components(for: "oklch(20.5% 0 0)")
        )
        XCTAssertEqual(neutral.red, 0.0905274, accuracy: 0.000_001)
        XCTAssertEqual(neutral.green, 0.0905274, accuracy: 0.000_001)
        XCTAssertEqual(neutral.blue, 0.0905274, accuracy: 0.000_001)
        XCTAssertEqual(neutral.alpha, 1, accuracy: 0.000_001)
    }

    func testContrastRatioMeasuresTheRenderedTranslucentForeground() throws {
        let ratio = try XCTUnwrap(
            LightAnchorColorMath.contrastRatio(
                foreground: "#292c3359",
                background: "#FFFFFF"
            )
        )

        XCTAssertEqual(ratio, 2.04, accuracy: 0.01)
    }

    /// 文字级 token 在每个表面上都必须可读。注意：文字级强调是 textBlue
    /// （主色 #5BA7CE 的加深档），主色本身只承担填充与识别，不作为正文颜色。
    func testReadableTextAndStatusTokensMeetContrastAcrossEveryThemeSurface() throws {
        for theme in LightAnchorResolvedTheme.allCases {
            let palette = LightAnchorThemePalette(theme: theme)
            let surfaceNames = ["background", "card", "popover", "sidebar", "muted"]
            let readableTokenNames = [
                "foreground", "textBlue", "mutedForeground", "text2", "text3",
                "errorDark", "warning", "danger", "chart-3"
            ]

            for surfaceName in surfaceNames {
                let surface = try XCTUnwrap(palette.token(surfaceName))
                for tokenName in readableTokenNames {
                    let foreground = try XCTUnwrap(palette.token(tokenName))
                    XCTAssertGreaterThanOrEqual(
                        try XCTUnwrap(
                            LightAnchorColorMath.contrastRatio(
                                foreground: foreground,
                                background: surface
                            )
                        ),
                        4.5,
                        "\(theme) \(tokenName) on \(surfaceName) must remain readable"
                    )
                }
            }
        }
    }

    /// 主按钮标签：深色主题达到 4.5；浅色主题是用户定稿的品牌配对
    /// （白字 on #5BA7CE ≈ 2.67）——经用户确认按"按钮标签例外"处理，
    /// 阈值锁定为不低于当前实测值，防止后续改色时进一步恶化。
    func testPrimaryActionLabelContrast() throws {
        let dark = LightAnchorThemePalette(theme: .dark)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(
                LightAnchorColorMath.contrastRatio(
                    foreground: try XCTUnwrap(dark.token("primaryForeground")),
                    background: try XCTUnwrap(dark.token("primary"))
                )
            ),
            4.5
        )

        let light = LightAnchorThemePalette(theme: .light)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(
                LightAnchorColorMath.contrastRatio(
                    foreground: try XCTUnwrap(light.token("primaryForeground")),
                    background: try XCTUnwrap(light.token("primary"))
                )
            ),
            2.6,
            "浅色主按钮为用户定稿的品牌例外（docs/design/blue-dot-requirements.md）"
        )
    }

    func testPrimaryActionUsesSkyBlue() {
        XCTAssertEqual(LightAnchorTheme.primaryAction, LightAnchorTheme.primaryText)
        XCTAssertEqual(
            LightAnchorThemePalette(theme: .light).token("primary"),
            "#5BA7CE"
        )
        XCTAssertEqual(
            LightAnchorThemePalette(theme: .light).token("brand"),
            "#5BA7CE"
        )
    }

    func testSupportTokensKeepTheirProvidedSemanticRoles() {
        XCTAssertEqual(LightAnchorTheme.secondaryInk.role, .text2)
        XCTAssertEqual(LightAnchorTheme.disabledInk.role, .text4)
        XCTAssertEqual(LightAnchorTheme.subtleFill.role, .fill100)
        XCTAssertEqual(LightAnchorTheme.selectedFill.role, .fill200)
        XCTAssertEqual(LightAnchorTheme.hairlineBorder.role, .border100)
        XCTAssertEqual(LightAnchorTheme.iconSoft.role, .iconSoft400)
        XCTAssertEqual(LightAnchorTheme.iconDisabled.role, .iconDisabled100)
        XCTAssertEqual(LightAnchorTheme.dangerText.role, .textRedBold)
        XCTAssertEqual(LightAnchorTheme.error.role, .errorDark)
        XCTAssertEqual(LightAnchorTheme.chartWarm.role, .chart1)
        XCTAssertEqual(LightAnchorTheme.chartYellow.role, .chart4)
        XCTAssertEqual(LightAnchorTheme.chartAmber.role, .chart5)
    }

    func testThemeModeHasTheThreeUserFacingChoices() {
        XCTAssertEqual(
            LightAnchorThemeMode.allCases.map(\.rawValue),
            ["automatic", "light", "dark"]
        )
        XCTAssertEqual(
            LightAnchorThemeMode.allCases.map(\.title),
            ["自动", "浅色", "深色"]
        )
    }
}

@MainActor
final class LightAnchorThemeControllerTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "LightAnchorThemeControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testControllerDefaultsToAutomaticAndIgnoresInvalidStoredValues() {
        let (defaults, suiteName) = makeDefaults()
        defaults.set("warm", forKey: LightAnchorThemeController.storageKey)
        let controller = LightAnchorThemeController(
            defaults: defaults,
            systemThemeProvider: { .dark },
            startObserving: false
        )
        XCTAssertEqual(controller.mode, .automatic)
        XCTAssertEqual(controller.resolvedTheme, .dark)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testControllerPersistsSelectionAndFollowsSystemInAutomaticMode() {
        let (defaults, suiteName) = makeDefaults()
        var systemTheme = LightAnchorResolvedTheme.light
        let controller = LightAnchorThemeController(
            defaults: defaults,
            systemThemeProvider: { systemTheme },
            startObserving: false
        )
        XCTAssertEqual(controller.resolvedTheme, .light)

        controller.select(.dark)
        XCTAssertEqual(controller.mode, .dark)
        XCTAssertEqual(controller.resolvedTheme, .dark)
        XCTAssertEqual(defaults.string(forKey: LightAnchorThemeController.storageKey), "dark")

        controller.select(.automatic)
        XCTAssertEqual(controller.resolvedTheme, .light)
        systemTheme = .dark
        controller.refresh()
        XCTAssertEqual(controller.resolvedTheme, .dark)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFixedModesIgnoreSystemAppearanceChanges() {
        let (defaults, suiteName) = makeDefaults()
        var systemTheme = LightAnchorResolvedTheme.dark
        let controller = LightAnchorThemeController(
            defaults: defaults,
            systemThemeProvider: { systemTheme },
            startObserving: false
        )
        controller.select(.light)
        systemTheme = .light
        controller.refresh()
        XCTAssertEqual(controller.resolvedTheme, .light)
        controller.select(.dark)
        controller.refresh()
        XCTAssertEqual(controller.resolvedTheme, .dark)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
