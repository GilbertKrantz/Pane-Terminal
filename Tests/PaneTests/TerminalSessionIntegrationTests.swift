import AppKit
import Darwin
import SwiftUI
import XCTest
@preconcurrency import SwiftTerm
@testable import Pane

final class TerminalSessionIntegrationTests: XCTestCase {
    @MainActor
    func testReadOnlyLiveMirrorHidesItsNoninteractiveScroller() throws {
        let terminalView = LiveCommandTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 120)
        )

        terminalView.layoutSubtreeIfNeeded()

        let scrollers = terminalView.subviews.compactMap { $0 as? NSScroller }
        XCTAssertFalse(scrollers.isEmpty)
        XCTAssertTrue(scrollers.allSatisfy(\.isHidden))
    }

    @MainActor
    func testHiddenPrimaryTerminalStillEmitsProtocolReplies() {
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        var response = Data()
        terminalView.onTerminalResponse = { response.append(contentsOf: $0) }

        terminalView.feed(text: "\u{001B}[6n")

        XCTAssertFalse(response.isEmpty)
        XCTAssertTrue(response.starts(with: [0x1B, 0x5B]))
        XCTAssertEqual(response.last, 0x52)
    }

    @MainActor
    func testShellInitializationBlocksDraftSubmissionUntilReady() async throws {
        let session = makeTestSession()
        session.commandDraft = "printf 'ready-after-initialization\\n'"

        XCTAssertEqual(session.shellReadiness, .starting)
        XCTAssertFalse(session.isShellReadyForInput)

        session.submitDraft()

        XCTAssertTrue(session.blocks.isEmpty)
        XCTAssertEqual(session.commandDraft, "printf 'ready-after-initialization\\n'")

        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        XCTAssertFalse(session.isShellReadyForInput)
        try await waitUntil("shell initialization to finish", timeout: 5) {
            session.shellReadiness == .ready && session.isShellReadyForInput
        }

        session.submitDraft()
        try await waitUntil("post-initialization command to complete", timeout: 5) {
            session.blocks.contains { block in
                guard block.command == "printf 'ready-after-initialization\\n'" else {
                    return false
                }
                if case .completed = block.state { return true }
                return false
            }
        }
        XCTAssertTrue(session.commandDraft.isEmpty)
    }

    @MainActor
    func testBlocksComposerHasAFullWidthEditableTextView() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        try await waitUntil("shell readiness and composer mount", timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isShellReadyForInput
                && self.findTextView(in: hostingView) != nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: hostingView))
        let composerScrollView = try XCTUnwrap(textView.enclosingScrollView)
        let composerFrame = composerScrollView.convert(
            composerScrollView.bounds,
            to: hostingView
        )
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertGreaterThan(textView.bounds.width, 400)
        XCTAssertEqual(
            composerScrollView.bounds.height,
            PaneMetrics.composerEditorMinHeight,
            accuracy: 1
        )
        XCTAssertEqual(
            composerFrame.minX,
            PaneMetrics.composerHorizontalInset,
            accuracy: 1
        )
        XCTAssertLessThan(
            composerFrame.maxX,
            hostingView.bounds.maxX - PaneMetrics.composerHorizontalInset
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.insertText("printf composer-ok", replacementRange: textView.selectedRange())
        await Task.yield()

        XCTAssertEqual(textView.string, "printf composer-ok")
        XCTAssertEqual(session.commandDraft, "printf composer-ok")

        let selectionBeforeResize = textView.selectedRange()
        window.setContentSize(NSSize(width: 340, height: 620))
        try await Task.sleep(nanoseconds: 50_000_000)
        hostingView.layoutSubtreeIfNeeded()

        let narrowTextView = try XCTUnwrap(findTextView(in: hostingView))
        let narrowScrollView = try XCTUnwrap(narrowTextView.enclosingScrollView)
        let narrowFrame = narrowScrollView.convert(narrowScrollView.bounds, to: hostingView)
        XCTAssertTrue(narrowTextView === textView)
        XCTAssertEqual(
            narrowFrame.minX,
            PaneMetrics.composerHorizontalInset,
            accuracy: 1
        )
        XCTAssertGreaterThan(narrowFrame.width, 150)
        XCTAssertEqual(narrowTextView.string, "printf composer-ok")
        XCTAssertEqual(narrowTextView.selectedRange(), selectionBeforeResize)
        XCTAssertTrue(window.firstResponder === narrowTextView)
    }

    @MainActor
    func testComposerControlCInterruptsForegroundCommand() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        try await waitUntil("composer and shell to mount", timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return self.findTextView(in: hostingView) != nil && session.isShellRunning
        }

        // A block becoming active is not enough: zsh can publish its preexec
        // marker before the child owns the PTY foreground process group. The
        // child itself confirms `tcgetpgrp(0) == getpgrp()` through a sidecar
        // file, avoiding reads from SwiftTerm's concurrently-rendered buffer.
        let readinessURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-ControlC-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readinessURL) }
        let command = """
        /usr/bin/perl -MPOSIX -e 'my $marker = "\(readinessURL.path)";
        while (POSIX::tcgetpgrp(0) != POSIX::getpgrp()) {
            select undef, undef, undef, 0.01;
        }
        open(my $file, ">", $marker) or die $!;
        close($file);
        exec "/usr/bin/caffeinate";'
        """
        session.submit(command: command)
        try await waitUntil("caffeinate child to become active", timeout: 5) {
            guard let block = session.activeCommandBlock else { return false }
            return block.command == command
                && block.state == .running
                && FileManager.default.fileExists(atPath: readinessURL.path)
                && self.findTextView(in: hostingView) != nil
        }

        session.commandDraft = "draft must remain"
        let textView = try XCTUnwrap(findTextView(in: hostingView))
        XCTAssertTrue(window.makeFirstResponder(textView))
        let controlC = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{3}",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )
        // Route through this window's responder chain, not directly to the
        // text view. Asking NSApplication to choose a key window is dependent
        // on unrelated windows left by earlier UI tests.
        window.sendEvent(controlC)

        try await waitUntil("Control-C to interrupt foreground command", timeout: 5) {
            guard let block = session.blocks.first(where: { $0.command == command }) else {
                return false
            }
            if case .interrupted(exitCode: 130) = block.state {
                return !session.isCommandActive
            }
            return false
        }
        XCTAssertEqual(session.commandDraft, "draft must remain")
    }

    @MainActor
    func testAlternateScreenEmbedsDirectTerminalWithoutLeavingBlocksLayout() async throws {
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        XCTAssertEqual(session.mode, .blocks)
        XCTAssertFalse(session.isAlternateScreenActive)

        for mode in [47, 1047, 1049] {
            terminalView.feed(text: "\u{001B}[?\(mode)h")

            XCTAssertTrue(terminalView.terminal.isCurrentBufferAlternate)
            try await waitUntil("session to observe DEC mode \(mode) entering") {
                session.isAlternateScreenActive
                    && session.mode == .blocks
                    && session.inputRequirement == .direct
                    && session.shouldEmbedAuthoritativeTerminalInActiveBlock == false
            }

            terminalView.feed(text: "\u{001B}[?\(mode)l")

            XCTAssertFalse(terminalView.terminal.isCurrentBufferAlternate)
            try await waitUntil("session to observe DEC mode \(mode) leaving") {
                !session.isAlternateScreenActive
                    && session.mode == .blocks
                    && session.inputRequirement == .shellIdle
            }
        }

        terminalView.feed(text: "\u{001B}[?1048h")
        await Task.yield()
        XCTAssertFalse(session.isAlternateScreenActive)
        XCTAssertEqual(session.mode, .blocks)
    }

    @MainActor
    func testManualModeChoiceOverridesAlternateScreenAutoReturn() async throws {
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        try await waitUntil("shell initialization before alternate screen", timeout: 5) {
            session.isShellReadyForInput
        }
        terminalView.feed(text: "\u{001B}[?1049h")
        try await waitUntil("embedded direct input after entering alternate screen") {
            session.isAlternateScreenActive
                && session.mode == .blocks
                && session.inputRequirement == .direct
        }

        session.setMode(.blocks)
        session.setMode(.terminal)
        terminalView.feed(text: "\u{001B}[?1049l")

        try await waitUntil("alternate-screen exit after manual mode override") {
            !session.isAlternateScreenActive
        }
        XCTAssertEqual(session.mode, .terminal)
    }

    @MainActor
    func testForegroundMonitorKeepsPaneShellInBlocksMode() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        try await waitUntil("idle shell to start", timeout: 5) {
            session.isShellRunning
        }
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(session.mode, .blocks)
        XCTAssertEqual(session.modeAttribution, .manual)
        XCTAssertFalse(session.isSecureInputActive)
    }

    @MainActor
    func testNoninteractiveForegroundProgramDoesNotForceDirectInput() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let command = "tail -f /dev/null"
        session.submit(command: command)

        try await waitUntil("tail to become the active command", timeout: 8) {
            session.activeCommandBlock?.processName == "tail"
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(session.mode, .blocks)
        XCTAssertEqual(session.inputRequirement, .lineOriented)
        XCTAssertEqual(session.activeTerminalPresentation, .liveMirror)

        session.sendInterrupt()
        try await waitUntil("shell foreground to restore Blocks mode", timeout: 8) {
            session.mode == .blocks && !session.isCommandActive
        }
    }

    @MainActor
    func testTerminalModePassesLiteralTabByteToPTY() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        session.submit(command: ":")
        try await waitUntil("shell integration to become ready", timeout: 8) {
            session.blocks.contains { block in
                guard block.command == ":" else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        session.setMode(.terminal)
        let readCommand = #"printf 'PANE_TAB_READY\n'; read -k 1 pane_char; printf '\nPANE_TAB=%d\n' "'$pane_char""#
        terminalView.send(data: Array("\(readCommand)\r".utf8)[...])
        _ = try await waitFor("PANE_TAB_READY", in: terminalView, timeout: 5)

        terminalView.send(data: [0x09][...])
        let output = try await waitFor("PANE_TAB=9", in: terminalView, timeout: 5)

        XCTAssertTrue(output.contains("PANE_TAB=9"), output)
    }

    @MainActor
    func testDirectTerminalCommandBecomesOneStructuredBlock() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        session.submit(command: ":")
        try await waitUntil("shell integration to become ready", timeout: 8) {
            session.blocks.contains { block in
                guard block.command == ":" else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        session.setMode(.terminal)
        let command = "printf 'PANE_DIRECT_CAPTURED\\n'"
        terminalView.send(data: Array("\(command)\r".utf8)[...])

        try await waitUntil("direct terminal command block to complete", timeout: 8) {
            session.blocks.contains { block in
                guard block.command == command else { return false }
                if case .completed(exitCode: 0) = block.state { return true }
                return false
            }
        }
        XCTAssertEqual(session.blocks.filter { $0.command == command }.count, 1)
    }

    @MainActor
    func testAuthoritativeTerminalAndHostIdentitySurviveRemounting() {
        let session = makeTestSession()
        defer { session.shutdown() }

        let firstHost = session.makeAuthoritativeTerminalHostView()
        let firstTerminal = session.makeAuthoritativeTerminalView()
        let secondHost = session.makeAuthoritativeTerminalHostView()
        let secondTerminal = session.makeAuthoritativeTerminalView()

        XCTAssertTrue(firstHost === secondHost)
        XCTAssertTrue(firstTerminal === secondTerminal)
        XCTAssertTrue(firstHost.terminalView === firstTerminal)
    }

    @MainActor
    func testManualSecureInputSuspendsAndRestoresComposerDraft() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }
        try await waitUntil("shell initialization before secure input", timeout: 5) {
            session.isShellReadyForInput
        }
        session.commandDraft = "unrelated draft"

        session.enterSecureInput()
        XCTAssertTrue(session.isSecureInputActive)
        XCTAssertEqual(session.inputRequirement, .secure)
        XCTAssertTrue(session.commandDraft.isEmpty)

        session.exitSecureInput()
        XCTAssertFalse(session.isSecureInputActive)
        XCTAssertEqual(session.commandDraft, "unrelated draft")
    }

    @MainActor
    func testRawTermiosAutomaticallyUsesCompactDirectInput() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let command = #"/bin/sh -c 'trap "stty icanon; exit 130" INT TERM; stty -icanon echo min 1 time 0; sleep 30'"#
        session.submit(command: command)

        try await waitUntil("raw termios to trigger embedded direct input", timeout: 8) {
            guard session.mode == .blocks,
                  session.inputRequirement == .direct,
                  session.shouldEmbedAuthoritativeTerminalInActiveBlock else { return false }
            if case .rawTermios = session.modeAttribution { return true }
            return false
        }
        XCTAssertEqual(session.activeTerminalPresentation, .authoritativeInBlock)

        let terminalIdentity = session.debugAuthoritativeTerminalView
        let hostIdentity = session.makeAuthoritativeTerminalHostView()
        let processGeneration = session.debugProcessGeneration
        session.setMode(.terminal)
        XCTAssertEqual(session.activeTerminalPresentation, .fullTerminal)
        session.setMode(.blocks)
        XCTAssertEqual(session.activeTerminalPresentation, .authoritativeInBlock)
        XCTAssertEqual(session.focusTarget, .authoritativeTerminal)
        XCTAssertTrue(session.debugAuthoritativeTerminalView === terminalIdentity)
        XCTAssertTrue(session.debugAuthoritativeHostView === hostIdentity)
        XCTAssertEqual(session.debugProcessGeneration, processGeneration)

        session.sendInterrupt()
        try await waitUntil("canonical shell input to restore Blocks mode", timeout: 8) {
            session.mode == .blocks && !session.isCommandActive
        }
    }

    @MainActor
    func testAlternateScreenOverridesTransientAutomaticSecureClassification() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let command = #"/bin/sh -c 'trap "printf \"\033[?1049l\"; stty echo icanon; exit 130" INT TERM; stty -echo -icanon; printf "\033[?1049h"; sleep 30'"#
        session.submit(command: command)

        try await waitUntil("alternate screen to use direct rather than secure input", timeout: 8) {
            session.isAlternateScreenActive
                && session.inputRequirement == .direct
                && !session.isSecureInputActive
                && session.modeAttribution == .alternateScreen
                && session.shouldEmbedAuthoritativeTerminalInActiveBlock
                && session.shouldPresentExpandedAuthoritativeTerminal
        }

        session.sendInterrupt()
    }

    @MainActor
    func testAlternateScreenLayoutRemovesBottomComposer() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
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

        hostingView.layoutSubtreeIfNeeded()
        try await waitUntil("shell to start", timeout: 5) {
            session.isShellRunning
        }

        let command = #"/bin/sh -c 'trap "printf \"\033[?1049l\"; stty echo icanon; exit 130" INT TERM; stty -echo -icanon; printf "\033[?1049h"; sleep 30'"#
        session.submit(command: command)

        try await waitUntil("alternate-screen block layout", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isAlternateScreenActive
                && session.shouldEmbedAuthoritativeTerminalInActiveBlock
                && session.shouldPresentExpandedAuthoritativeTerminal
                && self.findTerminalView(in: hostingView) != nil
                && self.findTextView(in: hostingView) == nil
        }

        XCTAssertTrue(session.inputRequirement == .direct)
        XCTAssertFalse(session.isSecureInputActive)
        await drainMainQueue(turns: 3)
        AuthoritativeTerminalRenderInstrumentation.reset()
        try await Task.sleep(for: .seconds(10))
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.hostReparents, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.postMountCallbacks, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.ptyResizeAccepted, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.focusResponderChanges, 0)
        session.sendInterrupt()
    }

    @MainActor
    func testAlternateScreenInputSurvivesRapidBlocksTerminalReparenting() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let defaultsSuiteName = "PaneTests.AlternateScreenReparent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let hostingView = NSHostingView(
            rootView: ContentView(session: session)
                .defaultAppStorage(defaults)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        try await waitUntil("shell and Blocks composer to mount", timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isShellReadyForInput
                && self.findTextView(in: hostingView) != nil
        }

        let terminalIdentity = session.makeAuthoritativeTerminalView()
        let hostIdentity = session.makeAuthoritativeTerminalHostView()
        let processGeneration = session.debugProcessGeneration
        let command = #"trap 'printf "\033[?1049l"; stty echo icanon; exit 130' INT TERM; stty -echo -icanon min 1 time 0; printf '\033[?1049hPANE_ALT_READY\n'; read -k 1 pane_a; printf 'PANE_ALT_A=%s\n' "$pane_a"; read -k 1 pane_b; printf 'PANE_ALT_B=%s\n' "$pane_b"; read -k 1 pane_c; printf 'PANE_ALT_C=%s\n' "$pane_c"; printf '\033[?1049l'; stty echo icanon"#
        session.submit(command: command)

        try await waitUntil("alternate-screen authoritative Block mount", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isAlternateScreenActive
                && session.activeTerminalPresentation == .expanded
                && session.focusTarget == .authoritativeTerminal
                && terminalIdentity.window === window
                && window.firstResponder === terminalIdentity
        }
        _ = try await waitFor("PANE_ALT_READY", in: terminalIdentity, timeout: 5)

        terminalIdentity.send(data: [Character("A").asciiValue!][...])
        _ = try await waitFor("PANE_ALT_A=A", in: terminalIdentity, timeout: 5)

        session.setMode(.terminal)
        try await waitUntil("Full Terminal remount and focus repair", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return session.activeTerminalPresentation == .fullTerminal
                && terminalIdentity.window === window
                && window.firstResponder === terminalIdentity
        }
        terminalIdentity.send(data: [Character("B").asciiValue!][...])
        _ = try await waitFor("PANE_ALT_B=B", in: terminalIdentity, timeout: 5)

        for expectedMode in [
            InputMode.blocks,
            .terminal,
            .blocks,
            .terminal,
            .blocks
        ] {
            session.setMode(expectedMode)
            try await waitUntil(
                "\(expectedMode.rawValue) remount during rapid transition",
                timeout: 8,
                diagnostics: {
                    "mode=\(session.mode.rawValue), "
                        + "presentation=\(session.activeTerminalPresentation), "
                        + "alternate=\(session.isAlternateScreenActive), "
                        + "terminalWindowMatches=\(terminalIdentity.window === window), "
                        + "hostSuperview=\(String(describing: hostIdentity.superview))"
                }
            ) {
                hostingView.layoutSubtreeIfNeeded()
                let expectedPresentation: ActiveTerminalPresentation =
                    expectedMode == .terminal ? .fullTerminal : .expanded
                return session.mode == expectedMode
                    && session.activeTerminalPresentation == expectedPresentation
                    && terminalIdentity.window === window
            }
            XCTAssertTrue(session.debugAuthoritativeTerminalView === terminalIdentity)
            XCTAssertTrue(session.debugAuthoritativeHostView === hostIdentity)
            XCTAssertEqual(session.debugProcessGeneration, processGeneration)
        }

        try await waitUntil("terminal focus after final rapid Blocks remount", timeout: 8) {
            window.firstResponder === terminalIdentity
                && session.focusTarget == .authoritativeTerminal
        }
        terminalIdentity.send(data: [Character("C").asciiValue!][...])
        _ = try await waitFor("PANE_ALT_C=C", in: terminalIdentity, timeout: 5)
        try await waitUntil("alternate-screen fixture to finish", timeout: 8) {
            !session.isAlternateScreenActive && !session.isCommandActive
        }

        XCTAssertTrue(session.debugAuthoritativeTerminalView === terminalIdentity)
        XCTAssertTrue(session.debugAuthoritativeHostView === hostIdentity)
        XCTAssertEqual(session.debugProcessGeneration, processGeneration)
    }

    @MainActor
    func testForegroundingSuspendedAlternateScreenRestoresExpandedWorkspaceGeometry() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let defaultsSuiteName = "PaneTests.AlternateScreenForeground.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let hostingView = NSHostingView(
            rootView: ContentView(session: session)
                .defaultAppStorage(defaults)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        try await waitUntil("shell and Blocks composer to mount", timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isShellReadyForInput
                && self.findTextView(in: hostingView) != nil
        }

        let command = #"/usr/bin/perl -MPOSIX=SIGSTOP -e '$|=1; sub normal { print "\e[?1049l"; system "stty echo icanon"; } $SIG{INT}=sub { normal(); exit 130; }; $SIG{TERM}=sub { normal(); exit 143; }; $SIG{TSTP}=sub { normal(); print "PANE_SUSPENDED\n"; kill SIGSTOP, $$; system "stty -echo -icanon"; select undef, undef, undef, 0.6; print "\e[?1049hPANE_RESUMED\n"; }; system "stty -echo -icanon"; print "\e[?1049hPANE_STARTED\n"; while (1) { select undef, undef, undef, 1; }'"#
        session.submit(command: command)

        try await waitUntil("initial alternate screen to expand", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isAlternateScreenActive
                && session.activeTerminalPresentation == .expanded
        }
        let terminal = session.makeAuthoritativeTerminalView()
        let terminalIdentity = ObjectIdentifier(terminal)
        let ptyGeneration = session.debugProcessGeneration

        terminal.send(data: [0x1A][...])
        try await waitUntil("suspended job to return to the shell", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return !session.isAlternateScreenActive
                && !session.isCommandActive
                && session.isShellReadyForInput
        }

        session.submit(command: "fg")
        try await waitUntil("foregrounded job to mount compact direct input", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return session.activeTerminalPresentation == .authoritativeInBlock
                && terminal.window === window
                && terminal.visibleRect.height < 200
        }
        try await waitUntil(
            "foregrounded alternate screen to reclaim expanded geometry",
            timeout: 8
        ) {
            hostingView.layoutSubtreeIfNeeded()
            return session.isAlternateScreenActive
                && session.activeTerminalPresentation == .expanded
                && terminal.window === window
                && terminal.visibleRect.height > hostingView.bounds.height * 0.65
        }

        XCTAssertEqual(ObjectIdentifier(session.makeAuthoritativeTerminalView()), terminalIdentity)
        XCTAssertEqual(session.debugProcessGeneration, ptyGeneration)
        XCTAssertGreaterThan(terminal.visibleRect.height, hostingView.bounds.height * 0.65)

        session.sendInterrupt()
        try await waitUntil("foregrounded fixture to exit", timeout: 8) {
            !session.isAlternateScreenActive && !session.isCommandActive
        }
    }

    @MainActor
    func testCharacterChoiceUsesCompactAuthoritativeBlockAndPreservesPrompt() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = makeTestSession()
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
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

        hostingView.layoutSubtreeIfNeeded()
        try await waitUntil("shell to start", timeout: 5) {
            session.isShellRunning
        }

        let command = #"/bin/sh -c 'trap "stty icanon; exit 130" INT TERM; stty -icanon echo min 1 time 0; printf "PANE_CHOICE [y/n]"; pane_choice=$(dd bs=1 count=1 2>/dev/null); printf "\nPANE_CHOICE=%s\n" "$pane_choice"; stty icanon'"#
        session.submit(command: command)

        try await waitUntil("character choice compact input classification", timeout: 8) {
            session.inputRequirement == .direct
                && !session.isAlternateScreenActive
                && !session.isSecureInputActive
                && session.shouldPresentCompactAuthoritativeTerminal
                && !session.shouldPresentExpandedAuthoritativeTerminal
        }
        XCTAssertEqual(session.debugSnapshot.interactionState, .commandRunningDirect)
        XCTAssertEqual(session.debugSnapshot.keyboardOwner, .authoritativeTerminal)
        XCTAssertEqual(session.debugSnapshot.terminalMount, .authoritativeInBlock)
        try await waitUntil("compact authoritative terminal mount", timeout: 8) {
            hostingView.layoutSubtreeIfNeeded()
            return self.findTerminalView(in: hostingView) != nil
        }
        XCTAssertNil(findTextView(in: hostingView))
        let mountedTerminal = try XCTUnwrap(findTerminalView(in: hostingView))
        try await waitUntil("choice prompt in compact authoritative terminal", timeout: 8) {
            self.bufferText(in: mountedTerminal, kind: .active)
                .contains("PANE_CHOICE [y/n]")
        }

        let hostIdentity = session.makeAuthoritativeTerminalHostView()
        let processGeneration = session.debugProcessGeneration
        session.setMode(.terminal)
        try await waitUntil("normal-buffer direct input to mount in Full Terminal", timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return session.activeTerminalPresentation == .fullTerminal
                && mountedTerminal.window === window
                && window.firstResponder === mountedTerminal
        }
        session.setMode(.blocks)
        try await waitUntil("normal-buffer direct input to remount in Blocks", timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return session.activeTerminalPresentation == .authoritativeInBlock
                && session.focusTarget == .authoritativeTerminal
                && mountedTerminal.window === window
                && window.firstResponder === mountedTerminal
        }

        mountedTerminal.send(data: [Character("y").asciiValue!][...])
        _ = try await waitFor("PANE_CHOICE=y", in: mountedTerminal, timeout: 5)
        try await waitUntil("interactive block to finish and return focus", timeout: 8) {
            guard let block = session.blocks.first(where: { $0.command == command }) else {
                return false
            }
            if case .completed(exitCode: 0) = block.state {
                return session.focusTarget == .composer
            }
            return false
        }
        XCTAssertTrue(session.debugAuthoritativeTerminalView === mountedTerminal)
        XCTAssertTrue(session.debugAuthoritativeHostView === hostIdentity)
        XCTAssertEqual(session.debugProcessGeneration, processGeneration)
    }

    @MainActor
    func testNoEchoInputBypassesDraftHistoryAutocompleteAndRenderedOutput() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let command = #"/bin/sh -c 'stty -echo; printf "PANE_SECURE_READY\n"; IFS= read -r pane_secret; stty echo; printf "\nPANE_SECURE_DONE\n"'"#
        session.submit(command: command)

        try await waitUntil("disabled echo to enter secure input", timeout: 8) {
            session.isSecureInputActive
                && session.mode == .blocks
                && session.inputRequirement == .secure
                && session.shouldEmbedAuthoritativeTerminalInActiveBlock
                && session.shouldPresentCompactAuthoritativeTerminal
        }
        let readyOutput = try await waitFor(
            "PANE_SECURE_READY",
            in: terminalView,
            timeout: 5
        )
        XCTAssertTrue(readyOutput.contains("PANE_SECURE_READY"), readyOutput)
        let updates = await session.autocompleteSuggestions(
            for: "git",
            cursorUTF16Offset: 3
        )
        let suggestions = await finalSuggestions(from: updates)
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(session.commandDraft.isEmpty)

        let seededSecret = "pane-secure-secret-123456"
        terminalView.send(data: Array("\(seededSecret)\n".utf8)[...])

        let completedOutput = try await waitFor(
            "PANE_SECURE_DONE",
            in: terminalView,
            timeout: 5
        )
        XCTAssertTrue(completedOutput.contains("PANE_SECURE_DONE"), completedOutput)

        try await waitUntil("secure input to end", timeout: 8) {
            !session.isSecureInputActive
        }
        try await waitUntil("secure command block to finish", timeout: 8) {
            !session.isCommandActive
        }
        try await waitUntil("Blocks mode to resume after secure input", timeout: 8) {
            session.mode == .blocks
        }

        let block = try XCTUnwrap(session.blocks.first { $0.command == command })
        let terminalText = bufferText(in: terminalView, kind: .active)
        XCTAssertFalse(block.output.contains(seededSecret))
        XCTAssertFalse(terminalText.contains(seededSecret))
        XCTAssertFalse(session.commandDraft.contains(seededSecret))
        XCTAssertFalse(session.history.commands.contains { $0.contains(seededSecret) })
    }

    @MainActor
    func testShellBuiltinReadSilentEntersSecureModeWithoutLeakingInput() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let command = #"printf 'PANE_READ_S_READY\n'; read -s pane_secret; printf '\nPANE_READ_S_DONE\n'"#
        session.submit(command: command)
        let readyOutput = try await waitFor(
            "PANE_READ_S_READY",
            in: terminalView,
            timeout: 5
        )
        XCTAssertTrue(readyOutput.contains("PANE_READ_S_READY"), readyOutput)
        try await waitUntil("read -s to enter secure input", timeout: 8) {
            session.isSecureInputActive
        }

        let seededSecret = "pane-zsh-read-secret-987654"
        terminalView.send(data: Array("\(seededSecret)\n".utf8)[...])
        let completedOutput = try await waitFor(
            "PANE_READ_S_DONE",
            in: terminalView,
            timeout: 5
        )
        XCTAssertTrue(completedOutput.contains("PANE_READ_S_DONE"), completedOutput)
        try await waitUntil("normal prompt after read -s", timeout: 8) {
            !session.isSecureInputActive && !session.isCommandActive
        }

        let block = try XCTUnwrap(session.blocks.first { $0.command == command })
        XCTAssertFalse(block.output.contains(seededSecret))
        XCTAssertFalse(bufferText(in: terminalView, kind: .active).contains(seededSecret))
        XCTAssertFalse(session.commandDraft.contains(seededSecret))
        XCTAssertFalse(session.history.commands.contains { $0.contains(seededSecret) })
    }

    @MainActor
    func testDEC1049UsesAnIsolatedAlternateBufferAndRestoresNormalBuffer() {
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )

        terminalView.feed(text: "normal-buffer-marker")
        let normalBeforeSwitch = bufferText(in: terminalView, kind: .normal)
        XCTAssertTrue(normalBeforeSwitch.contains("normal-buffer-marker"))

        terminalView.feed(text: "\u{001B}[?1049h")

        XCTAssertTrue(terminalView.terminal.isCurrentBufferAlternate)
        XCTAssertFalse(bufferText(in: terminalView, kind: .active).contains("normal-buffer-marker"))
        XCTAssertEqual(bufferText(in: terminalView, kind: .normal), normalBeforeSwitch)

        terminalView.feed(text: "alternate-frame-marker")

        let alternateFrame = bufferText(in: terminalView, kind: .active)
        XCTAssertTrue(alternateFrame.contains("alternate-frame-marker"))
        XCTAssertFalse(alternateFrame.contains("normal-buffer-marker"))
        XCTAssertFalse(bufferText(in: terminalView, kind: .normal).contains("alternate-frame-marker"))

        terminalView.feed(text: "\u{001B}[?1049l")

        XCTAssertFalse(terminalView.terminal.isCurrentBufferAlternate)
        let restoredNormalBuffer = bufferText(in: terminalView, kind: .active)
        XCTAssertEqual(restoredNormalBuffer, normalBeforeSwitch)
        XCTAssertTrue(restoredNormalBuffer.contains("normal-buffer-marker"))
        XCTAssertFalse(restoredNormalBuffer.contains("alternate-frame-marker"))
    }

    @MainActor
    func testRapidAlternateScreenExitReturnsKeyboardFocusToComposer() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let hostingView = NSHostingView(rootView: ContentView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
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

        hostingView.layoutSubtreeIfNeeded()
        try await waitUntil("composer to mount") {
            hostingView.layoutSubtreeIfNeeded()
            return self.findTextView(in: hostingView) != nil
        }

        let initialComposer = try XCTUnwrap(findTextView(in: hostingView))
        XCTAssertTrue(window.makeFirstResponder(initialComposer))
        let terminalView = session.makeAuthoritativeTerminalView()

        terminalView.feed(text: "\u{001B}[?1049h")
        try await waitUntil("deferred alternate-screen entry") {
            session.isAlternateScreenActive
                && session.mode == .blocks
                && session.inputRequirement == .direct
        }

        // Exit as soon as the deferred entry notification is observed. This
        // intentionally races the representable's queued focus hand-off.
        terminalView.feed(text: "\u{001B}[?1049l")
        try await waitUntil("deferred alternate-screen exit") {
            !session.isAlternateScreenActive && session.mode == .blocks
        }

        try await waitUntil("keyboard focus to return to the composer") {
            hostingView.layoutSubtreeIfNeeded()
            guard let composer = self.findTextView(in: hostingView) else { return false }
            return window.firstResponder === composer
        }

        XCTAssertFalse(terminalView.terminal.isCurrentBufferAlternate)
        XCTAssertTrue(window.firstResponder is NSTextView)

        // A true back-to-back enter/leave is coalesced before either state is
        // published. The stale queued entry must not steal focus afterward.
        terminalView.feed(text: "\u{001B}[?1049h")
        terminalView.feed(text: "\u{001B}[?1049l")
        await drainMainQueue(turns: 2)
        hostingView.layoutSubtreeIfNeeded()

        let composerAfterCoalescedSwitch = try XCTUnwrap(findTextView(in: hostingView))
        XCTAssertFalse(session.isAlternateScreenActive)
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertTrue(window.firstResponder === composerAfterCoalescedSwitch)
    }

    @MainActor
    func testInteractiveLoginShellLoadsZshrcUsedByOhMyZsh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-Zshrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try "export PANE_ZSHRC=loaded\n".write(
            to: directory.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": directory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "ZDOTDIR": directory.path
            ],
            homeDirectory: directory
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        try await waitUntil("interactive shell initialization", timeout: 5) {
            session.isShellReadyForInput
        }
        session.commandDraft = "printf 'PANE_ZSHRC=%s\\n' \"$PANE_ZSHRC\""
        session.submitDraft()

        let output = try await waitFor(
            "PANE_ZSHRC=loaded",
            in: terminalView,
            timeout: 5
        )
        XCTAssertTrue(
            output.contains("PANE_ZSHRC=loaded"),
            "Expected interactive zsh to load $ZDOTDIR/.zshrc:\n\(output)"
        )
    }

    @MainActor
    func testCommandsShareOnePersistentPTYBackedShell() async throws {
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        try await waitUntil("persistent shell initialization", timeout: 5) {
            session.isShellReadyForInput
        }
        session.commandDraft = "cd /"
        session.submitDraft()
        try await waitUntil("cd command to complete") {
            session.blocks.contains { block in
                guard block.command == "cd /" else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        session.commandDraft = "printf 'PANE_CWD=%s\\n' \"$PWD\""
        session.submitDraft()

        var renderedOutput = try await waitFor(
            "PANE_CWD=/",
            in: terminalView,
            timeout: 5
        )

        XCTAssertTrue(
            renderedOutput.contains("PANE_CWD=/"),
            "Expected persistent working directory in terminal output:\n\(renderedOutput)"
        )

        session.setMode(.terminal)
        let rawCommand = Array("printf 'PANE_RAW_OK\\n'\r".utf8)
        terminalView.send(data: rawCommand[...])

        renderedOutput = try await waitFor(
            "PANE_RAW_OK",
            in: terminalView,
            timeout: 5
        )

        XCTAssertTrue(
            renderedOutput.contains("PANE_RAW_OK"),
            "Expected raw-mode bytes to reach the PTY:\n\(renderedOutput)"
        )

        let block = try await waitForCompletedBlock(
            containing: "PANE_CWD=/",
            in: session,
            timeout: 5
        )
        XCTAssertEqual(block.command, "printf 'PANE_CWD=%s\\n' \"$PWD\"")
        XCTAssertTrue(block.succeeded)
        XCTAssertEqual(session.currentDirectory, "/")
    }

    @MainActor
    func testCompletedCommandPersistsAndRestoresOnlyPredictionHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-LiveRuntimeState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let runtimeConfiguration = RuntimeStateConfiguration(
            persistenceEnabled: true,
            commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        )
        let shellConfiguration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let firstController = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: runtimeConfiguration
        )
        let firstSession = TerminalSession(
            shellConfiguration: shellConfiguration,
            runtimeStateController: firstController
        )
        let firstTerminal = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        firstSession.attach(terminalView: firstTerminal)

        let command = "printf 'PANE_PERSISTED_CONTEXT\\n'"
        firstSession.submit(command: command)
        try await waitUntil("command to complete before persistence", timeout: 8) {
            firstSession.blocks.contains { block in
                guard block.command == command else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        let inspectionStore = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        try await waitForPersistedCommand(
            command,
            workspaceID: "/tmp",
            in: inspectionStore,
            timeout: 8
        )
        firstSession.shutdown()

        let secondController = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: runtimeConfiguration
        )
        let restoredSession = TerminalSession(
            shellConfiguration: shellConfiguration,
            runtimeStateController: secondController
        )
        let restoredTerminal = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        restoredSession.attach(terminalView: restoredTerminal)
        defer { restoredSession.shutdown() }

        try await waitUntil("prediction history to restore", timeout: 8) {
            restoredSession.history.commands.contains(command)
        }
        XCTAssertTrue(restoredSession.blocks.contains { block in
            block.command == command && block.isRerunnable
        })
        XCTAssertTrue(restoredSession.commandDraft.isEmpty)
        XCTAssertFalse(restoredSession.isSecureInputActive)
    }

    @MainActor
    func testActiveBlockStreamsThroughReadOnlyTerminalThenFreezesOneSnapshot() async throws {
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let primary = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let live = LiveCommandTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 220)
        )
        session.attach(terminalView: primary)
        defer { session.shutdown() }

        let command =
            "printf 'PANE_PROGRESS_01%%\\rPANE_PROGRESS_42%%\\rPANE_%s\\n' " +
            "PROGRESS_DONE; sleep 0.5"
        session.submit(command: command)

        try await waitUntil("command to become active") {
            session.blockTimeline.activeBlockID != nil
        }
        let blockID = try XCTUnwrap(session.blockTimeline.activeBlockID)
        session.attachLiveCommandTerminalView(live, blockID: blockID)
        // Reattaching the same mirror must not replay buffered bytes twice.
        session.attachLiveCommandTerminalView(live, blockID: blockID)

        try await waitUntil("live terminal to render progress") {
            self.bufferText(in: live, kind: .active).contains("PANE_PROGRESS_DONE")
        }

        let runningBlock = try XCTUnwrap(session.blockTimeline.block(id: blockID))
        XCTAssertEqual(runningBlock.output, "")
        XCTAssertTrue(primary.terminalDelegate === session)
        XCTAssertNil(live.terminalDelegate)
        XCTAssertEqual(
            occurrenceCount(of: "PANE_PROGRESS_DONE", in: bufferText(in: live, kind: .active)),
            1
        )

        try await waitUntil("active command to complete") {
            guard let block = session.blockTimeline.block(id: blockID) else { return false }
            if case .completed = block.state { return true }
            return false
        }

        let completedBlock = try XCTUnwrap(session.blockTimeline.block(id: blockID))
        XCTAssertEqual(completedBlock.output, "PANE_PROGRESS_DONE")
        let snapshot = try XCTUnwrap(completedBlock.terminalSnapshot)
        XCTAssertFalse(snapshot.bytes.isEmpty)
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(
            occurrenceCount(
                of: "PANE_PROGRESS_DONE",
                in: bufferText(in: primary, kind: .active)
            ),
            1
        )
    }

    @MainActor
    func testCompletedBlockPreservesStderrAndNonzeroExitCode() async throws {
        let session = makeTestSession()
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let marker = "PANE_STDERR_ONLY_7E94D9"
        let command = "print -u2 -- \(marker); (exit 23)"
        session.submit(command: command)

        try await waitUntil("stderr-only command to finish", timeout: 5) {
            guard let block = session.blocks.first(where: { $0.command == command }) else {
                return false
            }
            if case .completed(exitCode: 23) = block.state {
                return true
            }
            return false
        }

        let block = try XCTUnwrap(session.blocks.first { $0.command == command })
        XCTAssertEqual(block.state, .completed(exitCode: 23))
        XCTAssertEqual(
            block.output.trimmingCharacters(in: .whitespacesAndNewlines),
            marker
        )
    }

    @MainActor
    func testMultilineDraftProducesOneCompletedBlock() async throws {
        let session = makeTestSession()
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let command = "printf 'PANE_MULTI_ONE\\n'\nprintf 'PANE_MULTI_TWO\\n'"
        session.submit(command: command)

        try await waitUntil("multiline command to complete as one block", timeout: 5) {
            session.blocks.contains { block in
                guard block.command == command else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        let matchingBlocks = session.blocks.filter { $0.command == command }
        let block = try XCTUnwrap(matchingBlocks.first)
        XCTAssertEqual(matchingBlocks.count, 1)
        XCTAssertTrue(block.output.contains("PANE_MULTI_ONE"))
        XCTAssertTrue(block.output.contains("PANE_MULTI_TWO"))
    }

    @MainActor
    func testIncompleteCommandContinuesInComposerAndCompletesOneBlock() async throws {
        let session = makeTestSession()
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        session.submit(command: "if true; then")
        try await waitUntil("shell continuation prompt", timeout: 5) {
            guard let block = session.activeCommandBlock else { return false }
            return block.command == "if true; then" && block.state == .queued
        }

        session.commandDraft = "printf 'PANE_CONTINUATION_OK\\n'"
        session.submitDraft()
        session.commandDraft = "fi"
        session.submitDraft()

        let expectedCommand = "if true; then\nprintf 'PANE_CONTINUATION_OK\\n'\nfi"
        try await waitUntil("continued command to complete", timeout: 5) {
            session.blocks.contains { block in
                guard block.command == expectedCommand else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        let block = try XCTUnwrap(session.blocks.first { $0.command == expectedCommand })
        XCTAssertTrue(block.output.contains("PANE_CONTINUATION_OK"))
        XCTAssertEqual(session.history.commands.last, expectedCommand)
    }

    @MainActor
    func testCancellingContinuationUnwedgesNextCommand() async throws {
        let session = makeTestSession()
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        let incompleteCommand = "if true; then"
        session.submit(command: incompleteCommand)
        try await waitUntil("incomplete command to await input", timeout: 5) {
            session.activeCommandBlock?.command == incompleteCommand
        }

        session.sendInterrupt()
        try await waitUntil("incomplete command cancellation", timeout: 5) {
            guard let block = session.blocks.first(where: { $0.command == incompleteCommand }) else {
                return false
            }
            if case .interrupted = block.state {
                return !session.isCommandActive
            }
            return false
        }

        let recoveryCommand = "printf 'PANE_AFTER_CANCEL_OK\\n'"
        session.submit(command: recoveryCommand)
        try await waitUntil("command after cancellation to complete", timeout: 5) {
            session.blocks.contains { block in
                guard block.command == recoveryCommand,
                      block.output.contains("PANE_AFTER_CANCEL_OK") else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }
    }

    @MainActor
    func testLiveMirrorDetachDoesNotLoseEarlierOutput() async throws {
        let session = makeTestSession()
        let primary = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        let firstMirror = LiveCommandTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 220)
        )
        let secondMirror = LiveCommandTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 220)
        )
        session.attach(terminalView: primary)
        defer { session.shutdown() }

        session.submit(
            command: "printf 'PANE_EARLY\\n'; sleep 0.25; printf 'PANE_LATE\\n'"
        )
        try await waitUntil("command to start", timeout: 5) {
            session.blockTimeline.activeBlockID != nil
        }
        let blockID = try XCTUnwrap(session.blockTimeline.activeBlockID)
        session.attachLiveCommandTerminalView(firstMirror, blockID: blockID)

        try await waitUntil("early mirror output", timeout: 5) {
            self.bufferText(in: firstMirror, kind: .active).contains("PANE_EARLY")
        }
        session.detachLiveCommandTerminalView(firstMirror, blockID: blockID)
        session.attachLiveCommandTerminalView(secondMirror, blockID: blockID)

        try await waitUntil("reattached mirror to restore early output", timeout: 5) {
            self.bufferText(in: secondMirror, kind: .active).contains("PANE_EARLY")
        }
        try await waitUntil("command to finish after mirror transition", timeout: 5) {
            guard let block = session.blockTimeline.block(id: blockID) else { return false }
            if case .completed = block.state { return true }
            return false
        }

        let completed = try XCTUnwrap(session.blockTimeline.block(id: blockID))
        XCTAssertTrue(completed.output.contains("PANE_EARLY"))
        XCTAssertTrue(completed.output.contains("PANE_LATE"))
    }

    func testRawWaitStatusIsNormalizedForDisplay() {
        XCTAssertEqual(TerminalSession.normalizedExitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(TerminalSession.normalizedExitCode(fromWaitStatus: 7 << 8), 7)
        XCTAssertEqual(TerminalSession.normalizedExitCode(fromWaitStatus: SIGTERM), 143)
        XCTAssertNil(TerminalSession.normalizedExitCode(fromWaitStatus: nil))
    }

    @MainActor
    func testAutocompleteCapturesCompletionDefinedInTheWarmShell() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-WarmCompletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try "autoload -Uz compinit\ncompinit -C\n".write(
            to: directory.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": directory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "ZDOTDIR": directory.path
            ],
            homeDirectory: directory
        )
        let session = TerminalSession(shellConfiguration: configuration)
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        // This variable and compdef are created after the persistent shell is
        // running. A separately initialized helper zsh cannot observe them.
        let installRuntimeCompletion = #"typeset -g PANE_WARM_FLAG='from-warm-state'; _pane_warm_completion() { _arguments "--${PANE_WARM_FLAG}[Defined in the active Pane shell]" }; compdef _pane_warm_completion pane-warm-fixture"#
        session.submit(command: installRuntimeCompletion)

        try await waitUntil("runtime completion definition to finish", timeout: 8) {
            session.blocks.contains { block in
                guard block.command == installRuntimeCompletion else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }

        let draft = "pane-warm-fixture --f"
        let updates = await session.autocompleteSuggestions(
            for: draft,
            cursorUTF16Offset: (draft as NSString).length
        )
        let suggestions = await finalSuggestions(from: updates)

        let warmSuggestion = try XCTUnwrap(
            suggestions.first(where: { $0.replacementText == "--from-warm-state" }),
            "Expected zsh compsys to use the live shell's runtime compdef and parameter"
        )
        XCTAssertEqual(warmSuggestion.source, .zsh)
        XCTAssertEqual(warmSuggestion.detail, "Defined in the active Pane shell")
    }

    @MainActor
    private func waitFor(
        _ marker: String,
        in terminalView: TerminalView,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var output = ""

        while Date() < deadline {
            output = String(
                data: terminalView.terminal.getBufferAsData(),
                encoding: .utf8
            ) ?? ""
            if output.contains(marker) {
                return output
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        return output
    }

    @MainActor
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

    @MainActor
    private func waitForCompletedBlock(
        containing marker: String,
        in session: TerminalSession,
        timeout: TimeInterval
    ) async throws -> CommandBlock {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let block = session.blocks.first(where: { block in
                guard block.output.contains(marker) else { return false }
                if case .completed = block.state { return true }
                return false
            }) {
                return block
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for completed block containing \(marker)")
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private func waitForPersistedCommand(
        _ command: String,
        workspaceID: String,
        in store: SQLiteRuntimeStateStore,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let context = try await store.loadRecentContext(
                workspaceID: workspaceID,
                repositoryID: nil,
                limit: 20
            )
            if context.commandEvents.contains(where: { $0.command == command }) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for command to persist")
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        diagnostics: (@MainActor () -> String)? = nil,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let diagnosticText = diagnostics.map { "; \($0())" } ?? ""
        XCTFail("Timed out waiting for \(description)\(diagnosticText)")
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private func bufferText(
        in terminalView: TerminalView,
        kind: Terminal.BufferKind
    ) -> String {
        String(
            data: terminalView.terminal.getBufferAsData(kind: kind),
            encoding: .utf8
        ) ?? ""
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    @MainActor
    private func drainMainQueue(turns: Int) async {
        for _ in 0..<turns {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    @MainActor
    private func findTerminalView(in view: NSView) -> PaneTerminalView? {
        if let terminalView = view as? PaneTerminalView {
            return terminalView
        }

        for subview in view.subviews {
            if let terminalView = findTerminalView(in: subview) {
                return terminalView
            }
        }
        return nil
    }
}

extension TerminalSessionIntegrationTests {
    @MainActor
    func testStandardCopyCommandSanitizesSecrets() throws {
        let session = TerminalSession()
        session.submit(command: "curl -H 'Authorization: Bearer pane-secret-token-1234567890' https://example.com")
        let block = try XCTUnwrap(session.blocks.last)

        session.copyCommand(id: block.id)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""

        XCTAssertFalse(copied.contains("pane-secret-token-1234567890"))
    }

    @MainActor
    func testNormalCopyCommandRemainsUnchanged() throws {
        let session = TerminalSession()
        let command = "echo hello"
        session.submit(command: command)
        let block = try XCTUnwrap(session.blocks.last)

        session.copyCommand(id: block.id)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), command)
    }

    @MainActor
    func testStaleFocusGenerationIsIgnored() {
        let session = TerminalSession()
        session.requestFocus(.authoritativeTerminal)
        let queuedGeneration = session.focusGeneration
        session.requestFocus(.composer)

        XCTAssertNotEqual(session.focusGeneration, queuedGeneration)
        XCTAssertEqual(session.focusTarget, .composer)
    }

    @MainActor
    func testSearchPresentationAdvancesFocusGenerationAndRestoresComposer() {
        let session = TerminalSession()
        defer { session.shutdown() }
        session.requestFocus(.composer)
        let composerGeneration = session.focusGeneration

        session.presentBlockSearch()

        XCTAssertTrue(session.isBlockSearchPresented)
        XCTAssertEqual(session.focusTarget, .none)
        XCTAssertGreaterThan(session.focusGeneration, composerGeneration)

        session.dismissBlockSearch()

        XCTAssertFalse(session.isBlockSearchPresented)
        XCTAssertEqual(session.focusTarget, .composer)
    }

    @MainActor
    func testDismissingSearchRestoresTheCompleteBlocksTimeline() {
        let session = TerminalSession()
        defer { session.shutdown() }
        session.submit(command: "echo visible block")
        XCTAssertEqual(session.visibleBlocks.map(\.id), session.blocks.map(\.id))

        session.presentBlockSearch()
        session.blockSearchText = "query-with-no-matches"
        XCTAssertTrue(session.visibleBlocks.isEmpty)

        session.dismissBlockSearch()

        XCTAssertFalse(session.isBlockSearchPresented)
        XCTAssertEqual(session.visibleBlocks.map(\.id), session.blocks.map(\.id))
    }

    @MainActor
    func testSearchFromFullTerminalReturnsToAuthoritativeTerminal() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }
        try await waitUntil("shell readiness before Full Terminal search", timeout: 5) {
            session.isShellReadyForInput
        }
        session.setMode(.terminal)
        XCTAssertEqual(session.mode, .terminal)

        session.presentBlockSearch()

        XCTAssertTrue(session.isBlockSearchPresented)
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertEqual(session.focusTarget, .none)

        session.dismissBlockSearch()

        XCTAssertFalse(session.isBlockSearchPresented)
        XCTAssertEqual(session.mode, .terminal)
        XCTAssertEqual(session.focusTarget, .authoritativeTerminal)
    }

    @MainActor
    func testAuthoritativeHostAppliesViewportInsetsWithoutRecreatingTerminal() {
        let terminal = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100)
        )
        let host = AuthoritativeTerminalHostView(terminalView: terminal)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)

        host.setViewportInsets(.fullTerminal)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.viewportInsets, .fullTerminal)
        XCTAssertEqual(terminal.frame, NSRect(x: 10, y: 8, width: 180, height: 84))

        host.setViewportInsets(.embeddedDirect)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.viewportInsets, .embeddedDirect)
        XCTAssertEqual(terminal.frame, NSRect(x: 6, y: 6, width: 188, height: 88))
        XCTAssertTrue(host.terminalView === terminal)
    }

    @MainActor
    func testMountLeaseRejectsLateOutgoingUpdateAndRepairsOnlyTerminalFocusIntent() async throws {
        let session = makeTestSession()
        let host = session.makeAuthoritativeTerminalHostView()
        let firstMount = AuthoritativeTerminalMountView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 160)
        )
        let secondMount = AuthoritativeTerminalMountView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )
        let searchField = NSSearchField(frame: NSRect(x: 0, y: 330, width: 200, height: 24))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        container.addSubview(firstMount)
        container.addSubview(secondMount)
        container.addSubview(searchField)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        try await waitUntil("shell readiness before terminal focus intent", timeout: 5) {
            session.isShellReadyForInput
        }
        session.setMode(.terminal)
        let firstLease = session.terminalMountCoordinator.issueLease(for: .fullTerminal)
        let secondLease = session.terminalMountCoordinator.issueLease(for: .fullTerminal)
        XCTAssertTrue(session.terminalMountCoordinator.present(lease: firstLease, in: firstMount))
        XCTAssertFalse(session.terminalMountCoordinator.present(lease: firstLease, in: firstMount))
        firstMount.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 2)
        let compactWindowSize = session.debugPTYWindowSize
        session.enterSecureInput()
        session.restoreAuthoritativeFocusAfterMount()
        await drainMainQueue(turns: 2)
        XCTAssertTrue(window.firstResponder === host.terminalView)
        AuthoritativeTerminalRenderInstrumentation.reset()
        session.restoreAuthoritativeFocusAfterMount()
        session.restoreAuthoritativeFocusAfterMount()
        await drainMainQueue(turns: 2)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.focusRepairAttempts, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.focusResponderChanges, 0)

        XCTAssertTrue(session.terminalMountCoordinator.present(lease: secondLease, in: secondMount))
        secondMount.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        session.restoreAuthoritativeFocusAfterMount()
        await drainMainQueue(turns: 2)
        XCTAssertTrue(window.firstResponder === host.terminalView)
        XCTAssertTrue(session.debugAuthoritativeTerminalView === host.terminalView)
        XCTAssertTrue(session.debugAuthoritativeHostView === host)
        XCTAssertGreaterThan(session.debugPTYWindowSize.ws_col, compactWindowSize.ws_col)
        XCTAssertGreaterThan(session.debugPTYWindowSize.ws_row, compactWindowSize.ws_row)
        XCTAssertGreaterThan(session.debugPTYWindowSize.ws_xpixel, compactWindowSize.ws_xpixel)
        XCTAssertGreaterThan(session.debugPTYWindowSize.ws_ypixel, compactWindowSize.ws_ypixel)
        let currentWindowSize = session.debugPTYWindowSize

        XCTAssertFalse(session.terminalMountCoordinator.present(lease: firstLease, in: firstMount))
        XCTAssertTrue(host.superview === secondMount)
        XCTAssertNil(firstMount.subviews.first { $0 === host })
        XCTAssertEqual(session.debugPTYWindowSize.ws_col, currentWindowSize.ws_col)
        XCTAssertEqual(session.debugPTYWindowSize.ws_row, currentWindowSize.ws_row)

        session.terminalMountCoordinator.release(lease: firstLease, from: firstMount)
        XCTAssertTrue(session.terminalMountCoordinator.isCurrent(lease: secondLease, mount: secondMount))
        let mismatchedLease = session.terminalMountCoordinator.issueLease(
            for: .embeddedDirect(blockID: UUID())
        )
        XCTAssertFalse(
            session.terminalMountCoordinator.present(
                lease: mismatchedLease,
                in: firstMount
            )
        )
        XCTAssertTrue(host.superview === secondMount)

        session.requestFocus(.composer)
        XCTAssertTrue(session.terminalMountCoordinator.isCurrent(lease: secondLease, mount: secondMount))
        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertFalse(session.terminalMountCoordinator.present(lease: firstLease, in: firstMount))
        session.restoreAuthoritativeFocusAfterMount()
        await drainMainQueue(turns: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(window.firstResponder === searchField.currentEditor())
    }

    func testTerminalMountRepairPolicyRateLimitsAndCapsAutomaticAttempts() {
        let now = Date()
        XCTAssertTrue(
            TerminalMountRepairPolicy.allowsAutomaticRepair(
                now: now,
                lastAttempt: nil,
                consecutiveFailures: 0
            )
        )
        XCTAssertFalse(
            TerminalMountRepairPolicy.allowsAutomaticRepair(
                now: now,
                lastAttempt: now.addingTimeInterval(-0.99),
                consecutiveFailures: 1
            )
        )
        XCTAssertTrue(
            TerminalMountRepairPolicy.allowsAutomaticRepair(
                now: now,
                lastAttempt: now.addingTimeInterval(-1),
                consecutiveFailures: 2
            )
        )
        XCTAssertFalse(
            TerminalMountRepairPolicy.allowsAutomaticRepair(
                now: now,
                lastAttempt: nil,
                consecutiveFailures: 3
            )
        )
        XCTAssertTrue(
            TerminalMountRepairPolicy.requiresRecoveryOverlay(
                consecutiveFailures: 3
            )
        )
    }

    @MainActor
    func testTerminalRepresentableUpdatePreservesSearchFieldFocus() async throws {
        let session = TerminalSession()
        session.ensureAuthoritativeTerminalIsRunning()
        try await waitUntil("shell readiness before mounted representable update", timeout: 5) {
            session.isShellReadyForInput
        }
        session.setMode(.terminal)
        let terminalHost = NSHostingView(
            rootView: TerminalViewRepresentable(
                session: session,
                placement: .fullTerminal
            )
        )
        let searchField = NSSearchField(frame: NSRect(x: 12, y: 212, width: 280, height: 28))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        terminalHost.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        container.addSubview(terminalHost)
        container.addSubview(searchField)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            session.shutdown()
        }

        container.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 3)
        XCTAssertTrue(window.makeFirstResponder(searchField))

        session.requestFocus(.none)
        AuthoritativeTerminalRenderInstrumentation.reset()
        session.commandDraft = "unrelated publication"
        await drainMainQueue(turns: 2)

        XCTAssertGreaterThan(
            AuthoritativeTerminalRenderInstrumentation.updateAttempts,
            0
        )
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.hostReparents, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.postMountCallbacks, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.ptyResizeAttempts, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.focusRepairAttempts, 0)
        XCTAssertTrue(window.firstResponder === searchField.currentEditor())
    }

    @MainActor
    func testPostMountRequestsCoalesceAndMountGenerationRedrawsOnce() async throws {
        let session = makeTestSession()
        session.ensureAuthoritativeTerminalIsRunning()
        defer { session.shutdown() }
        try await waitUntil("shell readiness before render coalescing", timeout: 5) {
            session.isShellReadyForInput
        }
        session.setMode(.terminal)

        let mount = AuthoritativeTerminalMountView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )
        let window = NSWindow(
            contentRect: mount.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = mount
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let firstLease = session.terminalMountCoordinator.issueLease(for: .fullTerminal)
        XCTAssertTrue(session.terminalMountCoordinator.present(lease: firstLease, in: mount))
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 3)

        AuthoritativeTerminalRenderInstrumentation.reset()
        window.setContentSize(NSSize(width: 800, height: 400))
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 3)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.postMountCallbacks, 1)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 1)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.ptyResizeAccepted, 1)

        AuthoritativeTerminalRenderInstrumentation.reset()
        mount.requestPostMountLayoutCallback(generation: 10_000)
        mount.requestPostMountLayoutCallback(generation: 10_000)
        mount.requestPostMountLayoutCallback(generation: 10_000)
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 3)

        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.postMountCallbacks, 1)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.ptyResizeAttempts, 0)

        mount.requestPostMountLayoutCallback(generation: 10_000)
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 2)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.postMountCallbacks, 1)

        AuthoritativeTerminalRenderInstrumentation.reset()
        let nextLease = session.terminalMountCoordinator.issueLease(for: .fullTerminal)
        XCTAssertFalse(session.terminalMountCoordinator.present(lease: nextLease, in: mount))
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 3)

        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.hostReparents, 0)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 1)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.ptyResizeAccepted, 0)
    }

    @MainActor
    func testRepeatedBufferActivationInvalidatesOncePerActualTransition() async {
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )
        AuthoritativeTerminalRenderInstrumentation.reset()

        terminalView.feed(text: "\u{001B}[?1049h")
        terminalView.feed(text: "\u{001B}[?1049h")
        await drainMainQueue(turns: 2)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 1)

        terminalView.feed(text: "\u{001B}[?1049l")
        terminalView.feed(text: "\u{001B}[?1049l")
        await drainMainQueue(turns: 2)
        XCTAssertEqual(AuthoritativeTerminalRenderInstrumentation.fullScreenInvalidations, 2)
    }

    @MainActor
    func testManualMountRepairPreservesTerminalAndPTYIdentity() async throws {
        let session = makeTestSession()
        session.ensureAuthoritativeTerminalIsRunning()
        defer { session.shutdown() }
        try await waitUntil("shell readiness before mount repair", timeout: 5) {
            session.isShellReadyForInput
        }
        session.setMode(.terminal)

        let mount = AuthoritativeTerminalMountView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )
        let window = NSWindow(
            contentRect: mount.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = mount
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let lease = session.terminalMountCoordinator.issueLease(for: .fullTerminal)
        XCTAssertTrue(session.terminalMountCoordinator.present(lease: lease, in: mount))
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 2)
        let terminal = session.makeAuthoritativeTerminalView()
        let host = session.makeAuthoritativeTerminalHostView()
        let ptyGeneration = session.debugProcessGeneration

        host.removeFromSuperview()
        XCTAssertNil(host.superview)
        session.repairTerminalView()
        mount.layoutSubtreeIfNeeded()
        await drainMainQueue(turns: 2)

        XCTAssertTrue(host.superview === mount)
        XCTAssertTrue(session.makeAuthoritativeTerminalView() === terminal)
        XCTAssertEqual(session.debugProcessGeneration, ptyGeneration)
        XCTAssertTrue(session.ptyController.isRunning)
    }

    @MainActor
    func testMountedRepresentableSurvivesTwoThousandDeterministicTransitions() async throws {
        let session = makeTestSession()
        session.ensureAuthoritativeTerminalIsRunning()
        defer { session.shutdown() }
        try await waitUntil("shell readiness before mounted transition stress", timeout: 5) {
            session.isShellReadyForInput
        }
        session.setMode(.terminal)
        let terminal = session.makeAuthoritativeTerminalView()
        let host = session.makeAuthoritativeTerminalHostView()
        let ptyGeneration = session.debugProcessGeneration
        let hostingView = NSHostingView(
            rootView: AnyView(
                TerminalViewRepresentable(session: session, placement: .fullTerminal)
                    .id(0)
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        for transition in 1...2_000 {
            hostingView.rootView = AnyView(
                TerminalViewRepresentable(session: session, placement: .fullTerminal)
                    .id(transition)
            )
            if transition.isMultiple(of: 2) {
                hostingView.frame.size = NSSize(width: 800, height: 480)
            } else {
                hostingView.frame.size = NSSize(width: 960, height: 600)
            }
            hostingView.layoutSubtreeIfNeeded()
            XCTAssertTrue(session.makeAuthoritativeTerminalView() === terminal)
            XCTAssertEqual(session.debugProcessGeneration, ptyGeneration)
            XCTAssertNotNil(host.superview)
        }
        await drainMainQueue(turns: 3)
        hostingView.layoutSubtreeIfNeeded()
        let health = session.terminalMountCoordinator.healthSnapshot()
        XCTAssertTrue(health.isHealthy)
        XCTAssertTrue(host.window === window)
        XCTAssertGreaterThan(terminal.bounds.width, 0)
        XCTAssertGreaterThan(terminal.bounds.height, 0)
        XCTAssertEqual(session.terminalMountCoordinator.terminalIdentityChangeCount, 0)
        XCTAssertEqual(session.terminalMountCoordinator.ptyGenerationChangeCount, 0)
    }

    @MainActor
    func testCopyOutputAndCombinedCopySanitizeBearerTokens() async throws {
        let session = makeTestSession()
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }
        let secret = "pane-output-secret-1234567890"
        let command = "printf 'Authorization: Bearer (secret)\\n'"

        session.submit(command: command)
        try await waitUntil("secret-bearing output to complete", timeout: 5) {
            session.blocks.contains { block in
                guard block.command == command else { return false }
                if case .completed = block.state { return true }
                return false
            }
        }
        let block = try XCTUnwrap(session.blocks.first { $0.command == command })

        session.copyOutput(id: block.id)
        let outputCopy = NSPasteboard.general.string(forType: .string) ?? ""
        session.copyCommandAndOutput(id: block.id)
        let combinedCopy = NSPasteboard.general.string(forType: .string) ?? ""

        XCTAssertFalse(outputCopy.contains(secret))
        XCTAssertFalse(combinedCopy.contains(secret))
        XCTAssertFalse(outputCopy.isEmpty)
        XCTAssertFalse(combinedCopy.isEmpty)
    }

    @MainActor
    func testRestartPersistsActiveCommandAsInterruptedWithStableIDAndOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-RestartPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let controller = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: persistenceTestConfiguration
        )
        let session = TerminalSession(
            shellConfiguration: testShellConfiguration,
            runtimeStateController: controller
        )
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }
        let command = "printf 'PANE_BEFORE_RESTART\\n'; sleep 10"

        session.submit(command: command)
        try await waitUntil("restart command to become active", timeout: 5) {
            session.activeCommandBlock?.command == command
                && session.activeCommandBlock?.state == .running
        }
        let blockID = try XCTUnwrap(session.activeCommandBlock?.id)
        session.restartShell()
        session.restartShell()
        XCTAssertTrue(session.isRestartInProgress)
        XCTAssertEqual(session.shellReadiness, .starting)
        XCTAssertFalse(session.isShellReadyForInput)
        try await waitUntil("restart finalization", timeout: 5) {
            session.lastShellRestartAt != nil && !session.isRestartInProgress
        }
        try await waitUntil("restarted shell initialization", timeout: 5) {
            session.isShellReadyForInput
        }

        let context = try await SQLiteRuntimeStateStore(databaseURL: databaseURL)
            .loadRecentContext(workspaceID: nil, repositoryID: nil, limit: 20)
        let matchingEvents = context.commandEvents.filter { $0.blockID == blockID }
        let event = try XCTUnwrap(matchingEvents.first)
        XCTAssertEqual(matchingEvents.count, 1)
        XCTAssertEqual(event.completion, .interrupted)
        XCTAssertEqual(event.command, command)
        XCTAssertTrue(event.sanitizedOutputSummary?.contains("PANE_BEFORE_RESTART") == true)
        XCTAssertEqual(event.outputKind, .excerpt)
    }

    @MainActor
    func testCommandAndRestartExposeCrashSimulationCheckpoints() async throws {
        let recorder = SessionLifecycleCheckpointRecorder()
        let session = TerminalSession(
            shellConfiguration: testShellConfiguration,
            lifecycleFaultCheckpointHandler: { recorder.record($0) }
        )
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }

        try await waitUntil("fault-checkpoint shell readiness", timeout: 5) {
            session.isShellReadyForInput
        }
        let command = "printf 'PANE_FAULT_CHECKPOINT_COMMAND\\n'"
        session.submit(command: command)
        try await waitUntil("fault-checkpoint command completion", timeout: 5) {
            session.blocks.contains {
                $0.command == command && $0.isFinalized
            }
        }
        XCTAssertTrue(
            recorder.containsInOrder([
                .commandFinalizationStarted,
                .commandFinalizationCompleted,
            ])
        )

        let previousGeneration = session.debugSnapshot.processGeneration
        session.restartShell()
        try await waitUntil("fault-checkpoint shell restart", timeout: 5) {
            session.debugSnapshot.processGeneration > previousGeneration
                && session.isShellReadyForInput
        }
        XCTAssertTrue(
            recorder.containsInOrder([
                .shellRestartRequested,
                .interruptedCommandFinalizationStarted,
                .shellRestartCommandFinalized,
                .shellRestartPTYTerminated,
                .shellRestartStartingReplacement,
            ])
        )
    }

    @MainActor
    func testApplicationExitPersistsSensitiveCommandAsNonRerunnablePlaceholder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-SensitiveExit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let controller = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: persistenceTestConfiguration
        )
        let session = TerminalSession(
            shellConfiguration: testShellConfiguration,
            runtimeStateController: controller
        )
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        let secret = "pane-sensitive-exit-1234567890"
        let command = "OPENAI_API_KEY=(secret) sleep 10"

        session.submit(command: command)
        try await waitUntil("sensitive command to become active", timeout: 5) {
            session.activeCommandBlock?.command == command
                && session.activeCommandBlock?.state == .running
        }
        let blockID = try XCTUnwrap(session.activeCommandBlock?.id)
        await session.finalizeApplicationExit()

        let context = try await SQLiteRuntimeStateStore(databaseURL: databaseURL)
            .loadRecentContext(workspaceID: nil, repositoryID: nil, limit: 20)
        let event = try XCTUnwrap(context.commandEvents.first { $0.blockID == blockID })
        XCTAssertEqual(event.completion, .interrupted)
        XCTAssertEqual(event.command, "[Sensitive command interrupted]")
        XCTAssertNil(event.sanitizedOutputSummary)
        XCTAssertEqual(event.outputKind, .none)
        XCTAssertFalse(String(describing: context).contains(secret))
        let persistedBytes = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).reduce(into: Data()) { bytes, url in
            bytes.append(try Data(contentsOf: url))
        }
        XCTAssertFalse(String(decoding: persistedBytes, as: UTF8.self).contains(secret))

        let restoredSession = TerminalSession()
        restoredSession.restoreRuntimeContext(
            context,
            restoreCommandHistory: true,
            restoreVisibleBlocks: true
        )
        let restoredBlock = try XCTUnwrap(restoredSession.blocks.first { $0.id == blockID })
        XCTAssertFalse(restoredBlock.isRerunnable)
        restoredSession.copyCommandAndOutput(id: blockID)
        XCTAssertFalse((NSPasteboard.general.string(forType: .string) ?? "").contains(secret))
    }

    @MainActor
    func testControlledShutdownPersistsActiveCommandOnceAndRejectsSubmissions() async throws {
        let ephemeralStore = InMemoryRuntimeStateStore()
        var configuration = persistenceTestConfiguration
        configuration.persistenceEnabled = false
        let controller = RuntimeStateController(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unused-\(UUID().uuidString).sqlite"),
            configuration: configuration,
            ephemeralStore: ephemeralStore
        )
        let session = TerminalSession(
            shellConfiguration: testShellConfiguration,
            runtimeStateController: controller
        )
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        let command = "printf 'PANE_BEFORE_SHUTDOWN\\n'; sleep 10"

        session.submit(command: command)
        try await waitUntil("shutdown command to become active", timeout: 5) {
            session.activeCommandBlock?.command == command
                && session.activeCommandBlock?.state == .running
        }
        let blockID = try XCTUnwrap(session.activeCommandBlock?.id)
        session.shutdown()
        session.shutdown()
        session.submit(command: "echo must-not-run")
        XCTAssertTrue(session.isShuttingDown)
#if DEBUG
        // PTY teardown is synchronous with closing the tab; persistence is
        // deliberately allowed to finish asynchronously afterward.
        XCTAssertFalse(session.debugHasProcessReference)
#endif
        try await waitUntil("controlled shutdown finalization", timeout: 5) {
            !session.isShellRunning && session.debugShutdownCompleted
        }

        let context = try await ephemeralStore.loadRecentContext(
            workspaceID: nil, repositoryID: nil, limit: 20
        )
        let matchingEvents = context.commandEvents.filter { $0.blockID == blockID }
        XCTAssertEqual(matchingEvents.count, 1)
        XCTAssertEqual(matchingEvents.first?.completion, .interrupted)
        XCTAssertFalse(session.blocks.contains { $0.command == "echo must-not-run" })
    }

    @MainActor
    func testUnexpectedShellExitPersistsActiveCommandAsInterrupted() async throws {
        let ephemeralStore = InMemoryRuntimeStateStore()
        var configuration = persistenceTestConfiguration
        configuration.persistenceEnabled = false
        let controller = RuntimeStateController(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("unused-\(UUID().uuidString).sqlite"),
            configuration: configuration,
            ephemeralStore: ephemeralStore
        )
        let session = TerminalSession(
            shellConfiguration: testShellConfiguration,
            runtimeStateController: controller
        )
        let terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }
        let command = "printf 'PANE_BEFORE_SHELL_EXIT\\n'; kill -KILL $$"

        session.submit(command: command)
        try await waitUntil("shell process to exit", timeout: 5) {
            !session.isShellRunning && session.shellExitStatus != nil
        }
        let blockID = try XCTUnwrap(session.blocks.first { $0.command == command }?.id)
        var persistedEvent: PersistedCommandEvent?
        let persistenceDeadline = Date().addingTimeInterval(5)
        while persistedEvent == nil, Date() < persistenceDeadline {
            let context = try await ephemeralStore.loadRecentContext(
                workspaceID: nil, repositoryID: nil, limit: 20
            )
            persistedEvent = context.commandEvents.first { event in
                event.blockID == blockID && event.completion == .interrupted
            }
            if persistedEvent == nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        XCTAssertNotNil(persistedEvent, "Expected shell-exit event persistence")

        let finalizedBlock = try XCTUnwrap(session.blocks.first { $0.id == blockID })
        if case .interrupted(let exitCode) = finalizedBlock.state {
            XCTAssertEqual(exitCode, 137)
        } else {
            XCTFail("Expected interrupted shell-exit block")
        }
    }

    @MainActor
    func testSecureInputFocusIntentOverridesAndSafelyReturnsToComposer() async throws {
        let session = makeTestSession()
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        defer { session.shutdown() }
        try await waitUntil("shell initialization before focus transition", timeout: 5) {
            session.isShellReadyForInput
        }
        session.requestFocus(.composer)

        session.enterSecureInput()
        XCTAssertEqual(session.focusTarget, .authoritativeTerminal)
        XCTAssertEqual(session.inputRequirement, .secure)

        session.exitSecureInput()
        XCTAssertEqual(session.focusTarget, .composer)
        XCTAssertEqual(session.mode, .blocks)
        XCTAssertEqual(session.inputRequirement, .shellIdle)
    }

    @MainActor
    private var testShellConfiguration: ShellConfiguration {
        ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
    }

    private func finalSuggestions(
        from updates: AsyncStream<[CommandAutocompleteSuggestion]>
    ) async -> [CommandAutocompleteSuggestion] {
        var suggestions: [CommandAutocompleteSuggestion] = []
        for await update in updates {
            suggestions = update
        }
        return suggestions
    }

    private var persistenceTestConfiguration: RuntimeStateConfiguration {
        RuntimeStateConfiguration(
            persistenceEnabled: true,
            commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        )
    }
}

@MainActor
private final class SessionLifecycleCheckpointRecorder {
    private(set) var checkpoints: [PaneLifecycleFaultCheckpoint] = []

    func record(_ checkpoint: PaneLifecycleFaultCheckpoint) {
        checkpoints.append(checkpoint)
    }

    func containsInOrder(
        _ expected: [PaneLifecycleFaultCheckpoint]
    ) -> Bool {
        var expectedIndex = expected.startIndex
        for checkpoint in checkpoints where expectedIndex < expected.endIndex {
            if checkpoint == expected[expectedIndex] {
                expected.formIndex(after: &expectedIndex)
            }
        }
        return expectedIndex == expected.endIndex
    }
}
