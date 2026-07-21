import XCTest
@testable import Pane

final class CommandSerializerTests: XCTestCase {
    func testAppendsExactlyOneCarriageReturn() {
        XCTAssertEqual(
            CommandSerializer.serialize("printf hello"),
            Array("printf hello\r".utf8)
        )
    }

    func testEmptyCommandSerializesAsBlankShellLine() {
        XCTAssertEqual(CommandSerializer.serialize(""), [0x0D])
    }

    func testPreservesMultilineCommand() {
        let command = "for item in one two\ndo\n  echo $item\ndone"

        XCTAssertEqual(
            CommandSerializer.serializeCommand(command),
            Array(("\u{001B}[200~" + command + "\u{001B}[201~\r").utf8)
        )
    }

    func testDoesNotNormalizeExistingLineEndings() {
        let command = "echo one\r\necho two"
        XCTAssertEqual(
            CommandSerializer.serializeCommand(command),
            Array(("\u{001B}[200~" + command + "\u{001B}[201~\r").utf8)
        )
    }

    func testActiveInputDoesNotInjectBracketedPasteMarkers() {
        XCTAssertEqual(
            CommandSerializer.serializeInputLine("first\nsecond"),
            Array("first\nsecond\r".utf8)
        )
    }
}
