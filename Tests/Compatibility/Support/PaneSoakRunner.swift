import AppKit
import Foundation
import SwiftUI
@preconcurrency import SwiftTerm
@testable import Pane

enum PaneSoakPreset: String, CaseIterable, Sendable {
    case twoHours = "2h"
    case eightHours = "8h"

    var durationSeconds: TimeInterval {
        switch self {
        case .twoHours:
            return 2 * 60 * 60
        case .eightHours:
            return 8 * 60 * 60
        }
    }
}

struct PaneSoakConfiguration: Sendable {
    static let evidenceMode = "pane-backed-xctest"

    let durationSeconds: TimeInterval
    let intervalSeconds: TimeInterval
    let artifactURL: URL
    let diagnosticsDirectory: URL
    let startupTimeout: TimeInterval
    let actionTimeout: TimeInterval
    let cleanupTimeout: TimeInterval
    let mountedUI: Bool

    init(
        durationSeconds: TimeInterval,
        intervalSeconds: TimeInterval,
        artifactURL: URL,
        diagnosticsDirectory: URL,
        startupTimeout: TimeInterval = 5,
        actionTimeout: TimeInterval = 5,
        cleanupTimeout: TimeInterval = 2,
        mountedUI: Bool = ProcessInfo.processInfo.environment["PANE_SOAK_MOUNTED_UI"] == "1"
    ) {
        self.durationSeconds = durationSeconds
        self.intervalSeconds = intervalSeconds
        self.artifactURL = artifactURL
        self.diagnosticsDirectory = diagnosticsDirectory
        self.startupTimeout = startupTimeout
        self.actionTimeout = actionTimeout
        self.cleanupTimeout = cleanupTimeout
        self.mountedUI = mountedUI
    }
}

struct PaneSoakRunResult: Sendable {
    let sampleCount: Int
    let baseTabCount: Int
    let backgroundProducerCount: Int
    let interactiveFixtureCount: Int
    let idleShellCount: Int
    let performedActions: Set<String>
    let cleanupDuration: TimeInterval
    let cleanupConverged: Bool
    let evidenceMode: String
}

struct PaneSoakFailure: Error, CustomStringConvertible {
    enum Stage: String, Sendable {
        case startup
        case backgroundProducers
        case interactiveFixtures
        case marker
        case tabSwitch
        case temporaryTab
        case autocomplete
        case resize
        case sampling
        case interactiveExit
        case diagnostics
        case cleanup
    }

    let stage: Stage
    let diagnostic: String

    var description: String {
        "pane-soak stage=\(stage.rawValue) \(diagnostic)"
    }
}

/// Reproducible P2 soak driver backed by Pane's ordinary workspace, sessions,
/// PTY controllers, parser, focus routing, and authoritative terminal views.
/// It is automated terminal evidence, not visual, TUI, or manual evidence.
@MainActor
final class PaneSoakRunner {
    private struct Harness {
        let id: UUID
        let session: TerminalSession
        let terminalView: PaneTerminalView
    }

    private let configuration: PaneSoakConfiguration
    private let fixtureURL: URL
    private let metricSampler = PaneProcessMetricSampler()
    private let writer: PaneSoakArtifactWriter

    init(
        configuration: PaneSoakConfiguration,
        fixtureURL: URL
    ) {
        self.configuration = configuration
        self.fixtureURL = fixtureURL
        writer = PaneSoakArtifactWriter(
            artifactURL: configuration.artifactURL,
            diagnosticsDirectory: configuration.diagnosticsDirectory
        )
    }

