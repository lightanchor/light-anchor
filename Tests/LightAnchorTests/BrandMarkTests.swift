import AppKit
import Foundation
import XCTest
@testable import LightAnchor

/// 品牌标记「蜜芽方块」的守卫。
///
/// 几何断言保护的是可读性，不是好看：蓝点必须和方墩留出气口、四种状态必须
/// 真的画出不同的像素——否则菜单栏图标会退化成一个说明不了任何状态的色块。
final class BrandMarkTests: XCTestCase {

    // MARK: - 几何

    func testDotClearsTheSquare() {
        let mark = LightAnchorMark.self
        // 蓝点中心到方墩右上圆角圆心的距离要大于两个半径之和：
        // 点和方墩之间必须有一条缝，贴上就读成一块异形。
        let corner = CGPoint(
            x: mark.squareRect.maxX - mark.squareCornerRadius,
            y: mark.squareRect.minY + mark.squareCornerRadius
        )
        let distance = hypot(mark.dotCenter.x - corner.x, mark.dotCenter.y - corner.y)
        XCTAssertGreaterThan(distance, mark.squareCornerRadius + mark.dotOuterRadius + 0.5)
        // 但又不能飞出去：点的左缘要压进方墩的横向范围，两者才是一个标记。
        XCTAssertLessThan(mark.dotCenter.x - mark.dotOuterRadius, mark.squareRect.maxX)
    }

    func testBoundsCoverSquareAndDot() {
        let mark = LightAnchorMark.self
        let bounds = mark.bounds
        XCTAssertTrue(bounds.contains(mark.squareRect))
        XCTAssertEqual(bounds.minY, mark.dotCenter.y - mark.dotOuterRadius, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxX, mark.dotCenter.x + mark.dotOuterRadius, accuracy: 0.0001)
        // 双环的内点要真的比环小一圈，否则 returning 和 active 分不开。
        XCTAssertLessThan(mark.innerDotRadius, mark.dotOuterRadius - mark.ringStroke * 1.5)
    }

    // MARK: - 菜单栏


    @MainActor
    func testStatusItemImageIsATemplateSizedForTheMenuBar() {
        for state in LightAnchorMarkState.allCases {
            let image = LightAnchorMark.cachedStatusItemImage(state)
            // template 图像才会跟着菜单栏前景色、深色外观和高亮反色。
            XCTAssertTrue(image.isTemplate, "\(state) 不是 template 图像")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertFalse(image.accessibilityDescription?.isEmpty ?? true)
            let ink = try? inkCoverage(of: image)
            XCTAssertGreaterThan(try XCTUnwrap(ink), 0.02, "\(state) 几乎没画出东西")
            XCTAssertLessThan(try XCTUnwrap(ink), 0.5, "\(state) 糊成了一块")
        }
    }

    @MainActor
    func testStatusItemImageIsCachedPerState() {
        let first = LightAnchorMark.cachedStatusItemImage(.waiting)
        let second = LightAnchorMark.cachedStatusItemImage(.waiting)
        XCTAssertIdentical(first, second, "菜单栏标签每轮更新都会取图，不能每次重画")
    }

    @MainActor
    func testEveryStateRendersDistinctPixels() throws {
        var seen: [LightAnchorMarkState: Data] = [:]
        for state in LightAnchorMarkState.allCases {
            seen[state] = try pixels(of: LightAnchorMark.cachedStatusItemImage(state))
        }
        for left in LightAnchorMarkState.allCases {
            for right in LightAnchorMarkState.allCases where left != right {
                XCTAssertNotEqual(
                    seen[left],
                    seen[right],
                    "\(left) 和 \(right) 在菜单栏尺寸下画出来是一样的"
                )
            }
        }
    }

    func testEveryEpisodeStateMapsToAMarkState() {
        XCTAssertEqual(LightAnchorMarkState(episodeState: .active), .active)
        XCTAssertEqual(LightAnchorMarkState(episodeState: .returning), .returning)
        XCTAssertEqual(LightAnchorMarkState(episodeState: .waiting), .waiting)
        XCTAssertEqual(LightAnchorMarkState(episodeState: .paused), .idle)
        XCTAssertEqual(LightAnchorMarkState(episodeState: .ended), .idle)
        XCTAssertEqual(LightAnchorMarkState(episodeState: nil), .idle)
    }

    // MARK: - 接线

    func testMenuBarLabelUsesTheBrandMark() throws {
        let source = try source(at: "Sources/LightAnchor/App/LightAnchorApp.swift")
        XCTAssertTrue(source.contains("MenuBarStatusLabel(state: menuBarMarkState)"))
        XCTAssertTrue(source.contains("LightAnchorMark.cachedStatusItemImage(state)"))
        // 换回 SF Symbols 的圆点就丢了品牌识别，四个符号的视觉直径也对不齐。
        XCTAssertFalse(source.contains("Image(systemName:"))
    }

    func testAppIconIsBuiltIntoTheReleaseBundle() throws {
        let iconURL = repositoryRoot.appendingPathComponent("Support/Brand/AppIcon.icns")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: iconURL.path),
            "缺少 Support/Brand/AppIcon.icns，运行 Scripts/make-brand-assets.sh"
        )

        let plistData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Support/LightAnchor-Info.plist")
        )
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")

        let script = try source(at: "Scripts/build-release.sh")
        XCTAssertTrue(script.contains("Contents/Resources/AppIcon.icns"))
    }

    func testBrandVectorAssetsAreCommitted() throws {
        for name in [
            "lightanchor-mark.svg",
            "lightanchor-lockup-light.svg",
            "lightanchor-lockup-dark.svg"
        ] {
            let url = repositoryRoot.appendingPathComponent("Support/Brand/\(name)")
            let svg = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(svg.hasPrefix("<svg"), "\(name) 不是 SVG")
            // 字形已转路径：logo 不能依赖装机字体。
            XCTAssertFalse(svg.contains("<text"), "\(name) 里还有活文字")
        }
    }

    // MARK: - 工具

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 按菜单栏 @2x 的实际尺寸栅格化，取 alpha 通道。
    private func pixels(of image: NSImage) throws -> Data {
        let side = 36
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        var rect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let data = try XCTUnwrap(context.data)
        return Data(bytes: data, count: side * side * 4)
    }

    private func inkCoverage(of image: NSImage) throws -> Double {
        let raw = try pixels(of: image)
        var covered = 0
        for index in stride(from: 3, to: raw.count, by: 4) where raw[index] > 32 {
            covered += 1
        }
        return Double(covered) / Double(raw.count / 4)
    }
}
