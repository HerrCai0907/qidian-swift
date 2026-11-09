import AppKit
import XCTest
@testable import QidianReader

final class AppIconTests: XCTestCase {
    func testAppIconIsBundled() {
        let image = AppIcon.image
        XCTAssertNotNil(image, "AppIcon.icns 应该随 QidianReader 资源一起打包")
        // NSImage 的 size 是点，1024px 是 512pt 的 @2x 表示。
        XCTAssertEqual(image?.size, NSSize(width: 512, height: 512))
        XCTAssertFalse(image?.representations.isEmpty ?? true)
    }

    func testAppIconContainsHighResolutionReps() {
        let sizes = AppIcon.image?.representations.compactMap { rep -> CGFloat? in
            let width = CGFloat(rep.pixelsWide)
            return width > 0 ? width : nil
        }
        XCTAssertEqual(sizes?.max(), 1024, "Dock/Retina 至少需要 1024px 的图标")
    }
}