    func run() async throws -> PaneSoakRunResult {
        guard configuration.durationSeconds > 0,
              configuration.intervalSeconds > 0 else {
            throw PaneSoakFailure(
                stage: .startup,
                diagnostic: "duration and interval must be positive"
            )
        }
        try await writer.prepare()

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Pane-Soak-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        let shell = isolatedShell(home: temporaryRoot)
        let factory = DefaultTerminalSessionFactory(
            runtimeStateControllerProvider: { nil },
            commandHistoryEnabled: true
        )
        let workspace = TerminalWorkspaceController(
            factory: factory,
            snapshotURL: temporaryRoot.appendingPathComponent("workspace.json"),
            defaultShell: shell
        )

        var harnesses: [Harness] = []
        var backgroundHarnesses: [Harness] = []
        var interactiveHarnesses: [Harness] = []
        var idleHarnesses: [Harness] = []
        var primaryError: Error?
        var currentStage = PaneSoakFailure.Stage.startup
        var sampleCount = 0
        var performedActions: Set<String> = []
        var mountedWindow: NSWindow?
        var transitionCount = 0
        var maximumConsecutiveUnhealthySamples = 0

        do {
            await workspace.restoreWorkspace()
            while workspace.tabs.count < 8 {
                guard await workspace.createTab(inBackground: true) != nil else {
                    throw PaneSoakFailure(
                        stage: .startup,
                        diagnostic: "failed to create tab \(workspace.tabs.count + 1)"
                    )
                }
            }
            try await wait(
                stage: .startup,
                description: "eight clean zsh sessions"
            ) {
                workspace.tabs.count == 8
                    && workspace.tabs.allSatisfy {
                        $0.session.isShellRunning
                            && $0.session.shellReadiness == .ready
                    }
            }

            harnesses = try workspace.tabs.map(makeHarness)
            backgroundHarnesses = Array(harnesses.prefix(4))
            interactiveHarnesses = Array(
                harnesses.dropFirst(4).prefix(2)
            )
            idleHarnesses = Array(harnesses.suffix(2))
            if let idle = idleHarnesses.first {
                workspace.selectTab(id: idle.id)
            }
            if configuration.mountedUI {
                let hostingView = NSHostingView(
                    rootView: TerminalWorkspaceView(workspace: workspace)
                )
                hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
                let window = NSWindow(
                    contentRect: hostingView.bounds,
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = hostingView
                window.makeKeyAndOrderFront(nil)
                mountedWindow = window
            }

            currentStage = .backgroundProducers
            try await startBackgroundProducers(backgroundHarnesses)
            currentStage = .interactiveFixtures
            try await startInteractiveFixtures(interactiveHarnesses)

            let loopStartedAt = Date()
            let loopDeadline = loopStartedAt.addingTimeInterval(
                configuration.durationSeconds
            )
            var iteration = 0
            while Date() < loopDeadline, !Task.isCancelled {
                let actions = try await exercise(
                    iteration: iteration,
                    workspace: workspace,
                    shell: shell,
                    temporaryRoot: temporaryRoot,
                    harnesses: harnesses,
                    idleHarnesses: idleHarnesses,
                    stage: &currentStage
                )
                performedActions.formUnion(actions)
                transitionCount += actions.count

                if let mountedWindow {
                    mountedWindow.contentView?.layoutSubtreeIfNeeded()
                    await Task.yield()
                    guard let selected = workspace.selectedTab?.session else {
                        throw PaneSoakFailure(stage: .sampling, diagnostic: "mounted UI has no selected session")
                    }
                    var consecutiveUnhealthy = 0
                    for attempt in 0..<2 {
                        let health = selected.terminalMountCoordinator.healthSnapshot()
                        if health.expectedPlacement == nil || health.isHealthy { break }
                        consecutiveUnhealthy += 1
                        maximumConsecutiveUnhealthySamples = max(
                            maximumConsecutiveUnhealthySamples,
                            consecutiveUnhealthy
                        )
                        if attempt == 0 {
                            try await Task.sleep(nanoseconds: 100_000_000)
                            mountedWindow.contentView?.layoutSubtreeIfNeeded()
                        }
                    }
                    if consecutiveUnhealthy >= 2 {
                        throw PaneSoakFailure(
                            stage: .sampling,
                            diagnostic: "expected visible host remained unhealthy for two settled layout cycles"
                        )
                    }
                }

                currentStage = .sampling
                let blockCount = workspace.tabs.reduce(into: 0) {
                    $0 += $1.session.blocks.count
                }
                let sample = await metricSampler.sample(
                    blockCount: blockCount
                )
                try await writer.append(
                    sample: sample,
                    iteration: iteration,
                    selectedTabID: workspace.selectedTabID,
                    actions: actions,
                    transitionCount: transitionCount,
                    mountCounters: aggregateMountCounters(workspace.tabs),
                    maximumConsecutiveUnhealthySamples: maximumConsecutiveUnhealthySamples
                )
                sampleCount += 1
                iteration += 1

                let nextSampleDate = min(
                    loopDeadline,
                    loopStartedAt.addingTimeInterval(
                        Double(iteration) * configuration.intervalSeconds
                    )
                )
                try await sleep(until: nextSampleDate)
            }
            if Task.isCancelled {
                throw CancellationError()
            }

            currentStage = .interactiveExit
            try await finishInteractiveFixtures(
                interactiveHarnesses,
                workspace: workspace
            )
            currentStage = .diagnostics
            try await writer.writeDiagnostics(
                await workspace.diagnosticsSnapshot()
            )
        } catch {
            primaryError = error
            if let snapshot = try? await workspace.diagnosticsSnapshot()
                .encodedJSON() {
                try? await writer.writeDiagnosticsData(snapshot)
            }
            try? await writer.writeFailure(
                stage: currentStage,
                errorType: String(describing: type(of: error))
            )
        }

        mountedWindow?.orderOut(nil)
        mountedWindow = nil
        let cleanupStartedAt = Date()
        await workspace.shutdown()
        let cleanupDuration = Date().timeIntervalSince(cleanupStartedAt)
        let cleanupConverged = cleanupDuration
                <= configuration.cleanupTimeout
            && harnesses.allSatisfy {
                !$0.session.isShellRunning
                    && $0.session.focusTarget == .none
            }
            && workspace.debugSnapshot.closingTabIDs.isEmpty

        let result = PaneSoakRunResult(
            sampleCount: sampleCount,
            baseTabCount: harnesses.count,
            backgroundProducerCount: backgroundHarnesses.count,
            interactiveFixtureCount: interactiveHarnesses.count,
            idleShellCount: idleHarnesses.count,
            performedActions: performedActions,
            cleanupDuration: cleanupDuration,
            cleanupConverged: cleanupConverged,
            evidenceMode: PaneSoakConfiguration.evidenceMode
        )
        try? await writer.writeSummary(
            result: result,
            configuration: configuration,
            completed: primaryError == nil && cleanupConverged
        )
        try? FileManager.default.removeItem(at: temporaryRoot)

        if let primaryError {
            throw primaryError
        }
        guard cleanupConverged else {
            throw PaneSoakFailure(
                stage: .cleanup,
                diagnostic: String(
                    format: "cleanup took %.3fs or left a live session",
                    cleanupDuration
                )
            )
        }
        return result
    }

    private func aggregateMountCounters(_ tabs: [TerminalTab]) -> [String: Int] {
        tabs.reduce(into: [
            "mountClaimCount": 0,
            "mountReleaseCount": 0,
            "staleUpdateRejectionCount": 0,
            "validationFailureCount": 0,
            "automaticRepairCount": 0,
            "successfulRepairCount": 0,
            "terminalIdentityChangeCount": 0,
            "ptyGenerationChangeCount": 0,
        ]) { totals, tab in
            let mount = tab.session.terminalMountCoordinator
            totals["mountClaimCount", default: 0] += mount.claimCount
            totals["mountReleaseCount", default: 0] += mount.releaseCount
            totals["staleUpdateRejectionCount", default: 0] += mount.staleUpdateRejectionCount
            totals["validationFailureCount", default: 0] += mount.validationFailureCount
            totals["automaticRepairCount", default: 0] += mount.automaticRepairCount
            totals["successfulRepairCount", default: 0] += mount.successfulRepairCount
            totals["terminalIdentityChangeCount", default: 0] += mount.terminalIdentityChangeCount
            totals["ptyGenerationChangeCount", default: 0] += mount.ptyGenerationChangeCount
        }
    }

    private func startBackgroundProducers(
        _ harnesses: [Harness]
    ) async throws {
        let command = [
            "/usr/bin/python3",
            shellQuote(fixtureURL.path),
            "progress",
            "--count",
            "100000000",
            "--delay",
            "0.25",
        ].joined(separator: " ")
        for harness in harnesses {
            harness.session.submit(command: command)
        }
        try await wait(
            stage: .backgroundProducers,
            description: "four periodic output producers"
        ) {
            harnesses.allSatisfy {
                $0.session.visibilityState == .background
                    && $0.session.isCommandActive
                    && self.terminalContains(
                        $0.terminalView,
                        "PANE_FIXTURE_READY"
                    )
            }
        }
    }

    private func startInteractiveFixtures(
        _ harnesses: [Harness]
    ) async throws {
        let actionTimeout = Int(
            ceil(configuration.durationSeconds + 60)
        )
        let command = [
            "/usr/bin/python3",
            shellQuote(fixtureURL.path),
            "alternate-screen",
            "--interactive",
            "--action-timeout",
            String(actionTimeout),
        ].joined(separator: " ")
        for harness in harnesses {
            harness.session.submit(command: command)
        }
        try await wait(
            stage: .interactiveFixtures,
            description: "two held alternate-screen fixtures"
        ) {
            harnesses.allSatisfy {
                $0.session.visibilityState == .background
                    && $0.session.isCommandActive
                    && $0.session.isAlternateScreenActive
                    && $0.session.inputRequirement == .direct
                    && self.terminalContains(
                        $0.terminalView,
                        "PANE_FIXTURE_READY"
                    )
            }
        }
    }

    private func exercise(
        iteration: Int,
        workspace: TerminalWorkspaceController,
        shell: ShellConfiguration,
        temporaryRoot: URL,
        harnesses: [Harness],
        idleHarnesses: [Harness],
        stage: inout PaneSoakFailure.Stage
    ) async throws -> [String] {
        var actions: [String] = []

        stage = .tabSwitch
        let selected = harnesses[iteration % harnesses.count]
        workspace.selectTab(id: selected.id)
        try await drainMainQueue()
        guard workspace.selectedTabID == selected.id else {
            throw PaneSoakFailure(
                stage: .tabSwitch,
                diagnostic: "selection did not converge"
            )
        }
        actions.append("tab-switch")

        stage = .marker
        for (index, harness) in idleHarnesses.enumerated() {
            let marker = "PANE_SOAK_MARKER|\(harness.id.uuidString)|\(iteration)|\(index)"
            let command = printCommand(marker)
            harness.session.submit(command: command)
            try await waitForCompletedCommand(
                command,
                marker: marker,
                in: harness.session,
                stage: .marker
            )
        }
        actions.append("marker")

        stage = .temporaryTab
        try await createAndCloseTemporaryTab(
            iteration: iteration,
            workspace: workspace,
            shell: shell,
            temporaryRoot: temporaryRoot
        )
        actions.append("temporary-tab-create-close")

        stage = .autocomplete
        let completionHarness = idleHarnesses[
            iteration % idleHarnesses.count
        ]
        workspace.selectTab(id: completionHarness.id)
        let completionCount = try await triggerAutocomplete(
            in: completionHarness.session,
            iteration: iteration
        )
        actions.append("autocomplete-\(completionCount)-emissions")
        actions.append("autocomplete")

        stage = .resize
        let columns = 80 + (iteration % 5) * 8
        let rows = 24 + (iteration % 3) * 4
        for (index, harness) in harnesses.enumerated() {
            harness.terminalView.setFrameSize(
                NSSize(
                    width: CGFloat(columns * 8 + index),
                    height: CGFloat(rows * 16 + index)
                )
            )
            harness.session.sizeChanged(
                source: harness.terminalView,
                newCols: harness.terminalView.terminal.cols,
                newRows: harness.terminalView.terminal.rows
            )
        }
        actions.append("resize-\(columns)x\(rows)")
        actions.append("resize")
        return actions
    }

    private func createAndCloseTemporaryTab(
        iteration: Int,
        workspace: TerminalWorkspaceController,
        shell: ShellConfiguration,
        temporaryRoot: URL
    ) async throws {
        let tabID = UUID()
        let configuration = TerminalSessionConfiguration(
            tabID: tabID,
            initialDirectory: temporaryRoot,
            shellConfiguration: shell,
            restoredMode: nil,
            restoredDraft: nil,
            restoredTitle: nil
        )
        _ = await workspace.createTab(
            configuration: configuration,
            select: false
        )
        guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else {
            throw PaneSoakFailure(
                stage: .temporaryTab,
                diagnostic: "temporary tab was not installed"
            )
        }
        try await wait(
            stage: .temporaryTab,
            description: "temporary tab readiness"
        ) {
            tab.session.shellReadiness == .ready
        }
        let marker = "PANE_SOAK_TEMP|\(tabID.uuidString)|\(iteration)"
        let command = printCommand(marker)
        tab.session.submit(command: command)
        try await waitForCompletedCommand(
            command,
            marker: marker,
            in: tab.session,
            stage: .temporaryTab
        )
        let closeResult = await workspace.closeTab(
            id: tabID,
            policy: .force
        )
        guard closeResult == .closed,
              !workspace.debugSnapshot.closingTabIDs.contains(tabID) else {
            throw PaneSoakFailure(
                stage: .temporaryTab,
                diagnostic: "temporary tab cleanup did not converge"
            )
        }
    }

    private func triggerAutocomplete(
        in session: TerminalSession,
        iteration: Int
    ) async throws -> Int {
        guard session.visibilityState == .selected,
              session.isShellReadyForInput,
              !session.isCommandActive else {
            throw PaneSoakFailure(
                stage: .autocomplete,
                diagnostic: "selected idle shell was not completion-ready"
            )
        }
        session.setMode(.blocks)
        let draft = "pane_soak_completion_\(iteration)"
        let stream = await session.autocompleteSuggestions(
            for: draft,
            cursorUTF16Offset: draft.utf16.count
        )
        var emissionCount = 0
        for await _ in stream {
            emissionCount += 1
        }
        try await wait(
            stage: .autocomplete,
            description: "completion tasks to settle"
        ) {
            PaneResourceCounters.completionTaskCount == 0
        }
        return emissionCount
    }

    private func finishInteractiveFixtures(
        _ harnesses: [Harness],
        workspace: TerminalWorkspaceController
    ) async throws {
        for harness in harnesses {
            workspace.selectTab(id: harness.id)
            let newline = Array("\n".utf8)
            harness.session.send(
                source: harness.terminalView,
                data: newline[...]
            )
        }
        try await wait(
            stage: .interactiveExit,
            description: "interactive fixture completion"
        ) {
            harnesses.allSatisfy {
                !$0.session.isAlternateScreenActive
                    && !$0.session.isCommandActive
            }
        }
    }

    private func waitForCompletedCommand(
        _ command: String,
        marker: String,
        in session: TerminalSession,
        stage: PaneSoakFailure.Stage
    ) async throws {
        try await wait(
            stage: stage,
            description: "marker command completion"
        ) {
            session.blocks.contains {
                $0.command == command
                    && $0.output.contains(marker)
                    && $0.isFinalized
            }
        }
    }

    private func wait(
        stage: PaneSoakFailure.Stage,
        description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let timeout = stage == .startup
            ? configuration.startupTimeout
            : configuration.actionTimeout
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PaneSoakFailure(
            stage: stage,
            diagnostic: "timeout waiting for \(description)"
        )
    }

    private func sleep(until deadline: Date) async throws {
        while Date() < deadline {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            try await Task.sleep(
                for: .milliseconds(
                    Int64(max(1, min(250, remaining * 1_000)))
                )
            )
        }
    }

    private func drainMainQueue() async throws {
        for _ in 0..<4 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeHarness(_ tab: TerminalTab) throws -> Harness {
        guard let terminalView = tab.session.debugAuthoritativeTerminalView
                as? PaneTerminalView else {
            throw PaneSoakFailure(
                stage: .startup,
                diagnostic: "tab \(tab.id) has no authoritative terminal"
            )
        }
        return Harness(
            id: tab.id,
            session: tab.session,
            terminalView: terminalView
        )
    }

    private func terminalContains(
        _ terminalView: PaneTerminalView,
        _ marker: String
    ) -> Bool {
        String(
            decoding: terminalView.terminal.getBufferAsData(kind: .active),
            as: UTF8.self
        ).contains(marker)
    }

    private func isolatedShell(home: URL) -> ShellConfiguration {
        .loginZsh(
            processEnvironment: [
                "HOME": home.path,
                "ZDOTDIR": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
            ],
            homeDirectory: home
        )
    }

    private func printCommand(_ marker: String) -> String {
        "printf '\(marker)\\n'"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) + "'"
    }
}

private actor PaneSoakArtifactWriter {
    private let artifactURL: URL
    private let diagnosticsDirectory: URL
    private let encoder: JSONEncoder

    init(
        artifactURL: URL,
        diagnosticsDirectory: URL
    ) {
        self.artifactURL = artifactURL
        self.diagnosticsDirectory = diagnosticsDirectory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: diagnosticsDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: artifactURL, options: .atomic)
        try? FileManager.default.removeItem(
            at: diagnosticsDirectory.appendingPathComponent("failure.json")
        )
    }

