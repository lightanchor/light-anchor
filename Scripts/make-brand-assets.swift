// 轻锚品牌资源生成器。
//
// 用法：Scripts/make-brand-assets.sh
//
// 它和应用共用 Sources/LightAnchor/Design/LightAnchorMark.swift 里的「蜜芽方块」
// 几何（蜜色软方墩 + 右上角蓝点），所以菜单栏图标、应用图标和 logo 永远是同一个
// 标记，改一处全部跟着改。风格是 tty7 那种纯平：三个平色、无渐变、无阴影，
// 脸用底色挖空、只上大尺寸。
//
// 产出（Support/Brand/）：
//   AppIcon.icns / AppIcon-1024.png   应用图标
//   lightanchor-mark.svg              标记（矢量）
//   lightanchor-lockup-light.svg      横版 logo（浅色，字形已转路径）
//   lightanchor-lockup-dark.svg       横版 logo（深色）
//   brand-preview.png                 一张审阅用总览图

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 调色板

enum Brand {
    static let blue = rgb(0x5B, 0xA7, 0xCE)
    static let honey = rgb(0xF3, 0xD0, 0x7F)
    static let cream = rgb(0xFD, 0xFA, 0xF4)
    static let ink = rgb(0x3B, 0x36, 0x44)
    static let inkSoft = rgb(0x6E, 0x68, 0x79)
    static let blush = rgb(0xE8, 0x8E, 0x7A, 0.45)
    static let warmBackground = rgb(0xFB, 0xF8, 0xF3)
    static let darkBackground = rgb(0x21, 0x1E, 0x28)
    static let darkInk = rgb(0xEC, 0xE8, 0xF1)
    static let darkInkSoft = rgb(0xAC, 0xA6, 0xB8)

    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: a
        )
    }

    static func hex(_ color: CGColor) -> String {
        let c = color.components ?? [0, 0, 0, 1]
        return String(format: "#%02X%02X%02X", Int(c[0] * 255 + 0.5), Int(c[1] * 255 + 0.5), Int(c[2] * 255 + 0.5))
    }
}

// MARK: - 位图工具

func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建 \(width)×\(height) 位图上下文")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法写入 \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("PNG 编码失败：\(url.path)")
    }
}

// MARK: - 脸（挖在方墩上，只上大尺寸）

/// 脸的锚点：方墩中心，半径按方墩短边走。
let faceCenter = CGPoint(
    x: LightAnchorMark.squareRect.midX,
    y: LightAnchorMark.squareRect.midY
)
let faceRadius: CGFloat = 3.8

/// 在标记的 24 网格坐标系里画脸（调用方已经完成变换）。
func drawFace(in ctx: CGContext, eye: CGColor, ground: CGColor) {
    let c = faceCenter
    let r = faceRadius
    ctx.saveGState()
    ctx.setFillColor(Brand.blush)
    for direction in [CGFloat(-1), 1] {
        ctx.fillEllipse(in: CGRect(
            x: c.x + direction * 0.76 * r - 0.25 * r,
            y: c.y + 0.10 * r - 0.14 * r,
            width: 0.5 * r,
            height: 0.28 * r
        ))
    }
    _ = ground
    ctx.setFillColor(eye)
    ctx.setStrokeColor(eye)
    for direction in [CGFloat(-1), 1] {
        let eyeRect = CGRect(
            x: c.x + direction * 0.44 * r - 0.16 * r,
            y: c.y - 0.34 * r - 0.24 * r,
            width: 0.32 * r,
            height: 0.48 * r
        )
        ctx.addPath(CGPath(
            roundedRect: eyeRect,
            cornerWidth: eyeRect.width / 2,
            cornerHeight: eyeRect.width / 2,
            transform: nil
        ))
        ctx.fillPath()
    }
    // ω 嘴
    ctx.setLineWidth(0.12 * r)
    ctx.setLineCap(.round)
    for direction in [CGFloat(-1), 1] {
        ctx.beginPath()
        ctx.addArc(
            center: CGPoint(x: c.x + direction * 0.14 * r, y: c.y + 0.38 * r),
            radius: 0.14 * r,
            startAngle: .pi,
            endAngle: 0,
            clockwise: true
        )
        ctx.strokePath()
    }
    ctx.restoreGState()
}

// MARK: - 应用图标

