import AppKit
import XCTest
@testable import LightAnchor

/// 内嵌的官方品牌 SVG 必须始终能被 NSImage 矢量渲染——
/// 字符串被误改（转义、缩进、截断）时在这里立刻暴露。
final class BrandMarkAssetsTests: XCTestCase {
    func testEmbeddedBrandSVGsDecode() {
        for (name, svg) in [
            ("pi favicon", BrandMarkAssets.piFaviconSVG),
            ("deepseek whale", BrandMarkAssets.deepseekWhaleSVG),
        ] {
            XCTAssertTrue(svg.hasPrefix("<"), "\(name) 应以标签开头（XML 声明前不得有空白）")
            let image = NSImage(data: Data(svg.utf8))
            XCTAssertNotNil(image, "\(name) 无法解码")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, name)
        }
    }
}
