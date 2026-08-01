import AppKit
import Darwin
import Foundation
@preconcurrency import SwiftTerm
@testable import Pane

enum WorkspaceStressBackend: Equatable {
    case fake
    case realPTY
}

struct WorkspaceStressRunResult {
    let initialTabCount: Int
    let commandsPerTab: Int
    let commandCount: Int
    let switchCount: Int
    let backgroundProducerCount: Int
    let alternateScreenCount: Int
    let closedTabIDs: [UUID]
    let replacementTabIDs: [UUID]
    let survivingTabIDs: [UUID]
    let finalMarkerOwners: [String: UUID]
    let outputIsolationViolations: [String]
    let inputIsolationViolations: [String]
    let focusIsolationViolations: [String]
    let resizeIsolationViolations: [String]
    let secureStateIsolationViolations: [String]
    let terminalIdentityChangeCount: Int
    let ptyGenerationChangeCount: Int
    let closingTabIDsAfterCleanup: Set<UUID>
    let pendingFocusTabIDAfterCleanup: UUID?
    let closeCleanupConverged: Bool
    let maximumCloseDuration: TimeInterval
}

struct WorkspaceStressFailure: Error, CustomStringConvertible {
    enum Stage: String {
        case startup
        case commands
        case backgroundOutput
        case alternateScreen
        case input
        case close
        case replacement
        case finalMarkers
        case cleanup
    }

    let stage: Stage
    let diagnostic: String

    var description: String {
        "workspace-stress stage=\(stage.rawValue) \(diagnostic)"
    }
}

/// Reusable P2 workspace runner. It always uses ordinary TerminalSession and
/// TerminalWorkspaceController instances. Fake mode replaces only the
/// PTYProcessDriving implementation, preserving Pane's lifecycle, parser,
/// terminal view, focus, resize, and cleanup paths.
@MainActor
final class WorkspaceStressRunner {
    private struct Harness {
        let id: UUID
        let session: TerminalSession
        let terminalView: PaneTerminalView
        let initialTerminalIdentity: ObjectIdentifier
        let initialPTYGeneration: UInt64
    }

    private let configuration: WorkspaceStressConfiguration
    private let backend: WorkspaceStressBackend
    private let fakeFleet = WorkspaceStressFakePTYFleet()
    private let timeout: TimeInterval

    init(
        configuration: WorkspaceStressConfiguration = .baseline,
        backend: WorkspaceStressBackend = .fake
    ) {
        self.configuration = configuration
        self.backend = backend
        timeout = backend == .fake ? 5 : 30
    }

