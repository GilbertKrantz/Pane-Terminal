import AppKit
import Darwin
import Foundation
@preconcurrency import SwiftTerm
import XCTest
@testable import Pane

final class TerminalCompatibilityTests: XCTestCase {
    func testEveryProtocolModeHasDeterministicMarkersAndExits() throws {
        let runner = try makeRunner()
        for mode in [
            "alternate-screen",
            "bracketed-paste",
            "progress",
            "unicode",
            "mouse",
            "resize",
            "osc-title",
            "sequences",
        ] {
            let result = try runner.run(mode)
            XCTAssertEqual(
                result.status,
                0,
                "\(mode): \(result.stderrString)"
            )
            XCTAssertTrue(
                result.stdoutString.contains("PANE_FIXTURE_READY"),
                mode
            )
            XCTAssertTrue(
                result.stdoutString.contains("PANE_FIXTURE_DONE"),
                mode
            )
        }
    }

    func testInteractiveProtocolModesReportTheExactAction() throws {
        let runner = try makeRunner()

        let alternate = try runner.run(
            "alternate-screen",
            arguments: ["--interactive"],
            inputAfterReady: Data("EXIT\n".utf8)
        )
        XCTAssertEqual(alternate.status, 0)
        XCTAssertTrue(
            alternate.stdoutString.contains(
                "PANE_FIXTURE_OBSERVED input=45584954"
            )
        )

        let paste = Data("one; echo two 漢字\n".utf8)
        let bracketedPaste = try runner.run(
            "bracketed-paste",
            arguments: ["--interactive"],
            inputAfterReady: paste
        )
        XCTAssertEqual(bracketedPaste.status, 0)
        XCTAssertTrue(
            bracketedPaste.stdoutString.contains(
                paste.dropLast().base64EncodedString()
            )
        )

        let mouseBytes = Data("\u{1B}[<0;12;4M\n".utf8)
        let mouse = try runner.run(
            "mouse",
            arguments: ["--interactive"],
            inputAfterReady: mouseBytes
        )
        XCTAssertEqual(mouse.status, 0)
        XCTAssertTrue(
            mouse.stdoutString.contains(mouseBytes.dropLast().hexString)
        )
    }

    func testResizeModeObservesSIGWINCHAndCleansUp() throws {
        let result = try makeRunner().run(
            "resize",
            arguments: ["--interactive"],
            inputAfterReady: Data("EXIT\n".utf8),
            signalAfterReady: SIGWINCH
        )

        XCTAssertEqual(result.status, 0, result.stderrString)
        XCTAssertTrue(result.stdoutString.contains("PANE_FIXTURE_OBSERVED resize="))
        XCTAssertTrue(result.stdoutString.contains("PANE_FIXTURE_DONE"))
    }

    func testUnicodeModePreservesCompleteGraphemeSequences() throws {
        let result = try makeRunner().run("unicode")
        for sequence in ["漢字", "e\u{301}", "✈️", "👍🏽", "👩‍💻", "אבג"] {
            XCTAssertTrue(result.stdoutString.contains(sequence), sequence)
        }
        XCTAssertNotNil(String(data: result.stdout, encoding: .utf8))
    }

    func testLargeOutputLineCountAndMarkers() throws {
        let result = try makeRunner().run(
            "output",
            arguments: ["--lines", "10000"]
        )

        XCTAssertEqual(result.status, 0, result.stderrString)
        XCTAssertEqual(
            result.stdoutString.components(
                separatedBy: "pane deterministic output"
            ).count - 1,
            10_000
        )
        XCTAssertTrue(result.stdoutString.hasSuffix("PANE_FIXTURE_DONE\r\n"))
    }

    func testInvalidUTF8FixtureRetainsBytesAndCompletes() throws {
        let result = try makeRunner().run(
            "output",
            arguments: ["--mode", "invalid-utf8"]
        )

        XCTAssertEqual(result.status, 0, result.stderrString)
        XCTAssertNotNil(result.stdout.range(of: Data([0xFF, 0xFE])))
        XCTAssertTrue(result.stdoutString.contains("PANE_FIXTURE_DONE"))
    }

    func testContinuousTenMegabyteFixtureWhenLargeSuiteEnabled() throws {
        guard ProcessInfo.processInfo.environment[
            "PANE_RUN_LARGE_COMPATIBILITY"
        ] == "1" else {
            throw XCTSkip("Enable in nightly CI with PANE_RUN_LARGE_COMPATIBILITY=1")
        }

        let byteCount = 10_000_000
        let result = try makeRunner().run(
            "output",
            arguments: ["--mode", "continuous", "--bytes", "\(byteCount)"]
        )

        XCTAssertEqual(result.status, 0, result.stderrString)
        XCTAssertGreaterThanOrEqual(result.stdout.count, byteCount)
        XCTAssertTrue(result.stdoutString.contains("PANE_FIXTURE_DONE"))
    }

