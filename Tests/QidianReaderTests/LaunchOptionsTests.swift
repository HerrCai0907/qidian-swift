import XCTest
@testable import QidianReader

final class LaunchOptionsTests: XCTestCase {
    func testDefaultKeepsForegroundActivation() {
        XCTAssertFalse(LaunchOptions(arguments: ["QidianReader"]).suppressesForeground)
        XCTAssertFalse(LaunchOptions(arguments: ["QidianReader", "--help"]).suppressesForeground)
    }

    func testNoActivateFlagSuppressesForeground() {
        XCTAssertTrue(LaunchOptions(arguments: ["QidianReader", "--no-activate"]).suppressesForeground)
        XCTAssertTrue(LaunchOptions(arguments: ["QidianReader", "--no-activate=1"]).suppressesForeground)
        XCTAssertTrue(LaunchOptions(arguments: ["QidianReader", "--no-activate=TRUE"]).suppressesForeground)
        XCTAssertTrue(LaunchOptions(arguments: ["QidianReader", "--no-activate=yes"]).suppressesForeground)
    }

    func testExplicitFalseKeepsForegroundActivation() {
        XCTAssertFalse(LaunchOptions(arguments: ["QidianReader", "--no-activate=0"]).suppressesForeground)
        XCTAssertFalse(LaunchOptions(arguments: ["QidianReader", "--no-activate=false"]).suppressesForeground)
        XCTAssertFalse(LaunchOptions(arguments: ["QidianReader", "--no-activate=unknown"]).suppressesForeground)
    }

    func testOnlyProcessArgumentsAreParsed() {
        // 可执行文件路径里即使出现同名文本也不算数。
        XCTAssertFalse(LaunchOptions(arguments: ["/tmp/--no-activate/QidianReader"]).suppressesForeground)
    }
}