    func run() async throws -> WorkspaceStressRunResult {
        guard configuration.tabCount >= configuration.closeCount,
              configuration.tabCount >= 9 else {
            throw WorkspaceStressFailure(
                stage: .startup,
                diagnostic: "configuration needs at least 9 tabs and closeCount <= tabCount"
            )
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Pane-WorkspaceStress-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let shell = isolatedShell(home: temporaryRoot)
        let factory = WorkspaceStressTerminalSessionFactory(
            backend: backend,
            fakeFleet: fakeFleet
        )
        let workspace = TerminalWorkspaceController(
            factory: factory,
            snapshotURL: temporaryRoot.appendingPathComponent("workspace.json"),
            defaultShell: shell
        )

        do {
            let result = try await execute(
                workspace: workspace,
                shell: shell,
                temporaryRoot: temporaryRoot
            )
            await workspace.shutdown()
            try? FileManager.default.removeItem(at: temporaryRoot)
            return result
        } catch {
            await workspace.shutdown()
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    private func execute(
        workspace: TerminalWorkspaceController,
        shell: ShellConfiguration,
        temporaryRoot: URL
    ) async throws -> WorkspaceStressRunResult {
        await workspace.restoreWorkspace()
        while workspace.tabs.count < configuration.tabCount {
            guard await workspace.createTab(inBackground: true) != nil else {
                throw WorkspaceStressFailure(
                    stage: .startup,
                    diagnostic: "failed to create tab \(workspace.tabs.count + 1)"
                )
            }
        }
        try await wait(stage: .startup, description: "all shells ready") {
            workspace.tabs.count == self.configuration.tabCount
                && workspace.tabs.allSatisfy {
                    $0.session.shellReadiness == .ready
                        && $0.session.isShellRunning
                }
        }

        var harnesses = try workspace.tabs.map(makeHarness)
        let initialHarnesses = harnesses

        var expectedCommandOwners: [String: UUID] = [:]
        for harness in harnesses {
            for commandIndex in 0..<configuration.commandsPerTab {
                let marker = marker(
                    kind: "COMMAND",
                    tabID: harness.id,
                    index: commandIndex
                )
                expectedCommandOwners[marker] = harness.id
                harness.session.submit(command: printCommand(marker))
            }
        }
        try await wait(stage: .commands, description: "command queues to drain") {
            harnesses.allSatisfy {
                $0.session.blocks.count >= self.configuration.commandsPerTab
                    && !$0.session.isCommandActive
            }
        }

        var outputViolations = isolationViolations(
            expectedOwners: expectedCommandOwners,
            harnesses: harnesses
        )

        let producerCount = min(6, harnesses.count)
        let alternateCount = min(3, harnesses.count - producerCount)
        let producerHarnesses = Array(harnesses.prefix(producerCount))
        let alternateHarnesses = Array(
            harnesses.dropFirst(producerCount).prefix(alternateCount)
        )

        if let foregroundHarness = harnesses.last {
            workspace.selectTab(id: foregroundHarness.id)
        }
        for harness in producerHarnesses {
            let ready = marker(kind: "PRODUCER_READY", tabID: harness.id, index: 0)
            harness.session.submit(
                command: backgroundProducerCommand(marker: ready)
            )
        }
        try await wait(
            stage: .backgroundOutput,
            description: "six background producers"
        ) {
            producerHarnesses.allSatisfy {
                $0.session.visibilityState == .background
                    && $0.session.isCommandActive
                    && self.sessionContains($0.session, "PANE_STRESS_PRODUCER_READY")
            }
        }

        if backend == .fake {
            for tick in 0..<4 {
                for harness in producerHarnesses {
                    fakeFleet.driver(for: harness.id)?.emitBackground(
                        marker(
                            kind: "BACKGROUND",
                            tabID: harness.id,
                            index: tick
                        )
                    )
                }
            }
            try await wait(
                stage: .backgroundOutput,
                description: "coalescible background output"
            ) {
                producerHarnesses.allSatisfy { harness in
                    (0..<4).allSatisfy { tick in
                        self.sessionContains(
                            harness.session,
                            self.marker(
                                kind: "BACKGROUND",
                                tabID: harness.id,
                                index: tick
                            )
                        )
                    }
                }
            }
        }

        for harness in alternateHarnesses {
            let ready = marker(kind: "ALT_READY", tabID: harness.id, index: 0)
            harness.session.submit(
                command: alternateScreenCommand(marker: ready)
            )
        }
        try await wait(
            stage: .alternateScreen,
            description: "three alternate screens"
        ) {
            alternateHarnesses.allSatisfy {
                $0.session.isAlternateScreenActive
                    && $0.session.inputRequirement == .direct
            }
        }

        for switchIndex in 0..<configuration.switchCount {
            workspace.selectTab(
                id: harnesses[switchIndex % harnesses.count].id
            )
        }
        try await drainMainQueue()

        var focusViolations: [String] = []
        if workspace.tabs.filter({
            $0.session.visibilityState == .selected
        }).count != 1 {
            focusViolations.append("selection did not converge to exactly one tab")
        }
        for tab in workspace.tabs
        where tab.id != workspace.selectedTabID
            && tab.session.focusTarget != .none {
            focusViolations.append("background tab \(tab.id) retained focus")
        }

        var identityChanges = 0
        var generationChanges = 0
        for harness in harnesses {
            if ObjectIdentifier(harness.session.makeAuthoritativeTerminalView())
                != harness.initialTerminalIdentity {
                identityChanges += 1
            }
            if harness.session.debugProcessGeneration
                != harness.initialPTYGeneration {
                generationChanges += 1
            }
        }

        let inputViolations = try await exerciseInputIsolation(
            workspace: workspace,
            harnesses: harnesses
        )
        let resizeViolations = exerciseResizeIsolation(harnesses: harnesses)
        let secureViolations = try await exerciseSecureStateIsolation(
            workspace: workspace,
            harnesses: harnesses
        )

        let tabsToClose = Array(harnesses.prefix(configuration.closeCount))
        var maximumCloseDuration: TimeInterval = 0
        for harness in tabsToClose {
            let startedAt = Date()
            let result = await workspace.closeTab(id: harness.id, policy: .force)
            maximumCloseDuration = max(
                maximumCloseDuration,
                Date().timeIntervalSince(startedAt)
            )
            guard result == .closed else {
                throw WorkspaceStressFailure(
                    stage: .close,
                    diagnostic: "tab \(harness.id) returned \(result)"
                )
            }
        }
        let closedIDs = tabsToClose.map(\.id)
        let closeCleanupConverged = tabsToClose.allSatisfy { harness in
            harness.session.isShuttingDown
                && harness.session.focusTarget == .none
                && !harness.session.isShellRunning
                && !harness.session.isRestartInProgress
                && (backend != .fake
                    || fakeFleet.driver(for: harness.id)?.terminateCount == 1)
        }

        harnesses.removeAll { closedIDs.contains($0.id) }
        var replacementIDs: [UUID] = []
        for _ in 0..<configuration.closeCount {
            let id = UUID()
            let config = TerminalSessionConfiguration(
                tabID: id,
                initialDirectory: temporaryRoot,
                shellConfiguration: shell,
                restoredMode: nil,
                restoredDraft: nil,
                restoredTitle: nil
            )
            _ = await workspace.createTab(
                configuration: config,
                select: false
            )
            guard let tab = workspace.tabs.first(where: { $0.id == id }) else {
                throw WorkspaceStressFailure(
                    stage: .replacement,
                    diagnostic: "replacement \(id) was not installed"
                )
            }
            replacementIDs.append(id)
            harnesses.append(try makeHarness(tab))
        }
        try await wait(
            stage: .replacement,
            description: "replacement shells ready"
        ) {
            replacementIDs.allSatisfy { id in
                workspace.tabs.first(where: { $0.id == id })?
                    .session.shellReadiness == .ready
            }
        }

        if backend == .fake {
            for harness in alternateHarnesses {
                fakeFleet.driver(for: harness.id)?.finishHeldCommand()
            }
        }
        let survivingAlternateHarnesses = alternateHarnesses.filter {
            !closedIDs.contains($0.id)
        }
        try await wait(
            stage: .alternateScreen,
            description: "alternate screens to exit"
        ) {
            survivingAlternateHarnesses.allSatisfy {
                !$0.session.isAlternateScreenActive
                    && !$0.session.isCommandActive
            }
        }

        var finalOwners: [String: UUID] = [:]
        for (index, harness) in harnesses.enumerated() {
            let marker = marker(
                kind: "FINAL",
                tabID: harness.id,
                index: index
            )
            finalOwners[marker] = harness.id
            harness.session.submit(command: printCommand(marker))
        }
        try await wait(stage: .finalMarkers, description: "final marker commands") {
            finalOwners.allSatisfy { marker, owner in
                guard let harness = harnesses.first(where: { $0.id == owner })
                else { return false }
                return self.sessionContains(harness.session, marker)
                    && !harness.session.isCommandActive
            }
        }
        outputViolations.append(
            contentsOf: isolationViolations(
                expectedOwners: finalOwners,
                harnesses: harnesses
            )
        )

        try await drainMainQueue()
        let workspaceSnapshot = workspace.debugSnapshot
        if let pending = workspaceSnapshot.pendingFocusTabID,
           closedIDs.contains(pending) {
            focusViolations.append("pending focus targets closed tab \(pending)")
        }
        for tab in workspace.tabs
        where tab.id != workspace.selectedTabID
            && tab.session.focusTarget != .none {
            focusViolations.append(
                "background survivor \(tab.id) retained focus after cleanup"
            )
        }

        let stuckSessions = harnesses.filter {
            $0.session.isShuttingDown
                || $0.session.isRestartInProgress
                || $0.session.isCommandActive
                || $0.session.shellReadiness != .ready
        }
        if !stuckSessions.isEmpty {
            throw WorkspaceStressFailure(
                stage: .cleanup,
                diagnostic: "survivors stuck: \(stuckSessions.map(\.id))"
            )
        }

        return WorkspaceStressRunResult(
            initialTabCount: initialHarnesses.count,
            commandsPerTab: configuration.commandsPerTab,
            commandCount: expectedCommandOwners.count,
            switchCount: configuration.switchCount,
            backgroundProducerCount: producerHarnesses.count,
            alternateScreenCount: alternateHarnesses.count,
            closedTabIDs: closedIDs,
            replacementTabIDs: replacementIDs,
            survivingTabIDs: harnesses.map(\.id),
            finalMarkerOwners: finalOwners,
            outputIsolationViolations: outputViolations,
            inputIsolationViolations: inputViolations,
            focusIsolationViolations: focusViolations,
            resizeIsolationViolations: resizeViolations,
            secureStateIsolationViolations: secureViolations,
            terminalIdentityChangeCount: identityChanges,
            ptyGenerationChangeCount: generationChanges,
            closingTabIDsAfterCleanup: workspaceSnapshot.closingTabIDs,
            pendingFocusTabIDAfterCleanup:
                workspaceSnapshot.pendingFocusTabID,
            closeCleanupConverged: closeCleanupConverged,
            maximumCloseDuration: maximumCloseDuration
        )
    }

    private func exerciseInputIsolation(
        workspace: TerminalWorkspaceController,
        harnesses: [Harness]
    ) async throws -> [String] {
        var violations: [String] = []
        let indices: [Int]
        if backend == .fake {
            indices = Array(harnesses.indices)
        } else {
            indices = Array(harnesses.indices.suffix(3))
        }

        for index in indices {
            let harness = harnesses[index]
            let other = harnesses[(index + 1) % harnesses.count]
            workspace.selectTab(id: harness.id)
            harness.session.setMode(.terminal)
            let marker = "PANE_STRESS_INPUT|\(harness.id.uuidString)"
            let bytes: [UInt8]
            if backend == .fake {
                bytes = Array((marker + "\n").utf8)
            } else {
                bytes = Array((printCommand(marker) + "\r").utf8)
            }

            let ownBefore = fakeFleet.driver(for: harness.id)?
                .stressInputMarkers.count ?? 0
            harness.session.send(
                source: other.terminalView,
                data: bytes[...]
            )
            if backend == .fake,
               fakeFleet.driver(for: harness.id)?
                .stressInputMarkers.count != ownBefore {
                violations.append("wrong terminal source reached \(harness.id)")
            }

            let inactiveBefore = fakeFleet.driver(for: other.id)?
                .stressInputMarkers.count ?? 0
            other.session.send(
                source: other.terminalView,
                data: bytes[...]
            )
            if backend == .fake,
               fakeFleet.driver(for: other.id)?
                .stressInputMarkers.count != inactiveBefore {
                violations.append("inactive tab \(other.id) accepted input")
            }

            harness.session.send(
                source: harness.terminalView,
                data: bytes[...]
            )
            if backend == .fake {
                let recipients = harnesses.compactMap { candidate -> UUID? in
                    fakeFleet.driver(for: candidate.id)?
                        .stressInputMarkers.contains(marker) == true
                        ? candidate.id : nil
                }
                if recipients != [harness.id] {
                    violations.append(
                        "input \(marker) recipients=\(recipients)"
                    )
                }
            } else {
                try await wait(
                    stage: .input,
                    description: "real input marker \(marker)"
                ) {
                    self.sessionContains(harness.session, marker)
                }
                let recipients = harnesses.filter {
                    self.sessionContains($0.session, marker)
                }.map(\.id)
                if recipients != [harness.id] {
                    violations.append(
                        "real input \(marker) recipients=\(recipients)"
                    )
                }
            }
            harness.session.setMode(.blocks)
        }
        return violations
    }

    private func exerciseResizeIsolation(
        harnesses: [Harness]
    ) -> [String] {
        var violations: [String] = []
        guard harnesses.count > 1 else { return violations }

        let first = harnesses[0]
        let second = harnesses[1]
        let beforeWrongSource = first.session.debugPTYWindowSize
        first.session.sizeChanged(
            source: second.terminalView,
            newCols: second.terminalView.terminal.cols,
            newRows: second.terminalView.terminal.rows
        )
        if !sameWindowSize(
            beforeWrongSource,
            first.session.debugPTYWindowSize
        ) {
            violations.append("wrong terminal source resized \(first.id)")
        }

        for (index, harness) in harnesses.enumerated() {
            let otherSizes = Dictionary(
                uniqueKeysWithValues: harnesses
                    .filter { $0.id != harness.id }
                    .map { ($0.id, $0.session.debugPTYWindowSize) }
            )
            harness.terminalView.setFrameSize(
                NSSize(
                    width: 640 + index * 37,
                    height: 320 + index * 19
                )
            )
            harness.session.sizeChanged(
                source: harness.terminalView,
                newCols: harness.terminalView.terminal.cols,
                newRows: harness.terminalView.terminal.rows
            )
            for candidate in harnesses where candidate.id != harness.id {
                guard let previous = otherSizes[candidate.id] else { continue }
                if !sameWindowSize(
                    previous,
                    candidate.session.debugPTYWindowSize
                ) {
                    violations.append(
                        "resize for \(harness.id) crossed to \(candidate.id)"
                    )
                }
            }
        }
        let dimensions = Set(harnesses.map {
            let size = $0.session.debugPTYWindowSize
            return "\(size.ws_xpixel)x\(size.ws_ypixel)"
        })
        if dimensions.count != harnesses.count {
            violations.append("per-session resize dimensions were not unique")
        }
        return violations
    }

    private func exerciseSecureStateIsolation(
        workspace: TerminalWorkspaceController,
        harnesses: [Harness]
    ) async throws -> [String] {
        var violations: [String] = []
        let secureIndex = min(9, harnesses.count - 1)
        let secureHarness = harnesses[secureIndex]
        workspace.selectTab(id: secureHarness.id)
        secureHarness.session.enterSecureInput()
        try await drainMainQueue()

        let secureOwners = harnesses.filter {
            $0.session.isSecureInputActive
        }.map(\.id)
        if secureOwners != [secureHarness.id] {
            violations.append("secure state owners=\(secureOwners)")
        }
        if harnesses.contains(where: {
            $0.id != secureHarness.id
                && $0.session.inputRequirement == .secure
        }) {
            violations.append("secure input requirement crossed sessions")
        }

        secureHarness.session.exitSecureInput()
        if harnesses.contains(where: { $0.session.isSecureInputActive }) {
            violations.append("secure state did not clear locally")
        }
        return violations
    }

    private func makeHarness(_ tab: TerminalTab) throws -> Harness {
        guard let terminalView = tab.session.debugAuthoritativeTerminalView
                as? PaneTerminalView else {
            throw WorkspaceStressFailure(
                stage: .startup,
                diagnostic: "tab \(tab.id) has no authoritative terminal"
            )
        }
        return Harness(
            id: tab.id,
            session: tab.session,
            terminalView: terminalView,
            initialTerminalIdentity: ObjectIdentifier(terminalView),
            initialPTYGeneration: tab.session.debugProcessGeneration
        )
    }

    private func isolationViolations(
        expectedOwners: [String: UUID],
        harnesses: [Harness]
    ) -> [String] {
        expectedOwners.compactMap { marker, owner in
            let recipients = harnesses.filter {
                sessionContains($0.session, marker)
            }.map(\.id)
            return recipients == [owner]
                ? nil
                : "\(marker) expected=\(owner) recipients=\(recipients)"
        }
    }

    private func sessionContains(
        _ session: TerminalSession,
        _ marker: String
    ) -> Bool {
        if session.blocks.contains(where: { $0.output.contains(marker) }) {
            return true
        }
        guard let terminalView = session.debugAuthoritativeTerminalView
                as? PaneTerminalView else {
            return false
        }
        return String(
            decoding: terminalView.terminal.getBufferAsData(kind: .active),
            as: UTF8.self
        ).contains(marker)
    }

    private func wait(
        stage: WorkspaceStressFailure.Stage,
        description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WorkspaceStressFailure(
            stage: stage,
            diagnostic: "timeout waiting for \(description)"
        )
    }

    private func drainMainQueue() async throws {
        for _ in 0..<4 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func marker(kind: String, tabID: UUID, index: Int) -> String {
        "PANE_STRESS_\(kind)|\(tabID.uuidString)|\(index)"
    }

    private func printCommand(_ marker: String) -> String {
        "printf '\(marker)\\n'"
    }

    private func backgroundProducerCommand(marker: String) -> String {
        if backend == .fake {
            return "printf '\(marker)\\n'; __PANE_STRESS_HOLD__"
        }
        return "printf '\(marker)\\n'; for pane_i in {1..200}; do printf 'PANE_STRESS_BACKGROUND|\(marker)|%s\\n' \"$pane_i\"; sleep 0.05; done"
    }

    private func alternateScreenCommand(marker: String) -> String {
        if backend == .fake {
            return "printf '\(marker)\\n'; __PANE_STRESS_ALT__"
        }
        return "printf '\\033[?1049h\(marker)\\n'; sleep 2; printf '\\033[?1049l'"
    }

    private func isolatedShell(home: URL) -> ShellConfiguration {
        .loginZsh(
            processEnvironment: [
                "HOME": home.path,
                "ZDOTDIR": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            homeDirectory: home
        )
    }

    private func sameWindowSize(_ lhs: winsize, _ rhs: winsize) -> Bool {
        lhs.ws_row == rhs.ws_row
            && lhs.ws_col == rhs.ws_col
            && lhs.ws_xpixel == rhs.ws_xpixel
            && lhs.ws_ypixel == rhs.ws_ypixel
    }
}

@MainActor
private final class WorkspaceStressTerminalSessionFactory:
    TerminalSessionFactory {
    private let backend: WorkspaceStressBackend
    private let fakeFleet: WorkspaceStressFakePTYFleet

    init(
        backend: WorkspaceStressBackend,
        fakeFleet: WorkspaceStressFakePTYFleet
    ) {
        self.backend = backend
        self.fakeFleet = fakeFleet
    }

    func makeSession(
        configuration: TerminalSessionConfiguration
    ) -> TerminalSession {
        var shell = configuration.shellConfiguration
        shell.workingDirectory = configuration.initialDirectory.path
        let controller: PTYController?
        switch backend {
        case .fake:
            controller = fakeFleet.makeController(tabID: configuration.tabID)
        case .realPTY:
            controller = nil
        }
        let session = TerminalSession(
            tabID: configuration.tabID,
            shellConfiguration: shell,
            commandHistoryEnabled: false,
            ptyController: controller
        )
        if let mode = configuration.restoredMode {
            session.restoreModeWhenReady(mode)
        }
        if let draft = configuration.restoredDraft {
            session.commandDraft = draft
        }
        return session
    }
}

@MainActor
private final class WorkspaceStressFakePTYFleet {
    private var drivers: [UUID: WorkspaceStressFakePTYProcess] = [:]

    func makeController(tabID: UUID) -> PTYController {
        PTYController(
            terminationDelay: .nanoseconds(0),
            processFactory: { [weak self] delegate in
                let driver = WorkspaceStressFakePTYProcess(
                    tabID: tabID,
                    delegate: delegate
                )
                self?.drivers[tabID] = driver
                return driver
            },
            resizeHandler: { _, _ in }
        )
    }

    func driver(for tabID: UUID) -> WorkspaceStressFakePTYProcess? {
        drivers[tabID]
    }
}

@MainActor
private final class WorkspaceStressFakePTYProcess: PTYProcessDriving {
    let tabID: UUID
    private let delegate: LocalProcessDelegate
    private(set) var running = false
    private(set) var terminateCount = 0
    private(set) var stressInputMarkers: [String] = []
    private var hasBootstrapped = false
    private var holdsAlternateScreen = false
    private var holdsCommand = false

    let childFileDescriptor: Int32 = -1
    let shellProcessID: pid_t = 0

    init(tabID: UUID, delegate: LocalProcessDelegate) {
        self.tabID = tabID
        self.delegate = delegate
    }

    func start(
        configuration: ShellConfiguration,
        workingDirectory: String
    ) {
        running = true
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard running else { return }
        let text = String(decoding: data, as: UTF8.self)
        if !hasBootstrapped {
            hasBootstrapped = true
            emitOnNextTurn(lifecycleEnd())
            return
        }
        if let input = stressMarker(in: text, prefix: "PANE_STRESS_INPUT|") {
            stressInputMarkers.append(input)
            return
        }

        let command = decodedCommand(text)
        if command.contains("__PANE_STRESS_ALT__") {
            holdsCommand = true
            holdsAlternateScreen = true
            let ready = stressMarker(
                in: command,
                prefix: "PANE_STRESS_ALT_READY|"
            ) ?? "PANE_STRESS_ALT_READY|\(tabID)|0"
            emitOnNextTurn(
                lifecycleStart(command)
                    + "\u{001B}[?1049h\(ready)\r\n"
            )
            return
        }
        if command.contains("__PANE_STRESS_HOLD__") {
            holdsCommand = true
            let ready = stressMarker(
                in: command,
                prefix: "PANE_STRESS_PRODUCER_READY|"
            ) ?? "PANE_STRESS_PRODUCER_READY|\(tabID)|0"
            emitOnNextTurn(
                lifecycleStart(command) + ready + "\r\n"
            )
            return
        }
        guard let marker = stressMarker(
            in: command,
            prefix: "PANE_STRESS_"
        ) else {
            return
        }
        emitOnNextTurn(
            lifecycleStart(command)
                + marker + "\r\n"
                + lifecycleEnd()
        )
    }

    func terminate() {
        guard running else { return }
        terminateCount += 1
        running = false
        holdsCommand = false
        holdsAlternateScreen = false
    }

    func emitBackground(_ marker: String) {
        guard running, holdsCommand else { return }
        emitOnNextTurn(marker + "\r\n")
    }

    func finishHeldCommand() {
        guard running, holdsCommand else { return }
        holdsCommand = false
        let prefix: String
        if holdsAlternateScreen {
            holdsAlternateScreen = false
            prefix = "\u{001B}[?1049l"
        } else {
            prefix = ""
        }
        emitOnNextTurn(prefix + lifecycleEnd())
    }

    private func decodedCommand(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{001B}[200~", with: "")
            .replacingOccurrences(of: "\u{001B}[201~", with: "")
            .trimmingCharacters(in: .newlines)
    }

    private func lifecycleStart(_ command: String) -> String {
        let encoded = Data(command.utf8).base64EncodedString()
        return "\u{001B}]777;Pane;START;\(encoded)\u{0007}"
    }

    private func lifecycleEnd(exitCode: Int32 = 0) -> String {
        "\u{001B}]777;Pane;END;\(exitCode);/tmp\u{0007}"
    }

    private func stressMarker(
        in text: String,
        prefix: String
    ) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        return String(text[range.lowerBound...].prefix { character in
            character.isLetter
                || character.isNumber
                || character == "_"
                || character == "-"
                || character == "|"
        })
    }

    private func emitOnNextTurn(_ text: String) {
        let bytes = Array(text.utf8)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.delegate.dataReceived(slice: bytes[...])
        }
    }
}
