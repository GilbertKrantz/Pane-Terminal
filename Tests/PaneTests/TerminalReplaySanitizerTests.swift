import AppKit
import Foundation
@preconcurrency import SwiftTerm
import Testing
@testable import Pane

struct TerminalReplaySanitizerTests {
    @Test func preservesVisualSequencesAndText() {
        let raw = Data("\u{001B}[31mred\u{001B}[0m\rprogress".utf8)

        #expect(TerminalReplaySanitizer.sanitize(raw) == raw)
        #expect(TerminalSession.requiresRichTerminalRendering(raw))
    }

    @Test func removesSideEffectSequences() {
        let raw = Data((
            "before\u{001B}]52;c;AAAA\u{0007}\u{001B}]0;title\u{0007}" +
            "\u{0007}\u{001B}[6n\u{001B}[>0c\u{001B}[8;40;120t" +
            "\u{001B}Ppayload\u{001B}\\after"
        ).utf8)
        let sanitized = String(decoding: TerminalReplaySanitizer.sanitize(raw), as: UTF8.self)

        #expect(sanitized == "beforeafter")
    }

    @Test func preservesOSC8HyperlinksButRemovesOtherEightBitControlStrings() {
        let hyperlink = Data("\u{001B}]8;;https://example.com\u{001B}\\link\u{001B}]8;;\u{001B}\\".utf8)
        let raw = Data([0x9D]) + Data("52;c;AAAA".utf8) + Data([0x9C])
            + hyperlink
            + Data([0x90]) + Data("payload".utf8) + Data([0x9C])
            + Data([0x9B]) + Data("6n".utf8)

        #expect(TerminalReplaySanitizer.sanitize(raw) == hyperlink)
    }

    @Test func plainLineOutputDoesNotRequireRichRendering() {
        #expect(!TerminalSession.requiresRichTerminalRendering(Data("hello\nworld\n".utf8)))
    }

    @Test func carriageReturnRewriteRequiresRichRendering() {
        #expect(TerminalSession.requiresRichTerminalRendering(Data("10%\r20%".utf8)))
    }

    @Test func boundedCaptureRetainsNewestBytesAndKeepsTruncationSticky() {
        var capture = BoundedByteTail(limit: 8)
        capture.append(Data("123456".utf8))
        capture.append(Data("7890".utf8))

        #expect(String(decoding: capture.data, as: UTF8.self) == "34567890")
        #expect(capture.isTruncated)

        capture.append(Data("abcdefgh".utf8))
        #expect(String(decoding: capture.data, as: UTF8.self) == "abcdefgh")
        #expect(capture.isTruncated)

        capture.removeAll()
        capture.append(Data("abcdefgh".utf8))
        #expect(!capture.isTruncated)
    }

    @MainActor
    @Test func frozenReplayUsesCapturedGeometryAndPreservesCellStyles() {
        let bytes = Data("\u{001B}[1;4;31;44mX\u{001B}[0m".utf8)
        let snapshot = TerminalReplaySnapshot(
            bytes: bytes,
            columns: 42,
            rows: 7,
            isTruncated: false
        )
        let view = FrozenBlockTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 200),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        view.replay(snapshot)
        view.layoutSubtreeIfNeeded()

        #expect(view.terminal.cols == 42)
        #expect(view.terminal.rows == 7)
        #expect(view.terminalDelegate == nil)
        #expect(view.nativeBackgroundColor.alphaComponent == 0)
        let scrollbarsAreHidden = view.subviews
            .compactMap { $0 as? NSScroller }
            .allSatisfy { $0.isHidden }
        #expect(scrollbarsAreHidden)
        let containsCaretView = view.subviews.contains {
            String(describing: type(of: $0)).contains("CaretView")
        }
        #expect(!containsCaretView)
        let firstCell = view.terminal.getScrollInvariantLine(row: 0)?[0]
        #expect(firstCell?.attribute.style.contains(.bold) == true)
        #expect(firstCell?.attribute.style.contains(.underline) == true)
        #expect(firstCell?.attribute.fg == .ansi256(code: 1))
        #expect(firstCell?.attribute.bg == .ansi256(code: 4))
    }
}
