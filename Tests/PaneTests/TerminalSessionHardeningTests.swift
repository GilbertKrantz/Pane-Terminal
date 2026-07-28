import AppKit
import Foundation
import XCTest
@preconcurrency import SwiftTerm
@testable import Pane

final class TerminalSessionHardeningTests: XCTestCase {
    private static let secureFixture = "PANE_TEST_SECRET_8f26e91a"

    @MainActor
    func testTerminalSessionLifecycleStressMaintainsInvariants() async throws {
        let harness = try makeHarness(named: "lifecycle-stress")
        let session = harness.session
        let terminalView = harness.terminalView
        defer {
            session.shutdown()
            try? FileManager.default.removeItem(at: harness.root)
        }

        try await waitUntil("isolated zsh to become ready", session: session) {
            session.isShellReadyForInput
        }
        assertHealthySession(session)
        let terminalIdentity = try XCTUnwrap(session.debugAuthoritativeTerminalView)

        for index in 0..<16 {
            try await runCommand(
                "printf 'pane-stress-\(index)\\n'; sleep 0.02",
                marker: "pane-stress-\(index)",
                in: session
            )
            assertHealthySession(session)
            XCTAssertTrue(session.debugAuthoritativeTerminalView === terminalIdentity)
        }

        for index in 0..<4 {
            let command = "caffeinate"
            session.submit(command: command)
            try await waitUntil("interrupt fixture \(index) to run", session: session) {
                session.activeCommandBlock?.command == command
                    && session.activeCommandBlock?.state == .running
                    && session.debugForegroundProcessName == "caffeinate"
            }
            let interruptedBlockID = try XCTUnwrap(session.activeCommandBlock?.id)
            session.sendInterrupt()
            try await waitUntil("interrupt fixture \(index) to stop", session: session) {
                guard let block = session.blocks.first(where: { $0.id == interruptedBlockID }),
                      case .interrupted(exitCode: 130) = block.state else {
                    return false
                }
                return !session.isCommandActive
            }
            assertHealthySession(session)
            try await runCommand(
                "printf 'pane-post-interrupt-\(index)\\n'; sleep 0.02",
                marker: "pane-post-interrupt-\(index)",
                in: session
            )
        }

        for _ in 0..<6 {
            session.setMode(.terminal)
            XCTAssertEqual(session.interactionState, .fullTerminal)
            XCTAssertEqual(session.debugSnapshot.keyboardOwner, .authoritativeTerminal)
            XCTAssertEqual(session.debugSnapshot.terminalMount, .fullTerminal)

            session.setMode(.blocks)
            assertHealthySession(session)
            XCTAssertTrue(session.debugAuthoritativeTerminalView === terminalIdentity)
        }

        let directCommand = #"/bin/sh -c 'stty -icanon echo; printf "pane-direct-ready\n"; IFS= read -r pane_reply; stty sane'"#
        session.submit(command: directCommand)
        try await waitUntil("normal-buffer direct input", session: session, timeout: 8) {
            session.activeCommandBlock?.command == directCommand
                && session.interactionState == .commandRunningDirect
                && session.debugSnapshot.keyboardOwner == .authoritativeTerminal
        }
        session.setMode(.terminal)
        XCTAssertEqual(session.interactionState, .fullTerminal)
        XCTAssertEqual(session.debugSnapshot.keyboardOwner, .authoritativeTerminal)
        session.setMode(.blocks)
        XCTAssertEqual(session.interactionState, .commandRunningDirect)
        XCTAssertEqual(session.debugSnapshot.keyboardOwner, .authoritativeTerminal)
        terminalView.send(data: Array("direct-ok\n".utf8)[...])
        try await waitUntil("direct fixture to complete", session: session, timeout: 8) {
            guard let block = session.blocks.first(where: { $0.command == directCommand }),
                  case .completed(exitCode: 0) = block.state else {
                return false
            }
            return !session.isCommandActive && session.interactionState == .shellIdle
        }
        assertHealthySession(session)

        for mode in [47, 1047, 1049] {
            terminalView.feed(text: "\u{001B}[?\(mode)h")
            try await waitUntil("DEC \(mode) alternate screen entry", session: session) {
                session.debugSnapshot.alternateScreenActive
                    && session.interactionState == .alternateScreen
                    && session.debugSnapshot.keyboardOwner == .authoritativeTerminal
            }
            terminalView.feed(text: "\u{001B}[?\(mode)l")
            try await waitUntil("DEC \(mode) alternate screen exit", session: session) {
                !session.debugSnapshot.alternateScreenActive
                    && session.interactionState == .shellIdle
            }
            assertHealthySession(session)
        }

        var previousGeneration = session.debugSnapshot.processGeneration
        session.restartShell()
        try await waitForRestart(
            after: previousGeneration,
            in: session,
            label: "idle restart"
        )
        XCTAssertGreaterThan(session.debugSnapshot.processGeneration, previousGeneration)
        previousGeneration = session.debugSnapshot.processGeneration
        try await runCommand(
            "printf 'restart-ok-idle\\n'; sleep 0.02",
            marker: "restart-ok-idle",
            in: session
        )

        let runningRestartCommand = "printf 'pane-running-restart\\n'; sleep 30"
        session.submit(command: runningRestartCommand)
        try await waitUntil("running restart fixture", session: session) {
            session.activeCommandBlock?.command == runningRestartCommand
                && session.activeCommandBlock?.state == .running
        }
        session.restartShell()
        try await waitForRestart(
            after: previousGeneration,
            in: session,
            label: "running-command restart"
        )
        XCTAssertGreaterThan(session.debugSnapshot.processGeneration, previousGeneration)
        previousGeneration = session.debugSnapshot.processGeneration
        XCTAssertTrue(session.blocks.contains { block in
            guard block.command == runningRestartCommand else { return false }
            if case .interrupted = block.state { return true }
            return false
        })
        try await runCommand(
            "printf 'restart-ok-running\\n'; sleep 0.02",
            marker: "restart-ok-running",
            in: session
        )

        let directRestartCommand = #"/bin/sh -c 'stty -icanon echo; printf "pane-direct-restart\n"; sleep 30'"#
        session.submit(command: directRestartCommand)
        try await waitUntil("direct-input restart fixture", session: session, timeout: 8) {
            session.activeCommandBlock?.command == directRestartCommand
                && session.interactionState == .commandRunningDirect
        }
        session.restartShell()
        try await waitForRestart(
            after: previousGeneration,
            in: session,
            label: "direct-input restart"
        )
        XCTAssertGreaterThan(session.debugSnapshot.processGeneration, previousGeneration)
        assertHealthySession(session)
        XCTAssertTrue(session.debugAuthoritativeTerminalView === terminalIdentity)

        try await runCommand(
            "printf 'pane-final-health-check\\n'; sleep 0.02",
            marker: "pane-final-health-check",
            in: session
        )
        assertHealthySession(session)
    }