/// 图标本体在 1024 画布里占 824pt（Apple 的应用图标网格）。
let iconBodyRatio: CGFloat = 824.0 / 1024.0

func appIconImage(pixelSize: Int) -> CGImage {
    let context = makeContext(width: pixelSize, height: pixelSize)
    let side = CGFloat(pixelSize)
    let body = CGRect(
        x: side * (1 - iconBodyRatio) / 2,
        y: side * (1 - iconBodyRatio) / 2,
        width: side * iconBodyRatio,
        height: side * iconBodyRatio
    )
    context.addPath(
        Path(roundedRect: body, cornerRadius: body.width * 0.225, style: .continuous).cgPath
    )
    context.setFillColor(Brand.cream)
    context.fillPath()

    // 16/32pt 放大标记、不画脸（那个像素数下眼睛只剩一两个像素）。
    let small = pixelSize <= 64
    let markHeight = body.height * (small ? 0.74 : 0.68)
    let source = LightAnchorMark.bounds
    let markWidth = markHeight * source.width / source.height
    let box = CGRect(
        x: body.midX - markWidth / 2,
        y: body.midY - markHeight / 2,
        width: markWidth,
        height: markHeight
    )
    LightAnchorMark.draw(.active, in: context, fitting: box, shape: Brand.honey, dot: Brand.blue)

    if !small {
        // 复现 draw() 的变换，把脸挖在方墩上。
        let scale = min(box.width / source.width, box.height / source.height)
        context.saveGState()
        context.translateBy(x: box.midX, y: box.midY)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -source.midX, y: -source.midY)
        drawFace(in: context, eye: Brand.ink, ground: Brand.cream)
        context.restoreGState()
    }
    return context.makeImage()!
}

// MARK: - 文字（转成路径，logo 不依赖装机字体）

struct TextRun {
    let path: CGPath
    let width: CGFloat
}

func textPath(_ string: String, fontName: String, size: CGFloat, tracking: CGFloat = 0) -> TextRun {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    var characters = Array(string.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else {
        fatalError("字体 \(fontName) 缺少「\(string)」需要的字形")
    }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)

    let combined = CGMutablePath()
    var x: CGFloat = 0
    for (index, glyph) in glyphs.enumerated() {
        if let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) {
            combined.addPath(glyphPath, transform: CGAffineTransform(translationX: x, y: 0))
        }
        x += advances[index].width + tracking
    }
    return TextRun(path: combined, width: max(0, x - tracking))
}

// MARK: - SVG

func round3(_ value: CGFloat) -> String {
    let rounded = (value * 1000).rounded() / 1000
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
}

/// CGPath → SVG path data。SVG 的 y 轴向下，所以整条路径按 `flipHeight` 翻转。
func svgPathData(_ path: CGPath, flipAround flipHeight: CGFloat) -> String {
    var out: [String] = []
    func map(_ point: CGPoint) -> String {
        "\(round3(point.x)) \(round3(flipHeight - point.y))"
    }
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: out.append("M \(map(points[0]))")
        case .addLineToPoint: out.append("L \(map(points[0]))")
        case .addQuadCurveToPoint: out.append("Q \(map(points[0])) \(map(points[1]))")
        case .addCurveToPoint: out.append("C \(map(points[0])) \(map(points[1])) \(map(points[2]))")
        case .closeSubpath: out.append("Z")
        @unknown default: break
        }
    }
    return out.joined(separator: " ")
}

/// 标记的 SVG 片段，坐标就是 24 单位设计网格（y 向下）。
/// SVG 没有连续圆角，rect 的 rx 是近似——logo 尺度下看不出差别。
func markSVGBody(shape: String, dot: String) -> String {
    let square = LightAnchorMark.squareRect
    let center = LightAnchorMark.dotCenter
    return """
      <rect x="\(round3(square.minX))" y="\(round3(square.minY))" width="\(round3(square.width))" \
    height="\(round3(square.height))" rx="\(round3(LightAnchorMark.squareCornerRadius))" fill="\(shape)"/>
      <circle cx="\(round3(center.x))" cy="\(round3(center.y))" r="\(round3(LightAnchorMark.dotOuterRadius))" fill="\(dot)"/>
    """
}

// MARK: - 输出

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brandDir = root.appendingPathComponent("Support/Brand")
try? FileManager.default.createDirectory(at: brandDir, withIntermediateDirectories: true)