    func testCompatibilityResultRoundTripsWithoutLosingDuration() throws {
        let value = TerminalCompatibilityResult(
            fixtureID: "unicode",
            applicationName: "pane-fixture",
            passed: false,
            duration: .milliseconds(125),
            failureCategory: .rendering,
            diagnostic: "stage=render"
        )
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(
            TerminalCompatibilityResult.self,
            from: encoded
        )

        XCTAssertEqual(decoded, value)
    }

    private func makeRunner() throws -> FixtureProcessRunner {
        FixtureProcessRunner(
            fixtureURL: try FixtureLocator.paneFixture(
                testCase: TerminalCompatibilityTests.self
            )
        )
    }
}

final class PaneConnectedCompatibilityTests: XCTestCase {
    @MainActor
    func testLocalSSHThroughPanePTYStaysSessionLocalAndExitsCleanly() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else {
            throw XCTSkip(
                "Local SSH fixture requires /usr/sbin/sshd, /usr/bin/ssh, and /usr/bin/ssh-keygen"
            )
        }

        let sshFixture: LocalSSHFixture
        do {
            sshFixture = try LocalSSHFixture.start()
        } catch let unavailable as LocalSSHFixture.Unavailable {
            throw XCTSkip(unavailable.diagnostic)
        }
        defer { _ = sshFixture.cleanup() }

        let sshSession = try PaneSessionHarness()
        let peerSession = try PaneSessionHarness()
        addTeardownBlock {
            await sshSession.cleanup()
            await peerSession.cleanup()
        }
        try await sshSession.waitUntil("SSH session zsh readiness") {
            sshSession.session.isShellReadyForInput
        }
        try await peerSession.waitUntil("peer session zsh readiness") {
            peerSession.session.isShellReadyForInput
        }

        sshSession.session.visibilityState = .selected
        peerSession.session.visibilityState = .background
        let sshView = sshSession.session.debugAuthoritativeTerminalView
        let peerMarker = "PANE_SSH_PEER_\(UUID().uuidString)"
        peerSession.session.submit(
            command: "/usr/bin/printf '%s\\n' \(shellQuote(peerMarker))"
        )
        let peerBlock = try await peerSession.waitForCompletedBlock(
            containing: peerMarker
        )

        let remoteMarker = "PANE_SSH_REMOTE_\(UUID().uuidString)"
        let remoteCommand = [
            "/usr/bin/ssh",
            "-F", "/dev/null",
            "-i", sshFixture.clientKeyURL.path,
            "-p", "\(sshFixture.port)",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(sshFixture.knownHostsURL.path)",
            "\(sshFixture.username)@127.0.0.1",
            "/usr/bin/printf 'PANE_SSH_FIXTURE_READY\\n\(remoteMarker)\\nPANE_SSH_FIXTURE_DONE\\n'",
        ].map(shellQuote).joined(separator: " ")

        sshSession.session.submit(command: remoteCommand)
        let sshBlock = try await sshSession.waitForCompletedCommand(
            remoteCommand,
            timeout: 5
        )