    @MainActor
    func testSecureInputNeverEntersPersistentState() async throws {
        let harness = try makeHarness(named: "secure-persistence", persistenceEnabled: true)
        let session = harness.session
        let terminalView = harness.terminalView
        defer { try? FileManager.default.removeItem(at: harness.root) }

        try await waitUntil("persistent session shell readiness", session: session) {
            session.isShellReadyForInput
        }
        let command = """
        printf 'PANE_SECURE_READY\\n'; read -s pane_secret; printf '\\nPANE_SECURE_DONE\\n'
        """
        session.submit(command: command)
        try await waitUntil("secure input requirement", session: session, timeout: 8) {
            session.isSecureInputActive
                && session.inputRequirement == .secure
                && session.debugSnapshot.securityState.inputMode == .secure
        }

        terminalView.send(data: Array("\(Self.secureFixture)\n".utf8)[...])
        try await waitUntil("secure interaction completion", session: session, timeout: 8) {
            !session.isSecureInputActive
                && !session.isCommandActive
                && session.blocks.contains { block in
                    guard block.command == command else { return false }
                    if case .completed(exitCode: 0) = block.state { return true }
                    return false
                }
        }

        try await waitForPersistedCommand(
            command,
            databaseURL: harness.databaseURL,
            workspaceID: harness.root.path
        )
        await session.finalizeApplicationExit()

        let context = try await SQLiteRuntimeStateStore(databaseURL: harness.databaseURL)
            .loadRecentContext(
                workspaceID: harness.root.path,
                repositoryID: nil,
                limit: 100
            )
        assertSecretAbsent(
            from: session,
            context: context,
            databaseDirectory: harness.root
        )
    }

