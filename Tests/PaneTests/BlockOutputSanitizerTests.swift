import Foundation
import XCTest
@testable import Pane

final class BlockOutputSanitizerTests: XCTestCase {
    func testRemovesANSIAndNormalizesCarriageReturns() {
        let data = Data("\u{001B}[31mred\u{001B}[0m\r\nplain\rupdated".utf8)

        XCTAssertEqual(BlockOutputSanitizer.sanitize(data), "red\nupdated")
    }

    func testRemovesOperatingSystemCommands() {
        let data = Data("before\u{001B}]0;window title\u{0007}after".utf8)

        XCTAssertEqual(BlockOutputSanitizer.sanitize(data), "beforeafter")
    }

    func testCarriageReturnProgressKeepsOnlyTheLastFrame() {
        let data = Data(
            "Progress 01%\rProgress 42%\rProgress 99%\r\nDone".utf8
        )

        XCTAssertEqual(
            BlockOutputSanitizer.sanitize(data),
            "Progress 99%\nDone"
        )
    }

    func testEraseLineRemovesLongerPreviousProgressFrame() {
        let data = Data(
            "Downloading 98.3 MB\r\u{001B}[2KDone\r\n".utf8
        )

        XCTAssertEqual(BlockOutputSanitizer.sanitize(data), "Done")
    }
}