        if sshBlock.output.localizedCaseInsensitiveContains(
            "operation not permitted"
        ) {
            throw XCTSkip(
                "Loopback SSH client is unavailable in this test environment: \(sshBlock.output)"
            )
        }
        XCTAssertTrue(
            sshBlock.output.contains("PANE_SSH_FIXTURE_READY"),
            sshBlock.output
        )
        XCTAssertTrue(sshBlock.output.contains(remoteMarker), sshBlock.output)
        XCTAssertTrue(
            sshBlock.output.contains("PANE_SSH_FIXTURE_DONE"),
            sshBlock.output
        )
        XCTAssertFalse(sshBlock.output.contains(peerMarker))
        XCTAssertFalse(peerBlock.output.contains(remoteMarker))
        XCTAssertTrue(
            sshSession.session.debugAuthoritativeTerminalView === sshView
        )
        XCTAssertEqual(sshSession.session.inputRequirement, .shellIdle)
        XCTAssertEqual(sshSession.session.focusTarget, .composer)
        if case .completed(exitCode: 0) = sshBlock.state {
        } else {
            XCTFail("Local SSH command did not exit zero: \(sshBlock.output)")
        }
        XCTAssertTrue(
            sshFixture.cleanup(),
            "Local sshd survived SIGTERM/SIGKILL cleanup"
        )
    }

    @MainActor
    func testCleanShellMatrixRunsThroughPanePTY() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let workingDirectory = harness.temporaryHome
            .appendingPathComponent("basic interaction", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let command = [
            "export PANE_COMPAT_VALUE=ready",
            "cd \(shellQuote(workingDirectory.path))",
            "printf '%s\\n' \"$PANE_COMPAT_VALUE\" | /usr/bin/tr '[:lower:]' '[:upper:]'",
            "printf 'redirect-ok\\n' > pane-output.txt",
            "/bin/zsh -f -c 'printf \"nested-zsh\\\\n\"'",
            "/bin/bash --noprofile --norc -c 'printf \"clean-bash\\\\n\"'",
            "/bin/cat pane-output.txt",
        ].joined(separator: "; ")

        harness.session.submit(command: command)
        let block = try await harness.waitForCompletedBlock(
            containing: "clean-bash"
        )

        XCTAssertTrue(block.output.contains("READY"))
        XCTAssertTrue(block.output.contains("nested-zsh"))
        XCTAssertTrue(block.output.contains("clean-bash"))
        XCTAssertTrue(block.output.contains("redirect-ok"))
        XCTAssertEqual(
            harness.session.currentDirectory,
            workingDirectory.path
        )
        if case .completed(exitCode: 0) = block.state {
        } else {
            XCTFail("clean shell compatibility command did not exit zero")
        }
    }

    @MainActor
    func testFixtureRunsThroughPanePTYAndAuthoritativeTerminal() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let authoritativeView = harness.session.debugAuthoritativeTerminalView
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let command = "/usr/bin/python3 \(shellQuote(fixture.path)) unicode"

        harness.session.submit(command: command)
        let block = try await harness.waitForCompletedBlock(
            containing: "PANE_FIXTURE_DONE"
        )

        XCTAssertTrue(block.output.contains("漢字"))
        XCTAssertTrue(block.output.contains("👩‍💻"))
        XCTAssertTrue(
            harness.session.debugAuthoritativeTerminalView === authoritativeView
        )
    }

    @MainActor
    func testAlternateScreenInputAndResizeStayOnPanePTY() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let command = [
            "/usr/bin/python3",
            shellQuote(fixture.path),
            "alternate-screen",
            "--interactive",
        ].joined(separator: " ")

        harness.session.submit(command: command)
        try await harness.waitUntil("alternate screen entry") {
            harness.session.isAlternateScreenActive
                && harness.session.inputRequirement == .direct
        }
        let authoritativeView = harness.terminalView
        authoritativeView.setFrameSize(NSSize(width: 1_000, height: 520))
        harness.session.sizeChanged(
            source: authoritativeView,
            newCols: authoritativeView.terminal.cols,
            newRows: authoritativeView.terminal.rows
        )
        let input = Array("EXIT\n".utf8)
        harness.session.send(source: authoritativeView, data: input[...])

        let block = try await harness.waitForCompletedBlock(
            containing: "PANE_FIXTURE_DONE"
        )
        try await harness.waitUntil("alternate screen exit") {
            !harness.session.isAlternateScreenActive
        }

        XCTAssertEqual(block.command, command)
        if case .completed(exitCode: 0) = block.state {
            // Completion is the deterministic acknowledgement: interactive
            // mode cannot emit DONE or exit until Pane routes EXIT to its PTY.
        } else {
            XCTFail("interactive alternate-screen fixture did not exit cleanly")
        }
        XCTAssertTrue(
            harness.session.debugAuthoritativeTerminalView === authoritativeView
        )
    }

    @MainActor
    func testBackgroundTerminalRejectsStaleUserInputAndClipboardCallbacks() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let command = [
            "/usr/bin/python3",
            shellQuote(fixture.path),
            "alternate-screen",
            "--interactive",
        ].joined(separator: " ")
        harness.session.submit(command: command)
        try await harness.waitUntil("alternate screen entry") {
            harness.session.isAlternateScreenActive
                && harness.session.inputRequirement == .direct
        }

        let terminalView = harness.terminalView
        harness.session.visibilityState = .background
        let staleInput = Array("WRONG-SESSION\n".utf8)
        harness.session.send(source: terminalView, data: staleInput[...])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        harness.session.clipboardCopy(
            source: terminalView,
            content: Data("must-not-copy".utf8)
        )
        XCTAssertNil(harness.session.clipboardRead(source: terminalView))
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "sentinel"
        )
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(harness.session.isAlternateScreenActive)

        harness.session.visibilityState = .selected
        let acceptedInput = Array("EXIT\n".utf8)
        harness.session.send(source: terminalView, data: acceptedInput[...])
        let block = try await harness.waitForCompletedBlock(
            containing: "PANE_FIXTURE_DONE"
        )

        if case .completed(exitCode: 0) = block.state {
            // The fixture reads only one newline-terminated action. Remaining
            // active after the hidden-tab write and completing only after the
            // selected-tab EXIT proves the stale callback was rejected.
        } else {
            XCTFail("selected terminal input did not complete the fixture")
        }
    }

    @MainActor
    func testBracketedPasteUsesSelectedPaneTerminalOnly() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let command = [
            "/usr/bin/python3",
            shellQuote(fixture.path),
            "bracketed-paste",
            "--interactive",
        ].joined(separator: " ")
        harness.session.submit(command: command)
        try await harness.waitUntil("bracketed paste mode") {
            harness.terminalView.terminal.bracketedPasteMode
                && harness.session.inputRequirement == .direct
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("WRONG BACKGROUND PASTE", forType: .string)
        harness.session.visibilityState = .background
        harness.terminalView.paste(harness.terminalView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(harness.session.isCommandActive)

        let payload = "one; echo two 漢字"
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        harness.session.visibilityState = .selected
        harness.terminalView.paste(harness.terminalView)
        let newline = Array("\n".utf8)
        harness.session.send(
            source: harness.terminalView,
            data: newline[...]
        )
        let block = try await harness.waitForCompletedCommand(command)
        let expectedBytes = Data(
            EscapeSequences.bracketedPasteStart
                + Array(payload.utf8)
                + EscapeSequences.bracketedPasteEnd
        )

        XCTAssertTrue(
            block.output.contains(expectedBytes.base64EncodedString())
        )
        XCTAssertFalse(block.output.contains("WRONG"))
    }

    @MainActor
    func testMouseReportingRejectsStaleBackgroundEvent() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let command = [
            "/usr/bin/python3",
            shellQuote(fixture.path),
            "mouse",
            "--interactive",
        ].joined(separator: " ")
        harness.session.submit(command: command)
        try await harness.waitUntil("mouse reporting mode") {
            harness.session.inputRequirement == .direct
        }

        let backgroundEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 20, y: 20),
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        harness.session.visibilityState = .background
        harness.terminalView.mouseDown(with: backgroundEvent)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(harness.session.isCommandActive)

        let selectedEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 120, y: 80),
                modifierFlags: [],
                timestamp: 2,
                windowNumber: 0,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )
        harness.session.visibilityState = .selected
        harness.terminalView.mouseDown(with: selectedEvent)
        let newline = Array("\n".utf8)
        harness.session.send(
            source: harness.terminalView,
            data: newline[...]
        )
        let block = try await harness.waitForCompletedCommand(command)

        XCTAssertTrue(block.output.contains("PANE_FIXTURE_OBSERVED mouse-hex=1b5b3c"))
        XCTAssertEqual(
            block.output.components(separatedBy: "1b5b3c").count - 1,
            1
        )
    }

    @MainActor
    func testLargeOutputThroughBackgroundPaneSessionStaysIsolated() async throws {
        let selected = try PaneSessionHarness()
        let background = try PaneSessionHarness()
        addTeardownBlock {
            await selected.cleanup()
            await background.cleanup()
        }
        try await selected.waitUntil("selected zsh readiness") {
            selected.session.isShellReadyForInput
        }
        try await background.waitUntil("background zsh readiness") {
            background.session.isShellReadyForInput
        }
        selected.session.visibilityState = .selected
        background.session.visibilityState = .background
        let selectedView = selected.session.debugAuthoritativeTerminalView
        let backgroundView = background.session.debugAuthoritativeTerminalView
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let outputCommand = [
            "/usr/bin/python3",
            shellQuote(fixture.path),
            "output",
            "--lines",
            "10000",
        ].joined(separator: " ")
        background.session.submit(command: outputCommand)

        let foregroundMarker = "PANE_SELECTED_DURING_BACKGROUND_OUTPUT"
        selected.session.submit(
            command: "/usr/bin/printf '%s\\n' \(shellQuote(foregroundMarker))"
        )
        let selectedBlock = try await selected.waitForCompletedBlock(
            containing: foregroundMarker
        )
        let backgroundBlock = try await background.waitForCompletedCommand(
            outputCommand,
            timeout: 15
        )

        XCTAssertTrue(selectedBlock.output.contains(foregroundMarker))
        XCTAssertFalse(selectedBlock.output.contains("pane deterministic output"))
        XCTAssertTrue(backgroundBlock.output.contains("PANE_FIXTURE_DONE"))
        XCTAssertFalse(backgroundBlock.output.contains(foregroundMarker))
        XCTAssertEqual(backgroundBlock.outputKind, .excerpt)
        XCTAssertLessThanOrEqual(
            backgroundBlock.output.utf8.count,
            ScrollbackPolicy.standard.excerptByteLimit
        )
        XCTAssertTrue(
            selected.session.debugAuthoritativeTerminalView === selectedView
        )
        XCTAssertTrue(
            background.session.debugAuthoritativeTerminalView === backgroundView
        )
    }

    @MainActor
    func testSystemVimEditsAcrossAlternateScreenAndExitsCleanly() async throws {
        let vim = URL(fileURLWithPath: "/usr/bin/vim")
        guard FileManager.default.isExecutableFile(atPath: vim.path) else {
            throw XCTSkip("System Vim is unavailable")
        }
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let editedFile = harness.temporaryHome.appendingPathComponent("vim-fixture.txt")
        let command = "\(vim.path) -Nu NONE -n -i NONE \(shellQuote(editedFile.path))"
        harness.session.submit(command: command)
        try await harness.waitUntil("Vim alternate screen") {
            harness.session.isAlternateScreenActive
        }
        let input = Array("iPane Vim fixture\u{1B}:wq\r".utf8)
        harness.session.send(source: harness.terminalView, data: input[...])

        let block = try await harness.waitForCompletedCommand(command, timeout: 8)

        XCTAssertEqual(
            try String(contentsOf: editedFile, encoding: .utf8),
            "Pane Vim fixture\n"
        )
        if case .completed(exitCode: 0) = block.state {
        } else {
            XCTFail("Vim did not exit cleanly")
        }
    }

    @MainActor
    func testLessAndPythonREPLPreserveDirectInputAndReturnToComposer() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/less"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("less or Python is unavailable")
        }
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }

        let lessInput = harness.temporaryHome.appendingPathComponent("less-fixture.txt")
        try (0..<200).map { "line-\($0)" }
            .joined(separator: "\n")
            .write(to: lessInput, atomically: true, encoding: .utf8)
        let lessCommand = "/usr/bin/less \(shellQuote(lessInput.path))"
        harness.session.submit(command: lessCommand)
        try await harness.waitUntil("less direct input") {
            harness.session.isAlternateScreenActive
                || harness.session.inputRequirement == .direct
        }
        let quit = Array("q".utf8)
        harness.session.send(source: harness.terminalView, data: quit[...])
        _ = try await harness.waitForCompletedCommand(lessCommand)

        let pythonCommand = "/usr/bin/python3 -q"
        harness.session.submit(command: pythonCommand)
        try await harness.waitUntil("Python REPL direct input") {
            harness.session.inputRequirement == .direct
        }
        let pythonInput = Array(
            "print('PANE_PYTHON_REPL')\nexit()\n".utf8
        )
        harness.session.send(
            source: harness.terminalView,
            data: pythonInput[...]
        )
        let pythonBlock = try await harness.waitForCompletedCommand(
            pythonCommand
        )

        XCTAssertTrue(pythonBlock.output.contains("PANE_PYTHON_REPL"))
        XCTAssertEqual(harness.session.inputRequirement, .shellIdle)
        XCTAssertEqual(harness.session.focusTarget, .composer)
    }

    @MainActor
    func testNodeAndSQLiteREPLsPreserveSessionLocalInput() async throws {
        guard let node = firstExecutable([
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]) else {
            throw XCTSkip("Node is unavailable")
        }
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/sqlite3"
        ) else {
            throw XCTSkip("SQLite is unavailable")
        }
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }

        let nodeCommand = "\(shellQuote(node.path)) --interactive"
        harness.session.submit(command: nodeCommand)
        try await harness.waitUntil("Node REPL direct input") {
            harness.session.inputRequirement == .direct
        }
        let nodeInput = Array(
            "console.log('PANE_NODE_REPL')\n.exit\n".utf8
        )
        harness.session.send(
            source: harness.terminalView,
            data: nodeInput[...]
        )
        let nodeBlock = try await harness.waitForCompletedCommand(
            nodeCommand,
            timeout: 8
        )
        XCTAssertTrue(nodeBlock.output.contains("PANE_NODE_REPL"))
        XCTAssertEqual(harness.session.focusTarget, .composer)

        let sqliteCommand = "/usr/bin/sqlite3 ':memory:'"
        harness.session.submit(command: sqliteCommand)
        try await harness.waitUntil("SQLite direct input") {
            harness.session.isCommandActive
                && harness.session.inputRequirement == .direct
        }
        let sqliteInput = Array(
            "select 'PANE_SQLITE_REPL';\n.quit\n".utf8
        )
        harness.session.send(
            source: harness.terminalView,
            data: sqliteInput[...]
        )
        let sqliteBlock = try await harness.waitForCompletedCommand(
            sqliteCommand
        )

        XCTAssertTrue(sqliteBlock.output.contains("PANE_SQLITE_REPL"))
        XCTAssertEqual(harness.session.inputRequirement, .shellIdle)
        XCTAssertEqual(harness.session.focusTarget, .composer)
    }

    @MainActor
    func testSystemManAndTopExitWithoutTerminalStateCorruption() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/man"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/top"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/less") else {
            throw XCTSkip("man, top, or less is unavailable")
        }
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }

        let manCommand = "MANPAGER='/usr/bin/less -R' /usr/bin/man 1 ls"
        harness.session.submit(command: manCommand)
        try await harness.waitUntil("man pager direct input", timeout: 8) {
            harness.session.isAlternateScreenActive
                || harness.session.inputRequirement == .direct
        }
        let quit = Array("q".utf8)
        harness.session.send(
            source: harness.terminalView,
            data: quit[...]
        )
        _ = try await harness.waitForCompletedCommand(manCommand, timeout: 8)
        XCTAssertEqual(harness.session.focusTarget, .composer)

        let topCommand = "/usr/bin/top -s 1"
        harness.session.submit(command: topCommand)
        try await harness.waitUntil("top direct input", timeout: 8) {
            harness.session.isAlternateScreenActive
                || harness.session.inputRequirement == .direct
        }
        harness.session.send(
            source: harness.terminalView,
            data: quit[...]
        )
        _ = try await harness.waitForCompletedCommand(topCommand, timeout: 8)

        XCTAssertFalse(harness.session.isAlternateScreenActive)
        XCTAssertEqual(harness.session.inputRequirement, .shellIdle)
        XCTAssertEqual(harness.session.focusTarget, .composer)
    }

    @MainActor
    func testPanePTYResizeDeliversSIGWINCHToInteractiveFixture() async throws {
        let harness = try PaneSessionHarness()
        addTeardownBlock { await harness.cleanup() }
        try await harness.waitUntil("clean zsh readiness") {
            harness.session.isShellReadyForInput
        }
        let fixture = try FixtureLocator.paneFixture(
            testCase: PaneConnectedCompatibilityTests.self
        )
        let command = [
            "/usr/bin/python3",
            shellQuote(fixture.path),
            "resize",
            "--interactive",
        ].joined(separator: " ")
        harness.session.submit(command: command)
        try await harness.waitUntil("resize fixture direct input") {
            harness.session.inputRequirement == .direct
        }

        harness.terminalView.setFrameSize(
            NSSize(width: 1_040, height: 560)
        )
        harness.terminalView.terminal.resize(cols: 120, rows: 40)
        harness.session.sizeChanged(
            source: harness.terminalView,
            newCols: harness.terminalView.terminal.cols,
            newRows: harness.terminalView.terminal.rows
        )
        try await Task.sleep(for: .milliseconds(100))
        let exit = Array("EXIT\n".utf8)
        harness.session.send(source: harness.terminalView, data: exit[...])
        let block = try await harness.waitForCompletedCommand(command)

        XCTAssertTrue(block.output.contains("PANE_FIXTURE_OBSERVED resize="))
        XCTAssertTrue(block.output.contains("PANE_FIXTURE_DONE"))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func firstExecutable(_ paths: [String]) -> URL? {
        paths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }
    }
}