    @MainActor
    func testSecureInputDoesNotReappearAfterRestore() async throws {
        let first = try makeHarness(named: "secure-restore", persistenceEnabled: true)
        let firstSession = first.session
        defer { try? FileManager.default.removeItem(at: first.root) }

        try await waitUntil("first restore shell readiness", session: firstSession) {
            firstSession.isShellReadyForInput
        }
        let command = """
        printf 'PANE_RESTORE_SECURE_READY\\n'; read -s pane_secret; printf '\\nPANE_RESTORE_SECURE_DONE\\n'
        """
        firstSession.submit(command: command)
        try await waitUntil("restore fixture secure input", session: firstSession, timeout: 8) {
            firstSession.isSecureInputActive
        }
        first.terminalView.send(data: Array("\(Self.secureFixture)\n".utf8)[...])
        try await waitUntil("restore fixture completion", session: firstSession, timeout: 8) {
            !firstSession.isCommandActive && !firstSession.isSecureInputActive
        }
        try await waitForPersistedCommand(
            command,
            databaseURL: first.databaseURL,
            workspaceID: first.root.path
        )
        await firstSession.finalizeApplicationExit()

        let secondController = RuntimeStateController(
            databaseURL: first.databaseURL,
            configuration: persistenceConfiguration
        )
        let restoredSession = TerminalSession(
            shellConfiguration: isolatedShellConfiguration(home: first.root),
            runtimeStateController: secondController
        )
        let restoredTerminal = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        restoredSession.attach(terminalView: restoredTerminal)
        defer { restoredSession.shutdown() }

        try await waitUntil("restored runtime context", session: restoredSession, timeout: 8) {
            restoredSession.isShellReadyForInput
                && restoredSession.history.commands.contains(command)
        }
        let context = try await SQLiteRuntimeStateStore(databaseURL: first.databaseURL)
            .loadRecentContext(
                workspaceID: first.root.path,
                repositoryID: nil,
                limit: 100
            )
        assertSecretAbsent(
            from: restoredSession,
            context: context,
            databaseDirectory: first.root
        )
        XCTAssertFalse(restoredSession.isSecureInputActive)
        XCTAssertTrue(restoredSession.commandDraft.isEmpty)
        XCTAssertTrue(restoredSession.blocks.allSatisfy(\.isRerunnable))
    }

    @MainActor
    func testSecureInputDisablesAutocomplete() async throws {
        let harness = try makeHarness(named: "secure-autocomplete")
        let session = harness.session
        defer {
            session.shutdown()
            try? FileManager.default.removeItem(at: harness.root)
        }

        try await waitUntil("autocomplete fixture shell readiness", session: session) {
            session.isShellReadyForInput
        }
        session.enterSecureInput()
        XCTAssertTrue(session.isSecureInputActive)

        let updates = await session.autocompleteSuggestions(
            for: Self.secureFixture,
            cursorUTF16Offset: Self.secureFixture.utf16.count
        )
        var suggestions: [CommandAutocompleteSuggestion] = []
        for await update in updates {
            suggestions = update
        }

        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertFalse(session.history.commands.contains(Self.secureFixture))
        XCTAssertFalse(session.commandDraft.contains(Self.secureFixture))
        session.exitSecureInput()
        assertHealthySession(session)
    }

    @MainActor
    private func runCommand(
        _ command: String,
        marker: String,
        in session: TerminalSession
    ) async throws {
        session.submit(command: command)
        try await waitUntil("\(marker) to become active", session: session) {
            session.activeCommandBlock?.command == command
                && session.activeCommandBlock?.state == .running
        }
        try await waitUntil("\(marker) to complete", session: session) {
            guard let block = session.blocks.first(where: { $0.command == command }),
                  case .completed(exitCode: 0) = block.state else {
                return false
            }
            return block.output.contains(marker) && !session.isCommandActive
        }
    }

    @MainActor
    private func waitForRestart(
        after generation: UInt64,
        in session: TerminalSession,
        label: String
    ) async throws {
        try await waitUntil(label, session: session, timeout: 8) {
            session.debugSnapshot.processGeneration > generation
                && session.isShellReadyForInput
                && !session.isRestartInProgress
        }
        assertHealthySession(session)
    }

