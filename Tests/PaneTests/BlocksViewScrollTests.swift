import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Pane

@MainActor
final class BlocksViewScrollTests: XCTestCase {
    func testRecycledHistoryBoundsMountedViewsAndReachesOffscreenSelection() async throws {
        let session = makeTestSession()
        defer { session.shutdown() }
        let blocks = (0..<1000).map { index in
            CommandBlock(command: "echo \(index)", workingDirectory: "/tmp",
                         state: .completed(exitCode: 0), output: "recycled-marker-\(index)")
        }
        session.blockLifecycleController.restore(blocks)
        let host = NSHostingView(rootView: BlocksView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 620)
        host.layoutSubtreeIfNeeded()
        let timeline = try XCTUnwrap(scrollViews(in: host).compactMap { $0 as? BlocksTimelineScrollView }.first)
        XCTAssertNotNil(commandOutputView(containing: "recycled-marker-999", in: host))
        XCTAssertLessThan(scrollViews(in: timeline.documentView!).count, 50)
        timeline.contentView.scroll(to: .zero)
        timeline.reflectScrolledClipView(timeline.contentView)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(commandOutputView(containing: "recycled-marker-0", in: host))
        session.selectBlock(blocks[500].id)
        await drainMainQueue(turns: 4)
        host.layoutSubtreeIfNeeded()
        let selected = try XCTUnwrap(commandOutputView(containing: "recycled-marker-500", in: host))
        XCTAssertTrue(selected.convert(selected.bounds, to: timeline.contentView).intersects(timeline.contentView.bounds))
        XCTAssertLessThan(scrollViews(in: timeline.documentView!).count, 50)
        let selectedText = try XCTUnwrap(selected as? NSTextView)
        selectedText.setSelectedRange(NSRange(location: 0, length: 8))
        host.frame.size.width = 760
        host.layoutSubtreeIfNeeded()
        let resized = try XCTUnwrap(commandOutputView(containing: "recycled-marker-500", in: host))
        XCTAssertTrue(resized === selected, "Resizing must retain the native text view")
        XCTAssertEqual((resized as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 8))
    }

