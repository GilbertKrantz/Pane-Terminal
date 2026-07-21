import XCTest
@testable import Pane

final class InputModeTests: XCTestCase {
    func testToggleMovesBetweenBlocksAndTerminalModes() {
        var mode = InputMode.blocks

        mode.toggle()
        XCTAssertEqual(mode, .terminal)

        mode.toggle()
        XCTAssertEqual(mode, .blocks)
    }

    func testModeTitlesAreUserFacing() {
        XCTAssertEqual(InputMode.blocks.title, "Blocks Mode")
        XCTAssertEqual(InputMode.terminal.title, "Terminal Mode")
        XCTAssertEqual(InputMode.blocks.shortTitle, "Blocks")
        XCTAssertEqual(InputMode.terminal.shortTitle, "Terminal")
    }
}