    func append(
        sample: PaneSoakSample,
        iteration: Int,
        selectedTabID: UUID?,
        actions: [String],
        transitionCount: Int,
        mountCounters: [String: Int],
        maximumConsecutiveUnhealthySamples: Int
    ) throws {
        let encodedSample = try encoder.encode(sample)
        guard var object = try JSONSerialization.jsonObject(
            with: encodedSample
        ) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["iteration"] = iteration
        object["selectedTabID"] = selectedTabID?.uuidString
        object["actions"] = actions
        object["evidenceMode"] = PaneSoakConfiguration.evidenceMode
        object["automatedPaneBacked"] = true
        object["visualEvidence"] = false
        object["mountedUI"] = ProcessInfo.processInfo.environment["PANE_SOAK_MOUNTED_UI"] == "1"
        object["transitionCount"] = transitionCount
        object["maximumConsecutiveUnhealthySamples"] = maximumConsecutiveUnhealthySamples
        for (key, value) in mountCounters {
            object[key] = value
        }
        var line = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        line.append(0x0A)

        let handle = try FileHandle(forWritingTo: artifactURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    func writeDiagnostics(_ snapshot: PaneDiagnosticsSnapshot) throws {
        try writeDiagnosticsData(snapshot.encodedJSON())
    }

    func writeDiagnosticsData(_ data: Data) throws {
        try data.write(
            to: diagnosticsDirectory.appendingPathComponent(
                "pane-diagnostics.json"
            ),
            options: .atomic
        )
    }

    func writeFailure(
        stage: PaneSoakFailure.Stage,
        errorType: String
    ) throws {
        let object: [String: Any] = [
            "errorType": errorType,
            "evidenceMode": PaneSoakConfiguration.evidenceMode,
            "stage": stage.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: diagnosticsDirectory.appendingPathComponent("failure.json"),
            options: .atomic
        )
    }

    func writeSummary(
        result: PaneSoakRunResult,
        configuration: PaneSoakConfiguration,
        completed: Bool
    ) throws {
        let object: [String: Any] = [
            "automatedPaneBacked": true,
            "backgroundTabs": result.backgroundProducerCount,
            "cleanupConverged": result.cleanupConverged,
            "cleanupDurationSeconds": result.cleanupDuration,
            "completed": completed,
            "durationSeconds": configuration.durationSeconds,
            "evidenceMode": result.evidenceMode,
            "idleTabs": result.idleShellCount,
            "interactiveTabs": result.interactiveFixtureCount,
            "intervalSeconds": configuration.intervalSeconds,
            "mountedUI": configuration.mountedUI,
            "sampleCount": result.sampleCount,
            "tabs": result.baseTabCount,
            "visualEvidence": false,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: artifactURL.appendingPathExtension("summary.json"),
            options: .atomic
        )
    }
}
