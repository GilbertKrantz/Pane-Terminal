import AppKit
import XCTest
@testable import Pane

@MainActor
final class CommandClickableTextViewTests: XCTestCase {
    func testHeightUsesTheProposedWidthInsteadOfTheInitialZeroWidth() {
        let textView = CommandClickableNSTextView()
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: String(repeating: "https://example.com/path ", count: 8))
        )

        XCTAssertEqual(textView.intrinsicContentSize.height, 0)

        let narrowHeight = textView.height(fitting: 120)
        let wideHeight = textView.height(fitting: 720)

        XCTAssertGreaterThan(narrowHeight, wideHeight)
        XCTAssertGreaterThan(wideHeight, 0)
        XCTAssertLessThan(wideHeight, 40)
    }
}