    @MainActor
    private func assertHealthySession(
        _ session: TerminalSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = session.debugSnapshot
        let diagnostic = sessionDiagnostic(session)
        XCTAssertEqual(snapshot.interactionState, .shellIdle, diagnostic, file: file, line: line)
        XCTAssertEqual(snapshot.shellReadiness, .ready, diagnostic, file: file, line: line)
        XCTAssertNil(snapshot.activeBlockID, diagnostic, file: file, line: line)
        XCTAssertFalse(snapshot.alternateScreenActive, diagnostic, file: file, line: line)
        XCTAssertEqual(snapshot.keyboardOwner, .composer, diagnostic, file: file, line: line)
        XCTAssertEqual(snapshot.terminalMount, .hidden, diagnostic, file: file, line: line)
        XCTAssertEqual(
            snapshot.securityState.inputMode,
            .normal,
            diagnostic,
            file: file,
            line: line
        )
        XCTAssertTrue(
            snapshot.securityState.echoEnabled,
            diagnostic,
            file: file,
            line: line
        )
        XCTAssertTrue(session.isShellRunning, diagnostic, file: file, line: line)
        XCTAssertTrue(session.isShellReadyForInput, diagnostic, file: file, line: line)
        XCTAssertFalse(session.isCommandActive, diagnostic, file: file, line: line)
        XCTAssertNotNil(session.debugAuthoritativeTerminalView, diagnostic, file: file, line: line)
    }

    @MainActor
    private func sessionDiagnostic(_ session: TerminalSession) -> String {
        let snapshot = session.debugSnapshot
        return [
            "interactionState=\(snapshot.interactionState)",
            "shellReadiness=\(snapshot.shellReadiness)",
            "processGeneration=\(snapshot.processGeneration)",
            "activeBlockID=\(snapshot.activeBlockID?.uuidString ?? "nil")",
            "alternateScreenActive=\(snapshot.alternateScreenActive)",
            "keyboardOwner=\(snapshot.keyboardOwner)",
            "terminalMount=\(snapshot.terminalMount)",
            "focusGeneration=\(snapshot.focusGeneration)",
            "securityState=\(snapshot.securityState)"
        ].joined(separator: ", ")
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        session: TerminalSession,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(description); \(sessionDiagnostic(session))")
        throw CocoaError(.coderReadCorrupt)
    }

    private struct Harness {
        let root: URL
        let databaseURL: URL
        let session: TerminalSession
        let terminalView: PaneTerminalView
    }

    @MainActor
    private func makeHarness(
        named name: String,
        persistenceEnabled: Bool = false
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("runtime-state.sqlite")
        let controller = persistenceEnabled
            ? RuntimeStateController(
                databaseURL: databaseURL,
                configuration: persistenceConfiguration
            )
            : nil
        let session = TerminalSession(
            shellConfiguration: isolatedShellConfiguration(home: root),
            runtimeStateController: controller
        )
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        session.attach(terminalView: terminalView)
        return Harness(
            root: root,
            databaseURL: databaseURL,
            session: session,
            terminalView: terminalView
        )
    }

    private func isolatedShellConfiguration(home: URL) -> ShellConfiguration {
        ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": home.path
            ],
            homeDirectory: home
        )
    }

    private var persistenceConfiguration: RuntimeStateConfiguration {
        RuntimeStateConfiguration(
            persistenceEnabled: true,
            commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        )
    }

    private func waitForPersistedCommand(
        _ command: String,
        databaseURL: URL,
        workspaceID: String
    ) async throws {
        let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let context = try await store.loadRecentContext(
                workspaceID: workspaceID,
                repositoryID: nil,
                limit: 100
            )
            if context.commandEvents.contains(where: { $0.command == command }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for secure interaction persistence")
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private func assertSecretAbsent(
        from session: TerminalSession,
        context: PersistedRuntimeContext,
        databaseDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let secret = Self.secureFixture
        XCTAssertFalse(
            session.blocks.contains {
                $0.command.contains(secret) || $0.output.contains(secret)
            },
            file: file,
            line: line
        )
        XCTAssertFalse(
            session.history.commands.contains { $0.contains(secret) },
            file: file,
            line: line
        )
        XCTAssertFalse(session.commandDraft.contains(secret), file: file, line: line)
        XCTAssertFalse(String(describing: context).contains(secret), file: file, line: line)

        let persistedFiles = (try? FileManager.default.contentsOfDirectory(
            at: databaseDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let secretBytes = Data(secret.utf8)
        for url in persistedFiles {
            guard let bytes = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(
                bytes.range(of: secretBytes),
                "Secure fixture leaked into \(url.lastPathComponent)",
                file: file,
                line: line
            )
        }
    }
}