// 1. 应用图标：iconset → icns
let iconsetDir = brandDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for entry in iconSizes {
    writePNG(appIconImage(pixelSize: entry.pixels), to: iconsetDir.appendingPathComponent("\(entry.name).png"))
}
writePNG(appIconImage(pixelSize: 1024), to: brandDir.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconsetDir.path,
    "-o", brandDir.appendingPathComponent("AppIcon.icns").path
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil 失败") }
try? FileManager.default.removeItem(at: iconsetDir)

// 2. 标记 SVG
let markBounds = LightAnchorMark.bounds
let markSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="\(round3(markBounds.minX)) \(round3(markBounds.minY)) \
\(round3(markBounds.width)) \(round3(markBounds.height))" width="\(round3(markBounds.width * 8))" \
height="\(round3(markBounds.height * 8))" role="img" aria-label="轻锚">
  <title>轻锚 · 蜜芽方块</title>
\(markSVGBody(shape: Brand.hex(Brand.honey), dot: Brand.hex(Brand.blue)))
</svg>

"""
try markSVG.write(to: brandDir.appendingPathComponent("lightanchor-mark.svg"), atomically: true, encoding: .utf8)

// 3. 横版 logo：标记 + 轻锚 + LIGHT ANCHOR，字形转路径
func lockupSVG(dark: Bool) -> String {
    let markHeight: CGFloat = 64
    let scale = markHeight / markBounds.height
    let markWidth = markBounds.width * scale
    let gap = markHeight * 0.42

    let zh = textPath("轻锚", fontName: "PingFangSC-Semibold", size: markHeight * 0.62)
    let en = textPath("LIGHT ANCHOR", fontName: "HelveticaNeue-Medium", size: markHeight * 0.17, tracking: markHeight * 0.038)

    let textX = markWidth + gap
    let zhBaseline: CGFloat = markHeight * 0.60
    let enBaseline: CGFloat = markHeight * 0.94
    let width = textX + max(zh.width, en.width)

    let inkColor = Brand.hex(dark ? Brand.darkInk : Brand.ink)
    let subColor = Brand.hex(dark ? Brand.darkInkSoft : Brand.inkSoft)

    let zhData = svgPathData(zh.path, flipAround: zhBaseline)
    let enData = svgPathData(en.path, flipAround: enBaseline)

    // 蜜色和蓝点在浅色深色底上都成立，标记不换色。
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(round3(width)) \(round3(markHeight))" \
    width="\(round3(width))" height="\(round3(markHeight))" role="img" aria-label="轻锚 Light Anchor">
      <title>轻锚 Light Anchor</title>
      <g transform="scale(\(round3(scale))) translate(\(round3(-markBounds.minX)) \(round3(-markBounds.minY)))">
    \(markSVGBody(shape: Brand.hex(Brand.honey), dot: Brand.hex(Brand.blue)))
      </g>
      <g transform="translate(\(round3(textX)) 0)">
        <path d="\(zhData)" fill="\(inkColor)"/>
        <path d="\(enData)" fill="\(subColor)"/>
      </g>
    </svg>

    """
}
try lockupSVG(dark: false).write(
    to: brandDir.appendingPathComponent("lightanchor-lockup-light.svg"),
    atomically: true,
    encoding: .utf8
)
try lockupSVG(dark: true).write(
    to: brandDir.appendingPathComponent("lightanchor-lockup-dark.svg"),
    atomically: true,
    encoding: .utf8
)

// 4. 审阅总览图
func drawText(
    _ string: String,
    in context: CGContext,
    at point: CGPoint,
    fontName: String = "PingFangSC-Regular",
    size: CGFloat,
    color: CGColor
) {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributed = NSAttributedString(
        string: string,
        attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black]
    )
    context.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
}

