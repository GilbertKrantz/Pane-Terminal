import AppKit
import SwiftUI
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

    func testCompletedSnapshotUsesPlainBlockOutputPresentation() {
        let session = TerminalSession()
        defer { session.shutdown() }
        let snapshot = TerminalReplaySnapshot(
            bytes: Data("\u{001B}[31mcolored\u{001B}[0m".utf8),
            columns: 80,
            rows: 24,
            isTruncated: false
        )
        let block = CommandBlock(
            command: "printf colored",
            workingDirectory: "/tmp",
            state: .completed(exitCode: 0),
            output: "colored",
            terminalSnapshot: snapshot
        )
        let hostingView = NSHostingView(
            rootView: CommandBlockView(
                block: block,
                isSelected: false,
                session: session
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 180)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(firstSubview(of: FrozenBlockTerminalView.self, in: hostingView))
        XCTAssertEqual(
            firstSubview(of: CommandClickableNSTextView.self, in: hostingView)?.string,
            "colored"
        )
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
