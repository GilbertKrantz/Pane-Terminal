import AppKit
import SwiftUI
import XCTest
@testable import Pane

@MainActor
final class CommandClickableTextViewTests: XCTestCase {
    func testCachedMeasurementInvalidatesAfterTextAndFontChanges() {
        let view = CommandClickableTextView.makeTextView()
        let initialFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        CommandClickableTextView(text: "short", font: initialFont, textColor: .labelColor).updateTextView(view)
        let initial = view.height(fitting: 120)
        CommandClickableTextView(text: String(repeating: "wrapped text ", count: 40),
                                 font: initialFont, textColor: .labelColor).updateTextView(view)
        let wrapped = view.height(fitting: 120)
        XCTAssertGreaterThan(wrapped, initial)
        view.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        XCTAssertGreaterThan(view.height(fitting: 120), wrapped)
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: view.string.utf16.count), with: "x")
        XCTAssertLessThan(view.height(fitting: 120), wrapped)
    }

    func testLargeOutputLinksRemainCorrectAfterReplacementAndAppearanceChange() async throws {
        let view = CommandClickableTextView.makeTextView()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let old = String(repeating: "old ", count: 3000) + "https://example.com/old"
        let replacement = String(repeating: "new ", count: 3000) + "https://example.com/new"
        CommandClickableTextView(text: old, font: font, textColor: .labelColor).updateTextView(view)
        CommandClickableTextView(text: replacement, font: font, textColor: .labelColor).updateTextView(view)
        CommandClickableTextView(text: replacement, font: font, textColor: .secondaryLabelColor).updateTextView(view)
        let offset = replacement.utf16.count - "https://example.com/new".utf16.count
        for _ in 0..<100 {
            if view.textStorage?.attribute(.link, at: offset, effectiveRange: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.string, replacement)
        XCTAssertEqual(view.textStorage?.attribute(.link, at: offset, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/new"))
    }

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

        let originalFrame = textView.frame
        let originalContainerSize = textView.textContainer?.containerSize
        let narrowHeight = textView.height(fitting: 120)
        let wideHeight = textView.height(fitting: 720)

        XCTAssertEqual(textView.frame, originalFrame, "Measurement must not resize the displayed text view")
        XCTAssertEqual(textView.textContainer?.containerSize, originalContainerSize)
        XCTAssertEqual(textView.height(fitting: 120), narrowHeight)
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