func drawMenuBarStrip(in context: CGContext, origin: CGPoint, scale: CGFloat, dark: Bool) -> CGFloat {
    let barHeight = 24 * scale
    let step = 30 * scale
    let width = step * 4 + 16 * scale
    let rect = CGRect(x: origin.x, y: origin.y, width: width, height: barHeight)
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 5 * scale, cornerHeight: 5 * scale, transform: nil))
    context.setFillColor(dark ? Brand.rgb(0x2C, 0x2A, 0x33) : Brand.rgb(0xE9, 0xE5, 0xDE))
    context.fillPath()
    let foreground = dark ? Brand.rgb(0xFF, 0xFF, 0xFF, 0.92) : Brand.rgb(0x1D, 0x1B, 0x22, 0.88)
    var x = origin.x + 10 * scale
    for state in LightAnchorMarkState.allCases {
        let live = 14 * scale
        let w = live * markBounds.width / markBounds.height
        LightAnchorMark.draw(
            state,
            in: context,
            fitting: CGRect(x: x, y: rect.midY - live / 2, width: w, height: live),
            color: foreground
        )
        x += step
    }
    context.restoreGState()
    return width
}

let sheetWidth = 1080
let sheetHeight = 640
let sheet = makeContext(width: sheetWidth, height: sheetHeight)
sheet.setFillColor(Brand.warmBackground)
sheet.fill(CGRect(x: 0, y: 0, width: CGFloat(sheetWidth), height: CGFloat(sheetHeight)))

drawText("轻锚 · 品牌资源（蜜芽方块）", in: sheet, at: CGPoint(x: 48, y: CGFloat(sheetHeight) - 56), fontName: "PingFangSC-Semibold", size: 26, color: Brand.ink)
drawText(
    "蜜色软方墩 + 右上角蓝点。纯平三色，脸只上 ≥48pt；菜单栏是单色剪影 + 四态（实心/双环/点环/空心环）。",
    in: sheet,
    at: CGPoint(x: 48, y: CGFloat(sheetHeight) - 84),
    size: 13,
    color: Brand.inkSoft
)

var iconX: CGFloat = 48
for size in [CGFloat(160), 96, 64, 32, 16] {
    sheet.draw(
        appIconImage(pixelSize: Int(size * 2)),
        in: CGRect(x: iconX, y: CGFloat(sheetHeight) - 130 - size, width: size, height: size)
    )
    drawText("\(Int(size))pt", in: sheet, at: CGPoint(x: iconX, y: CGFloat(sheetHeight) - 148 - size), size: 11, color: Brand.inkSoft)
    iconX += size + 26
}

drawText("菜单栏（进行中 / 准备返回 / 等待 / 空闲）", in: sheet, at: CGPoint(x: 48, y: 260), fontName: "PingFangSC-Semibold", size: 15, color: Brand.ink)
let wide = drawMenuBarStrip(in: sheet, origin: CGPoint(x: 48, y: 196), scale: 2, dark: false)
_ = drawMenuBarStrip(in: sheet, origin: CGPoint(x: 48 + wide + 20, y: 208), scale: 1, dark: false)
_ = drawMenuBarStrip(in: sheet, origin: CGPoint(x: 48 + wide + 20, y: 180), scale: 1, dark: true)

// 横版 logo 复核
func drawLockup(in context: CGContext, origin: CGPoint, markHeight: CGFloat, dark: Bool) {
    let scale = markHeight / markBounds.height
    let markWidth = markBounds.width * scale
    LightAnchorMark.draw(
        .active,
        in: context,
        fitting: CGRect(x: origin.x, y: origin.y, width: markWidth, height: markHeight),
        shape: Brand.honey,
        dot: Brand.blue
    )
    let textX = origin.x + markWidth + markHeight * 0.42
    drawText(
        "轻锚",
        in: context,
        at: CGPoint(x: textX, y: origin.y + markHeight * 0.40),
        fontName: "PingFangSC-Semibold",
        size: markHeight * 0.62,
        color: dark ? Brand.darkInk : Brand.ink
    )
    drawText(
        "LIGHT ANCHOR",
        in: context,
        at: CGPoint(x: textX + 1, y: origin.y + markHeight * 0.06),
        fontName: "HelveticaNeue-Medium",
        size: markHeight * 0.17,
        color: dark ? Brand.darkInkSoft : Brand.inkSoft
    )
}
drawLockup(in: sheet, origin: CGPoint(x: 48, y: 72), markHeight: 56, dark: false)
sheet.setFillColor(Brand.darkBackground)
sheet.fill(CGRect(x: 520, y: 48, width: 512, height: 108))
drawLockup(in: sheet, origin: CGPoint(x: 560, y: 72), markHeight: 56, dark: true)

writePNG(sheet.makeImage()!, to: brandDir.appendingPathComponent("brand-preview.png"))

print("品牌资源已生成：\(brandDir.path)")