    func testDraftEditingDoesNotPublishFinalizedTimelinePresentation() async {
        let session = makeTestSession()
        defer { session.shutdown() }
        session.blockLifecycleController.restore([
            CommandBlock(command: "echo done", workingDirectory: "/tmp",
                         state: .completed(exitCode: 0), output: "done")
        ])
        let presentation = session.blocksPresentation
        var publications = 0
        let observer = presentation.$snapshot.dropFirst().sink { _ in publications += 1 }
        session.commandDraft = "g"
        await drainMainQueue(turns: 4)
        session.commandDraft = "git status"
        await drainMainQueue(turns: 4)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observer) {}
    }

    func testHugeOutputUsesCappedInlineScroller() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = makeWindow(hostingView: hostingView)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        try await waitUntil("shell startup") {
            hostingView.layoutSubtreeIfNeeded()
            return session.isShellReadyForInput
        }

        let command = "for pane_line in {1..10000}; do printf 'huge-line-%05d\\n' $pane_line; done"
        session.submit(command: command)

        try await waitUntil("completed huge output block", timeout: 12) {
            hostingView.layoutSubtreeIfNeeded()
            return session.blocks.contains { block in
                guard block.command == command,
                      block.output.contains("huge-line-10000") else {
                    return false
                }
                if case .completed = block.state { return true }
                return false
            }
        }

        await drainMainQueue(turns: 4)
        hostingView.layoutSubtreeIfNeeded()

        let outputView = try XCTUnwrap(
            commandOutputView(containing: "huge-line-10000", in: hostingView)
        )
        let outputScroller = try XCTUnwrap(
            outputScrollView(containing: outputView, in: hostingView)
        )
        let outputDocument = try XCTUnwrap(outputScroller.documentView)

        XCTAssertLessThanOrEqual(
            outputScroller.bounds.height,
            PaneMetrics.blockOutputMaxHeight + 1
        )
        XCTAssertGreaterThan(
            outputDocument.bounds.height,
            outputScroller.contentView.bounds.height
        )
        XCTAssertTrue(session.visibleBlocks.contains { $0.command == command })
    }

    func testBulkTimelineMountsNewestBlockWithLargeOutputCards() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let largeOutput = String(repeating: "bulk-large-output\\n", count: 500)

        for index in 0..<500 {
            let output = index.isMultiple(of: 100)
                ? largeOutput + "bulk-marker-\(index)"
                : "bulk-marker-\(index)"
            addCompletedBlock(
                command: "printf bulk-\(index)",
                output: output,
                to: session
            )
        }

        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = makeWindow(hostingView: hostingView)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        try await waitUntil("bulk timeline to mount", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return self.timelineScrollView(in: hostingView) != nil
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await drainMainQueue(turns: 4)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(session.blocks.count, 500)
        XCTAssertEqual(session.visibleBlocks.count, 500)

        let timeline = try XCTUnwrap(timelineScrollView(in: hostingView))
        let documentView = try XCTUnwrap(timeline.documentView)
        XCTAssertGreaterThan(documentView.bounds.height, timeline.contentView.bounds.height)

        let newestOutput = try XCTUnwrap(
            commandOutputView(containing: "bulk-marker-499", in: hostingView)
        )
        let newestScroller = try XCTUnwrap(outputScrollView(containing: newestOutput, in: hostingView))
        XCTAssertLessThanOrEqual(newestScroller.bounds.height, 24,
                                 "Single-line output must not reserve a full-height blank viewport")
        let outputRectInTimeline = newestOutput.convert(
            newestOutput.bounds,
            to: timeline.contentView
        )
        XCTAssertTrue(
            outputRectInTimeline.intersects(timeline.contentView.bounds),
            "The newest block must be visible after a bulk timeline mount: output=\(outputRectInTimeline), viewport=\(timeline.contentView.bounds), document=\(documentView.bounds)"
        )
    }

    func testTimelineRemainsVisibleAfterRemountAndResize() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        for index in 0..<150 {
            addCompletedBlock(
                command: "printf remount-\(index)",
                output: String(repeating: "wrapped output ", count: index.isMultiple(of: 3) ? 400 : 3)
                    + "remount-marker-\(index)",
                to: session
            )
        }
        let otherSession = makeTestSession()
        let hostingView = NSHostingView(rootView: ContentView(session: session).id("primary"))
        let window = makeWindow(hostingView: hostingView)
        defer {
            window.orderOut(nil)
            session.shutdown()
            otherSession.shutdown()
        }
        try await waitUntil("shell startup") { session.isShellReadyForInput }

        for iteration in 0..<6 {
            // Replacing the root identity mirrors selecting another tab and returning.
            hostingView.rootView = ContentView(session: otherSession).id("other")
            hostingView.layoutSubtreeIfNeeded()
            await drainMainQueue(turns: 2)
            window.setContentSize(NSSize(width: iteration.isMultiple(of: 2) ? 460 : 1200,
                                         height: iteration.isMultiple(of: 2) ? 800 : 320))
            hostingView.rootView = ContentView(session: session).id("primary")
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            await drainMainQueue(turns: 4)
            hostingView.layoutSubtreeIfNeeded()
            let earlyTimeline = try XCTUnwrap(timelineScrollView(in: hostingView))
            let settledOrigin = earlyTimeline.contentView.bounds.origin
            // Tab restoration must not schedule a second jump 50 ms later.
            try await Task.sleep(nanoseconds: 130_000_000)
            await drainMainQueue(turns: 4)
            XCTAssertEqual(earlyTimeline.contentView.bounds.minY, settledOrigin.y, accuracy: 1,
                           "Tab restoration moved again after its initial layout")
            hostingView.layoutSubtreeIfNeeded()
            let timeline = try XCTUnwrap(timelineScrollView(in: hostingView))
            let newest = try XCTUnwrap(commandOutputView(containing: "remount-marker-149", in: hostingView))
            XCTAssertTrue(newest.convert(newest.bounds, to: timeline.contentView)
                .intersects(timeline.contentView.bounds), "Newest block missing on return \(iteration)")
        }
    }

    func testVisibleTimelineTracksWindowResizeWithoutRemounting() async throws {
        let session = makeTestSession()
        for index in 0..<40 {
            addCompletedBlock(command: "printf resize-\(index)",
                              output: String(repeating: "wrapped text ", count: 20) + "resize-marker-\(index)",
                              to: session)
        }
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = makeWindow(hostingView: hostingView)
        defer { window.orderOut(nil); session.shutdown() }
        try await waitUntil("shell startup") { session.isShellReadyForInput }
        for size in [NSSize(width: 450, height: 800), NSSize(width: 1200, height: 320),
                     NSSize(width: 600, height: 500), NSSize(width: 800, height: 420)] {
            window.setContentSize(size)
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            hostingView.layoutSubtreeIfNeeded()
            let timeline = try XCTUnwrap(timelineScrollView(in: hostingView))
            let newest = try XCTUnwrap(commandOutputView(containing: "resize-marker-39", in: hostingView))
            XCTAssertTrue(newest.convert(newest.bounds, to: timeline.contentView)
                .intersects(timeline.contentView.bounds), "Newest output missing after resize to \(size)")
        }
    }

    func testTimelineRemainsVisibleAfterCollapsingOutput() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        for index in 0..<150 {
            addCompletedBlock(
                command: "printf remount-\(index)",
                output: String(repeating: "wrapped output ", count: 400)
                    + "remount-marker-\(index)",
                to: session
            )
        }
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = makeWindow(hostingView: hostingView)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }
        try await waitUntil("shell startup") { session.isShellReadyForInput }

        try await Task.sleep(nanoseconds: 150_000_000)
        for block in session.blocks { session.toggleBlockCollapsed(id: block.id) }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        await drainMainQueue(turns: 4)
        hostingView.layoutSubtreeIfNeeded()
        let timeline = try XCTUnwrap(scrollViews(in: hostingView).max { $0.bounds.width < $1.bounds.width })
        let document = try XCTUnwrap(timeline.documentView)
        XCTAssertLessThanOrEqual(timeline.documentVisibleRect.maxY, document.bounds.maxY + 2)
    }

    func testCompletedCommandPinsTimelineToItsTrueBottom() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = makeWindow(hostingView: hostingView)
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
        try await Task.sleep(nanoseconds: 100_000_000)
        hostingView.layoutSubtreeIfNeeded()

        let timeline = try XCTUnwrap(timelineScrollView(in: hostingView))
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
                return !scrollViews(in: documentView).isEmpty
            }
            .max { lhs, rhs in
                lhs.bounds.width < rhs.bounds.width
            }
    }

    private func outputScrollView(
        containing outputView: NSView,
        in rootView: NSView
    ) -> NSScrollView? {
        scrollViews(in: rootView)
            .filter { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return contains(outputView, in: documentView)
                    && scrollViews(in: documentView).isEmpty
            }
            .min { lhs, rhs in
                (lhs.documentView?.bounds.height ?? 0)
                    < (rhs.documentView?.bounds.height ?? 0)
            }
    }

    private func commandOutputView(
        containing marker: String,
        in view: NSView
    ) -> NSView? {
        if let outputView = view as? CommandClickableNSTextView,
           outputView.string.contains(marker) {
            return outputView
        }
        if let outputView = view as? FrozenBlockTerminalView {
            let text = String(
                data: outputView.terminal.getBufferAsData(kind: .active),
                encoding: .utf8
            ) ?? ""
            if text.contains(marker) {
                return outputView
            }
        }
        for subview in view.subviews {
            if let outputView = commandOutputView(containing: marker, in: subview) {
                return outputView
            }
        }
        return nil
    }

    private func makeTestSession() -> TerminalSession {
        TerminalSession(
            shellConfiguration: .loginZsh(
                processEnvironment: [
                    "HOME": "/tmp",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
                ],
                homeDirectory: URL(fileURLWithPath: "/tmp")
            )
        )
    }

    private func makeWindow<Content: View>(hostingView: NSHostingView<Content>) -> NSWindow {
        // This harness owns the window's explicit resize scenarios. Letting
        // NSHostingView advertise a minimum/preferred window size can shrink
        // it to the root's measurement proposal while a native viewport mounts.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 420)
        hostingView.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func addCompletedBlock(
        command: String,
        output: String,
        to session: TerminalSession
    ) {
        let id = session.blockLifecycleController.queue(
            command: command,
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        session.blockLifecycleController.markAwaitingStart(id)
        XCTAssertEqual(session.blockLifecycleController.commandStarted(), id)
        XCTAssertEqual(
            session.blockLifecycleController.completeActive(
                exitCode: 0,
                renderedOutput: output,
                columns: 80,
                rows: 24
            ),
            id
        )
    }

    private func contains(_ target: NSView, in view: NSView) -> Bool {
        if view === target { return true }
        return view.subviews.contains { contains(target, in: $0) }
    }
}