final class WorkspaceStressTests: XCTestCase {
    func testBaselineConfigurationMatchesReleaseContract() {
        let value = WorkspaceStressConfiguration.baseline
        XCTAssertEqual(value.tabCount, 12)
        XCTAssertEqual(value.commandsPerTab, 20)
        XCTAssertEqual(value.switchCount, 500)
        XCTAssertEqual(value.closeCount, 6)
        XCTAssertEqual(value.duration, .seconds(300))
    }
}

final class LargeOutputTests: XCTestCase {
    func testScrollbackPolicyIsSessionBounded() {
        let policy = ScrollbackPolicy.standard
        XCTAssertLessThanOrEqual(
            policy.excerptByteLimit,
            policy.retainedOutputByteLimit
        )
        XCTAssertGreaterThan(policy.terminalLineLimit, 0)
        XCTAssertGreaterThan(policy.finalizedBlockLimit, 0)
    }
}

@MainActor
private final class PaneSessionHarness {
    let session: TerminalSession
    let terminalView: PaneTerminalView
    let temporaryHome: URL

    init() throws {
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaneCompatibility-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryHome,
            withIntermediateDirectories: true
        )
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": temporaryHome.path,
                "ZDOTDIR": temporaryHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            homeDirectory: temporaryHome
        )
        session = TerminalSession(shellConfiguration: configuration)
        terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
    }

    func cleanup() async {
        _ = await session.shutdownAndWait()
        session.detach(terminalView: terminalView)
        try? FileManager.default.removeItem(at: temporaryHome)
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out at stage=\(description)")
        throw FixtureExecutionError(
            stage: .action,
            mode: "pane-pty",
            diagnostic: description
        )
    }

    func waitForCompletedBlock(
        containing marker: String,
        timeout: TimeInterval = 5
    ) async throws -> CommandBlock {
        var result: CommandBlock?
        try await waitUntil("block completion containing \(marker)", timeout: timeout) {
            result = self.session.blocks.first { block in
                guard block.output.contains(marker) else { return false }
                if case .completed = block.state {
                    return true
                }
                return false
            }
            return result != nil
        }
        return try XCTUnwrap(result)
    }

    func waitForCompletedCommand(
        _ command: String,
        timeout: TimeInterval = 5
    ) async throws -> CommandBlock {
        var result: CommandBlock?
        try await waitUntil(
            "command completion for \(command)",
            timeout: timeout
        ) {
            result = self.session.blocks.first { block in
                guard block.command == command else { return false }
                return block.isFinalized
            }
            return result != nil
        }
        return try XCTUnwrap(result)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private final class LocalSSHFixture {
    struct Unavailable: Error {
        let diagnostic: String
    }

    let clientKeyURL: URL
    let knownHostsURL: URL
    let port: UInt16
    let username: String

    private let rootURL: URL
    private let server: Process
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let output = SSHLockedBuffer()
    private let errors = SSHLockedBuffer()
    private var cleanedUp = false

    private init(
        rootURL: URL,
        clientKeyURL: URL,
        knownHostsURL: URL,
        port: UInt16,
        username: String,
        server: Process,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) {
        self.rootURL = rootURL
        self.clientKeyURL = clientKeyURL
        self.knownHostsURL = knownHostsURL
        self.port = port
        self.username = username
        self.server = server
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
    }

    static func start() throws -> LocalSSHFixture {
        let startedAt = Date()
        let totalDeadline = startedAt.addingTimeInterval(20)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaneLocalSSH-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let hostKeyURL = rootURL.appendingPathComponent("host-ed25519")
            let clientKeyURL = rootURL.appendingPathComponent("client-ed25519")
            try runSetupProcess(
                "/usr/bin/ssh-keygen",
                arguments: [
                    "-q", "-t", "ed25519", "-N", "",
                    "-f", hostKeyURL.path,
                ],
                stage: "host-key",
                totalDeadline: totalDeadline
            )
            try runSetupProcess(
                "/usr/bin/ssh-keygen",
                arguments: [
                    "-q", "-t", "ed25519", "-N", "",
                    "-f", clientKeyURL.path,
                ],
                stage: "client-key",
                totalDeadline: totalDeadline
            )

            let authorizedKeysURL = rootURL.appendingPathComponent(
                "authorized_keys"
            )
            let clientPublicKeyURL = URL(
                fileURLWithPath: clientKeyURL.path + ".pub"
            )
            try Data(contentsOf: clientPublicKeyURL).write(
                to: authorizedKeysURL,
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: authorizedKeysURL.path
            )

            let port = try reserveLoopbackPort()
            let username = NSUserName()
            let configURL = rootURL.appendingPathComponent("sshd_config")
            let pidURL = rootURL.appendingPathComponent("sshd.pid")
            let config = """
            Port \(port)
            AddressFamily inet
            ListenAddress 127.0.0.1
            HostKey \(hostKeyURL.path)
            PidFile \(pidURL.path)
            AuthorizedKeysFile \(authorizedKeysURL.path)
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            ChallengeResponseAuthentication no
            PubkeyAuthentication yes
            UsePAM no
            PermitRootLogin no
            PermitEmptyPasswords no
            AllowUsers \(username)
            LogLevel VERBOSE
            """
            try config.write(
                to: configURL,
                atomically: true,
                encoding: .utf8
            )
            try runSetupProcess(
                "/usr/sbin/sshd",
                arguments: ["-t", "-f", configURL.path],
                stage: "configuration",
                totalDeadline: totalDeadline
            )

            let server = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            server.arguments = ["-D", "-e", "-f", configURL.path]
            server.environment = [
                "HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            server.standardOutput = outputPipe
            server.standardError = errorPipe
            let fixture = LocalSSHFixture(
                rootURL: rootURL,
                clientKeyURL: clientKeyURL,
                knownHostsURL: rootURL.appendingPathComponent("known_hosts"),
                port: port,
                username: username,
                server: server,
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    fixture.output.append(data)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    fixture.errors.append(data)
                }
            }

            do {
                try server.run()
            } catch {
                fixture.stopReading()
                try? FileManager.default.removeItem(at: rootURL)
                let diagnostic = "Local unprivileged sshd launch failed: \(error)"
                if isEnvironmentRestriction(diagnostic) {
                    throw Unavailable(diagnostic: diagnostic)
                }
                throw FixtureExecutionError(
                    stage: .startup,
                    mode: "local-ssh",
                    diagnostic: diagnostic
                )
            }
            guard Date().timeIntervalSince(startedAt) <= 5 else {
                fixture.cleanup()
                throw FixtureExecutionError(
                    stage: .startup,
                    mode: "local-ssh",
                    diagnostic: "sshd launch exceeded 5 seconds"
                )
            }

            let readinessDeadline = min(
                Date().addingTimeInterval(5),
                totalDeadline
            )
            while server.isRunning, Date() < readinessDeadline {
                if canConnectToLoopback(port: port) {
                    try writeKnownHost(
                        hostPublicKeyURL: URL(
                            fileURLWithPath: hostKeyURL.path + ".pub"
                        ),
                        port: port,
                        destination: fixture.knownHostsURL
                    )
                    return fixture
                }
                Thread.sleep(forTimeInterval: 0.01)
            }

            let diagnostic = fixture.serverDiagnostic
            fixture.cleanup()
            if isEnvironmentRestriction(diagnostic) {
                throw Unavailable(
                    diagnostic:
                        "Local unprivileged sshd is unavailable: \(diagnostic)"
                )
            }
            throw FixtureExecutionError(
                stage: .readiness,
                mode: "local-ssh",
                diagnostic: "loopback listener did not become ready; \(diagnostic)"
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    @discardableResult
    func cleanup() -> Bool {
        guard !cleanedUp else { return !server.isRunning }
        cleanedUp = true
        if server.isRunning {
            server.terminate()
        }
        let cleanupDeadline = Date().addingTimeInterval(2)
        let terminationDeadline = Date().addingTimeInterval(1.5)
        while server.isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if server.isRunning {
            _ = Darwin.kill(server.processIdentifier, SIGKILL)
        }
        while server.isRunning, Date() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if !server.isRunning {
            server.waitUntilExit()
        }
        stopReading()
        try? FileManager.default.removeItem(at: rootURL)
        return !server.isRunning
    }

    private var serverDiagnostic: String {
        let stdout = output.string
        let stderr = errors.string
        let status = server.isRunning
            ? "running"
            : String(server.terminationStatus)
        return "status=\(status) stdout=\(stdout) stderr=\(stderr)"
    }

    private func stopReading() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
    }

    private static func runSetupProcess(
        _ executable: String,
        arguments: [String],
        stage: String,
        totalDeadline: Date
    ) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "HOME": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw FixtureExecutionError(
                stage: .startup,
                mode: "local-ssh-\(stage)",
                diagnostic: String(describing: error)
            )
        }
        let deadline = min(Date().addingTimeInterval(5), totalDeadline)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            process.terminate()
            let cleanupDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < cleanupDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        guard !process.isRunning else {
            throw FixtureExecutionError(
                stage: .cleanup,
                mode: "local-ssh-\(stage)",
                diagnostic: "setup process survived bounded cleanup"
            )
        }
        process.waitUntilExit()
        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                decoding: stdout + stderr,
                as: UTF8.self
            )
            if isEnvironmentRestriction(diagnostic) {
                throw Unavailable(
                    diagnostic:
                        "Local SSH fixture \(stage) is unavailable: \(diagnostic)"
                )
            }
            throw FixtureExecutionError(
                stage: .startup,
                mode: "local-ssh-\(stage)",
                diagnostic: diagnostic
            )
        }
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            let diagnostic = String(cString: strerror(errno))
            if isEnvironmentRestriction(diagnostic) {
                throw Unavailable(
                    diagnostic:
                        "Loopback socket creation is unavailable: \(diagnostic)"
                )
            }
            throw FixtureExecutionError(
                stage: .startup,
                mode: "local-ssh-port",
                diagnostic: diagnostic
            )
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let diagnostic = String(cString: strerror(errno))
            if isEnvironmentRestriction(diagnostic) {
                throw Unavailable(
                    diagnostic:
                        "Loopback bind is unavailable: \(diagnostic)"
                )
            }
            throw FixtureExecutionError(
                stage: .startup,
                mode: "local-ssh-port",
                diagnostic: diagnostic
            )
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw FixtureExecutionError(
                stage: .startup,
                mode: "local-ssh-port",
                diagnostic: String(cString: strerror(errno))
            )
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func canConnectToLoopback(port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }

    private static func writeKnownHost(
        hostPublicKeyURL: URL,
        port: UInt16,
        destination: URL
    ) throws {
        let publicKey = try String(
            contentsOf: hostPublicKeyURL,
            encoding: .utf8
        )
        let fields = publicKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else {
            throw FixtureExecutionError(
                stage: .startup,
                mode: "local-ssh-known-host",
                diagnostic: "host public key is malformed"
            )
        }
        let entry = "[127.0.0.1]:\(port) \(fields[0]) \(fields[1])\n"
        try entry.write(
            to: destination,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func isEnvironmentRestriction(_ diagnostic: String) -> Bool {
        let value = diagnostic.lowercased()
        return value.contains("operation not permitted")
            || value.contains("permission denied")
            || value.contains("must be run as root")
            || value.contains("seteuid")
            || value.contains("setuid")
    }
}

private final class SSHLockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        lock.lock()
        data.append(value)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
