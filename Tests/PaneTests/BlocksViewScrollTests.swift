import AppKit
import SwiftUI
import XCTest
@testable import Pane

@MainActor
final class BlocksViewScrollTests: XCTestCase {
    func testCompletedCommandPinsTimelineToItsTrueBottom() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = TerminalSession(
            shellConfiguration: .loginZsh(
                processEnvironment: [
                    "HOME": "/tmp",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
                ],
                homeDirectory: URL(fileURLWithPath: "/tmp")
            )
        )
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        try await waitUntil("shell startup") {
            hostingView.layoutSubtreeIfNeeded()
            return session.isShellReadyForInput
        }

        let command = "for pane_line in {1..30}; do printf 'timeline-line-%02d\\n' $pane_line; done"
        session.submit(command: command)

        try await waitUntil("completed output block", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return session.blocks.contains { block in
                guard block.command == command, block.output.contains("timeline-line-30") else {
                    return false
                }
                if case .completed = block.state { return true }
                return false
            }
        }

        await drainMainQueue(turns: 3)
        hostingView.layoutSubtreeIfNeeded()

        let timeline = try XCTUnwrap(
            scrollViews(in: hostingView)
                .filter { scrollView in
                    guard let documentView = scrollView.documentView else { return false }
                    return documentView.bounds.height > scrollView.contentView.bounds.height + 20
                }
                .max { lhs, rhs in
                    (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
                }
        )
        let documentView = try XCTUnwrap(timeline.documentView)
        let visibleRect = timeline.documentVisibleRect

        if documentView.isFlipped {
            XCTAssertEqual(visibleRect.maxY, documentView.bounds.maxY, accuracy: 2)
        } else {
            XCTAssertEqual(visibleRect.minY, documentView.bounds.minY, accuracy: 2)
        }

        let terminalView = session.makeAuthoritativeTerminalView()
        terminalView.feed(text: "\u{001B}[?1049h")
        try await waitUntil("alternate screen to replace the blocks timeline") {
            hostingView.layoutSubtreeIfNeeded()
            return session.isAlternateScreenActive
        }

        terminalView.feed(text: "\u{001B}[?1049l")
        try await waitUntil("blocks timeline to return after alternate screen") {
            hostingView.layoutSubtreeIfNeeded()
            return !session.isAlternateScreenActive
                && self.timelineScrollView(in: hostingView) != nil
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await drainMainQueue(turns: 3)
        hostingView.layoutSubtreeIfNeeded()

        let restoredTimeline = try XCTUnwrap(timelineScrollView(in: hostingView))
        let restoredDocumentView = try XCTUnwrap(restoredTimeline.documentView)
        let restoredVisibleRect = restoredTimeline.documentVisibleRect
        if restoredDocumentView.isFlipped {
            XCTAssertEqual(restoredVisibleRect.maxY, restoredDocumentView.bounds.maxY, accuracy: 2)
        } else {
            XCTAssertEqual(restoredVisibleRect.minY, restoredDocumentView.bounds.minY, accuracy: 2)
        }
        let restoredOutput = try XCTUnwrap(
            commandOutputView(containing: "timeline-line-30", in: hostingView)
        )
        let outputRectInClipView = restoredOutput.convert(
            restoredOutput.bounds,
            to: restoredTimeline.contentView
        )
        XCTAssertTrue(
            outputRectInClipView.intersects(restoredTimeline.contentView.bounds),
            "The completed block must be visible immediately after alternate-screen exit"
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
        throw CocoaError(.coderReadCorrupt)
    }

    private func drainMainQueue(turns: Int) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for subview in view.subviews {
            result.append(contentsOf: scrollViews(in: subview))
        }
        return result
    }

    private func timelineScrollView(in view: NSView) -> NSScrollView? {
        scrollViews(in: view)
            .filter { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.bounds.height > scrollView.contentView.bounds.height + 20
            }
            .max { lhs, rhs in
                (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
            }
    }

    private func commandOutputView(
        containing marker: String,
        in view: NSView
    ) -> CommandClickableNSTextView? {
        if let outputView = view as? CommandClickableNSTextView,
           outputView.string.contains(marker) {
            return outputView
        }
        for subview in view.subviews {
            if let outputView = commandOutputView(containing: marker, in: subview) {
                return outputView
            }
        }
        return nil
    }
}
