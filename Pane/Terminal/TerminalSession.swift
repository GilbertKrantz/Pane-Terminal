import AppKit
import Combine
import Darwin
import Foundation
@preconcurrency import SwiftTerm

private struct BoundedByteTail {
    private let limit: Int
    private var storage = Data()
    private var discardedCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    var isEmpty: Bool {
        storage.count == discardedCount
    }

    var data: Data {
        Data(storage.dropFirst(discardedCount))
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }

        if data.count >= limit {
            storage = Data(data.suffix(limit))
            discardedCount = 0
            return
        }

        storage.append(data)
        let retainedCount = storage.count - discardedCount
        if retainedCount > limit {
            discardedCount += retainedCount - limit
        }

        // Compact in coarse batches so a long download does not copy the
        // entire tail for every small PTY chunk.
        if discardedCount >= 1_048_576 {
            storage = Data(storage.dropFirst(discardedCount))
            discardedCount = 0
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        discardedCount = 0
    }
}

/// SwiftTerm's delegate does not identify the source process for data events.
/// Give each shell generation its own bridge so bytes already queued by a
/// restarted shell can never be mistaken for output from the replacement.
private final class PTYProcessDelegateBridge: LocalProcessDelegate {
    let generation: UInt64
    private let dataHandler: ([UInt8], UInt64) -> Void
    private let terminationHandler: (LocalProcess, Int32?, UInt64) -> Void
    private let windowSizeProvider: () -> winsize

    init(
        generation: UInt64,
        dataHandler: @escaping ([UInt8], UInt64) -> Void,
        terminationHandler: @escaping (LocalProcess, Int32?, UInt64) -> Void,
        windowSizeProvider: @escaping () -> winsize
    ) {
        self.generation = generation
        self.dataHandler = dataHandler
        self.terminationHandler = terminationHandler
        self.windowSizeProvider = windowSizeProvider
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        dataHandler(Array(slice), generation)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        terminationHandler(source, exitCode, generation)
    }

    func getWindowSize() -> winsize {
        windowSizeProvider()
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject {
    struct SessionBoundary: Equatable {
        let sessionID: UUID
        let lifecycle: PersistedSessionLifecycle
        let startedAt: Date
        let lastActiveAt: Date
        let workingDirectory: String
        let shell: String
    }

    struct NewShellBoundary: Equatable {
        let workingDirectory: String
        let previousDirectoryUnavailable: Bool
    }

    @Published private(set) var mode: InputMode = .blocks
    @Published private(set) var isShellRunning = false
    @Published private(set) var shellExitStatus: Int32?
    @Published private(set) var terminalTitle = "Pane"
    @Published private(set) var currentDirectory: String?
    @Published private(set) var blockTimeline = CommandBlockTimeline()
    @Published private(set) var isAlternateScreenActive = false
    @Published private(set) var modeAttribution: InputModeAttribution = .manual
    @Published private(set) var inputRequirement: TerminalInputRequirement = .shellIdle
    @Published private(set) var terminalSecurityState: TerminalSecurityState = .normal
    @Published private(set) var runtimeStateDiagnostic: String?
    @Published private(set) var activeCommandVisibleLineCount = 1
    @Published var selectedBlockID: UUID?
    @Published var commandDraft = ""
    @Published var blockSearchText = ""
    @Published var blockSearchFilter: BlockSearchFilter = .all
    @Published private(set) var sessionBoundaries: [UUID: SessionBoundary] = [:]
    @Published private(set) var restoredSessionOrder: [UUID] = []
    @Published private(set) var newShellBoundary: NewShellBoundary?
    @Published private(set) var restoredBlockIDs: Set<UUID> = []
    @Published var isRestartConfirmationPresented = false
    @Published private(set) var lastShellRestartAt: Date?

    private(set) var history = CommandHistory()
    private var process: LocalProcess?
    private var processBridge: PTYProcessDelegateBridge?
    private var processGeneration: UInt64 = 0
    private var terminalView: TerminalView?
    private var authoritativeTerminalHostView: AuthoritativeTerminalHostView?
    private var suspendedCommandDraft: String?
    private var manualSecureInputActive = false
    private weak var liveCommandTerminalView: TerminalView?
    private var liveCommandTerminalBlockID: UUID?
    private var streamParser = BlockStreamParser()
    private var transcriptFilter = AlternateScreenTranscriptFilter()
    private var activeBlockOutput = BoundedByteTail(limit: 4 * 1_024 * 1_024)
    private var pendingLiveCommandOutput = Data()
    private var isLiveCommandFlushScheduled = false
    private var activeCommandCompletedLineCount = 0
    private var activeCommandHasCurrentLineContent = false
    private var windowSize = winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    private var shellConfiguration: ShellConfiguration
    private let commandAutocomplete = CommandAutocomplete()
    private let zshCompletionClient = WarmZshCompletionClient()
    private let runtimeStateController: RuntimeStateController?
    private let runtimeSessionID = UUID()
    private let runtimeSessionStartedAt = Date()
    private let sensitiveDataSanitizer = SensitiveDataSanitizer()
    private var restoredRuntimeEventKeys: Set<String> = []
    private var isCommandHistoryEnabled: Bool
    private var runtimeStateStartTask: Task<Void, Never>?
    private var isRuntimeStatePrepared: Bool
    private var zshCompletionEndpoint: WarmZshCompletionEndpoint?
    private var isShuttingDown = false
    private var isApplicationExitFinalized = false
    private var isShellIntegrationReady = false
    private var commandAwaitingStartID: UUID?
    private var shouldReturnToBlocksAfterAlternateScreen = false
    private var shouldRestoreBlocksViewportAfterAlternateScreen = false
    private var foregroundProcessTimer: Timer?
    private var lastForegroundSnapshot: ForegroundProcessSnapshot?

    var blocks: [CommandBlock] {
        blockTimeline.blocks
    }

    var visibleBlocks: [CommandBlock] {
        let query = BlockSearchQuery(text: blockSearchText, filter: blockSearchFilter)
        return blockTimeline.blocks.filter(query.matches)
    }

    var selectedBlock: CommandBlock? {
        guard let selectedBlockID else { return nil }
        return blockTimeline.block(id: selectedBlockID)
    }

    var isCommandActive: Bool {
        blockTimeline.activeBlockID != nil || commandAwaitingStartID != nil
    }

    var activeCommandBlock: CommandBlock? {
        if let activeBlockID = blockTimeline.activeBlockID {
            return blockTimeline.block(id: activeBlockID)
        }
        guard let commandAwaitingStartID else { return nil }
        return blockTimeline.block(id: commandAwaitingStartID)
    }

    var isSecureInputActive: Bool {
        terminalSecurityState.inputMode == .secure
    }

    var activeProcessLabel: String {
        if let activeBlock = activeCommandBlock {
            return activeBlock.processName
        }
        return isShellRunning ? "zsh · idle" : "Shell stopped"
    }

    init(
        shellConfiguration: ShellConfiguration = .loginZsh(),
        runtimeStateController: RuntimeStateController? = nil,
        commandHistoryEnabled: Bool = true
    ) {
        self.shellConfiguration = shellConfiguration
        self.runtimeStateController = runtimeStateController
        self.isCommandHistoryEnabled = commandHistoryEnabled
        self.isRuntimeStatePrepared = runtimeStateController == nil
        self.currentDirectory = shellConfiguration.workingDirectory
        super.init()
    }

    func makeAuthoritativeTerminalView() -> PaneTerminalView {
        if let terminalView = terminalView as? PaneTerminalView { return terminalView }
        let terminalView = PaneTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        terminalView.autoresizingMask = [.width, .height]
        terminalView.changeScrollback(10_000)
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.caretViewTracksFocus = true
        attach(terminalView: terminalView)
        return terminalView
    }

    func makeAuthoritativeTerminalHostView() -> AuthoritativeTerminalHostView {
        if let authoritativeTerminalHostView { return authoritativeTerminalHostView }
        let hostView = AuthoritativeTerminalHostView(
            terminalView: makeAuthoritativeTerminalView()
        )
        authoritativeTerminalHostView = hostView
        return hostView
    }

    func ensureAuthoritativeTerminalIsRunning() {
        _ = makeAuthoritativeTerminalHostView()
    }

    func attach(terminalView: TerminalView) {
        self.terminalView = terminalView
        terminalView.terminalDelegate = self
        if let terminalView = terminalView as? PaneTerminalView {
            terminalView.onAlternateScreenChanged = { [weak self] isActive in
                self?.handleAlternateScreenChanged(isActive)
            }
            terminalView.onTerminalResponse = { [weak self] data in
                guard let self else { return }
                _ = self.send(bytes: Array(data))
            }
        }
        updateWindowSize(from: terminalView)

        if process == nil, !isShuttingDown {
            startShell()
        }
    }

    func detach(terminalView: TerminalView) {
        guard self.terminalView === terminalView else { return }
        if let terminalView = terminalView as? PaneTerminalView {
            terminalView.onAlternateScreenChanged = nil
            terminalView.onTerminalResponse = nil
        }
        terminalView.terminalDelegate = nil
        self.terminalView = nil
    }

    /// Attaches a presentation-only terminal emulator for the active block.
    /// The primary terminal remains the sole PTY owner and TerminalViewDelegate.
    func attachLiveCommandTerminalView(_ terminalView: TerminalView, blockID: UUID) {
        guard blockTimeline.activeBlockID == blockID else { return }
        guard liveCommandTerminalView !== terminalView
            || liveCommandTerminalBlockID != blockID else { return }

        liveCommandTerminalView = terminalView
        liveCommandTerminalBlockID = blockID
        pendingLiveCommandOutput.removeAll(keepingCapacity: true)
        isLiveCommandFlushScheduled = false
        terminalView.terminalDelegate = nil
        terminalView.terminal.resetToInitialState()

        if !activeBlockOutput.isEmpty {
            terminalView.feed(byteArray: Array(activeBlockOutput.data)[...])
        }
    }

    func detachLiveCommandTerminalView(_ terminalView: TerminalView, blockID: UUID) {
        guard liveCommandTerminalView === terminalView,
              liveCommandTerminalBlockID == blockID else { return }
        pendingLiveCommandOutput.removeAll(keepingCapacity: true)
        isLiveCommandFlushScheduled = false
        liveCommandTerminalView = nil
        liveCommandTerminalBlockID = nil
    }

    func startShell(in workingDirectory: String? = nil) {
        guard !isShuttingDown, process?.running != true else { return }
        guard isRuntimeStatePrepared else {
            prepareRuntimeStateAndStartShell()
            return
        }

        shellExitStatus = nil
        isShellIntegrationReady = false
        streamParser = BlockStreamParser()
        transcriptFilter = AlternateScreenTranscriptFilter()
        let effectiveDirectory = Self.validatedWorkingDirectory(workingDirectory)
            ?? Self.validatedWorkingDirectory(currentDirectory)
            ?? Self.validatedWorkingDirectory(shellConfiguration.workingDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        currentDirectory = effectiveDirectory
        processGeneration &+= 1
        let generation = processGeneration
        let completionEndpoint = try? zshCompletionClient.makeEndpoint(
            for: generation
        )
        zshCompletionEndpoint = completionEndpoint
        let bridge = PTYProcessDelegateBridge(
            generation: generation,
            dataHandler: { [weak self] bytes, generation in
                MainActor.assumeIsolated {
                    self?.handleProcessData(bytes, generation: generation)
                }
            },
            terminationHandler: { [weak self] source, waitStatus, generation in
                MainActor.assumeIsolated {
                    self?.scheduleProcessTermination(
                        source,
                        waitStatus: waitStatus,
                        generation: generation
                    )
                }
            },
            windowSizeProvider: { [weak self] in
                MainActor.assumeIsolated {
                    self?.windowSize
                        ?? winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                }
            }
        )
        let newProcess = LocalProcess(delegate: bridge, dispatchQueue: .main)
        processBridge = bridge
        process = newProcess
        newProcess.startProcess(
            executable: shellConfiguration.executable,
            args: shellConfiguration.arguments,
            environment: shellConfiguration.environment,
            currentDirectory: effectiveDirectory
        )
        isShellRunning = newProcess.running

        if newProcess.running {
            startForegroundProcessMonitoring()
            let installationCommand: String
            if let completionEndpoint {
                installationCommand = ShellIntegration.installationCommand(
                    completionSocketPath: completionEndpoint.socketPath
                )
            } else {
                installationCommand = ShellIntegration.installationCommand
            }
            newProcess.send(
                data: CommandSerializer.serializeCommand(
                    installationCommand
                )[...]
            )
        } else {
            process = nil
            processBridge = nil
            invalidateCompletionEndpoint()
            terminalView?.feed(text: "\r\n[Unable to start \(shellConfiguration.executable)]\r\n")
        }
    }

    func restartShell() {
        let activeOutput = finalizedActiveBlockOutput()
        blockTimeline.interruptUnfinished(activeOutput: activeOutput)
        clearActiveBlockCapture()
        let oldProcess = process
        process = nil
        processBridge = nil
        isShellRunning = false
        commandAwaitingStartID = nil
        isShellIntegrationReady = false
        terminateAndReap(oldProcess)
        invalidateCompletionEndpoint()
        stopForegroundProcessMonitoring()
        leaveAlternateScreenIfNeeded()
        terminalView?.feed(text: "\r\n[Restarting shell]\r\n")
        lastShellRestartAt = Date()
        startShell()
    }

    func requestRestartShell() {
        if isCommandActive {
            isRestartConfirmationPresented = true
        } else {
            restartShell()
        }
    }

    func confirmRestartShell() {
        isRestartConfirmationPresented = false
        restartShell()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let activeOutput = finalizedActiveBlockOutput()
        blockTimeline.interruptUnfinished(activeOutput: activeOutput)
        stopProcessForShutdown()
    }

    private func stopProcessForShutdown() {
        clearActiveBlockCapture()
        let oldProcess = process
        process = nil
        processBridge = nil
        isShellRunning = false
        commandAwaitingStartID = nil
        isShellIntegrationReady = false
        terminateAndReap(oldProcess)
        invalidateCompletionEndpoint()
        stopForegroundProcessMonitoring()
        zshCompletionClient.shutdown()
    }

    /// App termination does not need to repaint status into a disappearing
    /// SwiftUI hierarchy.  Clearing the process reference first also makes a
    /// later LocalProcess callback a no-op.
    func terminateForApplicationExit() {
        guard !isShuttingDown || process != nil else { return }
        isShuttingDown = true
        stopProcessForShutdown()
    }

    func finalizeApplicationExit() async {
        guard !isApplicationExitFinalized else { return }
        isApplicationExitFinalized = true
        let activeID = blockTimeline.activeBlockID ?? commandAwaitingStartID
        isShuttingDown = true
        let activeOutput = finalizedActiveBlockOutput()
        blockTimeline.interruptUnfinished(activeOutput: activeOutput)
        if let activeID,
           let block = blockTimeline.block(id: activeID),
           block.origin == .live,
           block.isRerunnable,
           let runtimeStateController {
            let output = sensitiveDataSanitizer.sanitizeOutput(block.output).value
            let event = PersistedCommandEvent(
                blockID: block.id,
                sessionID: runtimeSessionID,
                timestamp: block.completedAt ?? Date(),
                workingDirectory: block.workingDirectory,
                command: block.command,
                exitCode: nil,
                durationMilliseconds: block.duration.map { Int(($0 * 1_000).rounded()) },
                sanitizedOutputSummary: output.isEmpty ? nil : String(output.prefix(1_000)),
                sanitizedErrorSummary: nil,
                predictionSource: nil,
                predictionAction: nil,
                completion: .interrupted,
                isCollapsed: block.isCollapsed,
                outputKind: output.isEmpty ? .none : .excerpt
            )
            _ = await runtimeStateController.persistCommandEvent(event)
        }
        _ = await runtimeStateController?.closeCurrentSessionCleanly()
        stopProcessForShutdown()
    }

    func submitDraft() {
        if blockTimeline.activeBlockID != nil {
            refreshForegroundProcessMode()
            guard terminalSecurityState.inputMode == .normal,
                  inputRequirement != .direct,
                  inputRequirement != .secure else {
                focusAuthoritativeTerminal()
                return
            }
            guard send(bytes: CommandSerializer.serializeInputLine(commandDraft)) else { return }
            commandDraft = ""
            return
        }

        if let awaitingID = commandAwaitingStartID {
            let continuation = commandDraft
            guard send(bytes: CommandSerializer.serializeInputLine(continuation)) else { return }
            if let fullCommand = blockTimeline.appendContinuation(
                continuation,
                to: awaitingID
            ) {
                let sanitized = sensitiveDataSanitizer.sanitizeCommand(fullCommand)
                if isCommandHistoryEnabled, sanitized.redactionCount == 0 {
                    history.replaceMostRecent(with: sanitized.value)
                } else if isCommandHistoryEnabled {
                    history.removeMostRecent()
                }
            }
            commandDraft = ""
            return
        }

        submit(command: commandDraft)
    }

    func submit(command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let blockID = blockTimeline.enqueue(
            command: command,
            workingDirectory: currentDirectory ?? shellConfiguration.workingDirectory,
            isRerunnable: sensitiveDataSanitizer.sanitizeCommand(command).redactionCount == 0
        )

        if !isCommandActive, isShellIntegrationReady {
            guard send(bytes: CommandSerializer.serializeCommand(command)) else {
                blockTimeline.remove(id: blockID)
                return
            }
            commandAwaitingStartID = blockID
        }

        selectedBlockID = blockID
        inputRequirement = .lineOriented
        let sanitizedCommand = sensitiveDataSanitizer.sanitizeCommand(command)
        if isCommandHistoryEnabled, sanitizedCommand.redactionCount == 0 {
            history.append(sanitizedCommand.value)
        } else {
            history.resetNavigation()
        }
        commandDraft = ""
    }

    func historyPrevious() {
        commandDraft = history.previous(currentDraft: commandDraft)
    }

    func historyNext() {
        commandDraft = history.next(currentDraft: commandDraft)
    }

    func autocompleteSuggestions(
        for draft: String,
        cursorUTF16Offset: Int
    ) async -> [CommandAutocompleteSuggestion] {
        guard terminalSecurityState.inputMode == .normal,
              mode == .blocks,
              isShellRunning,
              isShellIntegrationReady,
              !isCommandActive,
              !isAlternateScreenActive,
              terminalView?.terminal.isCurrentBufferAlternate != true,
              let endpoint = zshCompletionEndpoint,
              endpoint.generation == processGeneration else {
            return []
        }

        let directory = URL(
            fileURLWithPath: currentDirectory ?? shellConfiguration.workingDirectory,
            isDirectory: true
        )
        let generation = processGeneration
        let response = await zshCompletionClient.completions(
            for: draft,
            cursorUTF16Offset: cursorUTF16Offset,
            endpoint: endpoint
        )
        guard !Task.isCancelled,
              mode == .blocks,
              processGeneration == generation,
              zshCompletionEndpoint == endpoint,
              !isCommandActive,
              !isAlternateScreenActive,
              terminalSecurityState.inputMode == .normal else {
            return []
        }

        if let response, response.status == .ok {
            let captured = response.candidates.map {
                ZshCompletionCandidate(
                    replacementText: $0.replacementText,
                    detail: $0.detail,
                    isDirectory: $0.isDirectory
                )
            }
            return commandAutocomplete.capturedSuggestions(captured)
        }

        // If zsh startup, zpty, or a completion function fails, keep the
        // composer useful with the bounded local engine. A valid empty zsh
        // result remains empty and never falls through to heuristic matches.
        return commandAutocomplete.suggestions(
            for: draft,
            cursorUTF16Offset: cursorUTF16Offset,
            history: history.commands,
            currentDirectory: directory,
            executableSearchPath: shellEnvironmentValue(named: "PATH")
        )
    }

    func autocompleteEdit(
        for suggestion: CommandAutocompleteSuggestion,
        in draft: String,
        cursorUTF16Offset: Int
    ) -> CommandAutocompleteEdit {
        commandAutocomplete.accept(
            suggestion,
            in: draft,
            cursorUTF16Offset: cursorUTF16Offset
        )
    }

    func toggleMode() {
        shouldReturnToBlocksAfterAlternateScreen = false
        modeAttribution = .manual
        mode.toggle()
        inputRequirement = mode == .terminal
            ? (isSecureInputActive ? .secure : .direct)
            : (isCommandActive ? .lineOriented : .shellIdle)
    }

    func setMode(_ newMode: InputMode) {
        guard mode != newMode else { return }
        shouldReturnToBlocksAfterAlternateScreen = false
        modeAttribution = .manual
        mode = newMode
        inputRequirement = newMode == .terminal
            ? (isSecureInputActive ? .secure : .direct)
            : (isCommandActive ? .lineOriented : .shellIdle)
    }

    func selectBlock(_ id: UUID) {
        selectedBlockID = id
    }

    func selectPreviousBlock() {
        moveSelection(by: -1)
    }

    func selectNextBlock() {
        moveSelection(by: 1)
    }

    func copyCommand(id: UUID) {
        guard let block = blockTimeline.block(id: id) else { return }
        writeToPasteboard(block.command)
    }

    func copyOutput(id: UUID) {
        guard let block = blockTimeline.block(id: id) else { return }
        writeToPasteboard(block.output)
    }

    func copyCommandAndOutput(id: UUID) {
        guard let block = blockTimeline.block(id: id) else { return }
        writeToPasteboard(block.output.isEmpty ? block.command : "\(block.command)\n\n\(block.output)")
    }

    func copySanitizedBlock(id: UUID) {
        guard let block = blockTimeline.block(id: id) else { return }
        let command = sensitiveDataSanitizer.sanitizeCommand(block.command).value
        let output = sensitiveDataSanitizer.sanitizeOutput(block.output).value
        writeToPasteboard(output.isEmpty ? command : "\(command)\n\n\(output)")
    }

    func copyWorkingDirectory(id: UUID) {
        guard let block = blockTimeline.block(id: id) else { return }
        writeToPasteboard(block.workingDirectory)
    }

    func rerunBlock(id: UUID) {
        editBlock(id: id)
    }

    func runAgainBlock(id: UUID) {
        guard let block = blockTimeline.block(id: id), block.isRerunnable else { return }
        submit(command: block.command)
    }

    func runBlockInOriginalDirectory(id: UUID) {
        guard let block = blockTimeline.block(id: id), block.isRerunnable else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: block.workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            runtimeStateDiagnostic = "The original working directory no longer exists. The command was placed in the composer instead."
            editBlock(id: id)
            return
        }
        let escapedDirectory = "'" + block.workingDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        commandDraft = "cd -- \(escapedDirectory) && \(block.command)"
        setMode(.blocks)
    }

    func rerunSelectedBlock() {
        guard let selectedBlockID else { return }
        rerunBlock(id: selectedBlockID)
    }

    func editBlock(id: UUID) {
        guard let block = blockTimeline.block(id: id), block.isRerunnable else { return }
        commandDraft = block.command
        modeAttribution = .manual
        mode = .blocks
    }

    func editSelectedBlock() {
        guard let selectedBlockID else { return }
        editBlock(id: selectedBlockID)
    }

    func toggleBlockCollapsed(id: UUID) {
        blockTimeline.toggleCollapsed(id: id)
        guard let block = blockTimeline.block(id: id), let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.updateCommandEventCollapsed(
                id,
                isCollapsed: block.isCollapsed
            )
        }
    }

    func setAllCompletedBlocksCollapsed(_ collapsed: Bool) {
        let ids = blockTimeline.blocks.filter { block in
            switch block.state {
            case .completed, .interrupted, .unknown: return true
            case .queued, .running: return false
            }
        }.map(\.id)
        blockTimeline.setAllCompletedCollapsed(collapsed)
        guard let runtimeStateController else { return }
        Task { [weak self] in
            for id in ids {
                if let diagnostic = await runtimeStateController.updateCommandEventCollapsed(id, isCollapsed: collapsed) {
                    self?.runtimeStateDiagnostic = diagnostic
                }
            }
        }
    }

    func selectNextSearchMatch() {
        moveSearchSelection(by: 1)
    }

    func selectPreviousSearchMatch() {
        moveSearchSelection(by: -1)
    }

    func removeBlock(id: UUID) {
        if blockTimeline.activeBlockID == id {
            clearActiveBlockCapture()
        }
        blockTimeline.remove(id: id)
        if selectedBlockID == id {
            selectedBlockID = blockTimeline.blocks.last?.id
        }
    }

    func clearBlocks() {
        blockTimeline.clearFinalized()
        if let selectedBlockID,
           blockTimeline.block(id: selectedBlockID) == nil {
            self.selectedBlockID = nil
        }
    }

    func sendInterrupt() {
        _ = send(bytes: [0x03])
    }

    func sendEndOfFile() {
        _ = send(bytes: [0x04])
    }

    func enterDirectInput() {
        modeAttribution = .manual
        inputRequirement = terminalSecurityState.inputMode == .secure ? .secure : .direct
        if !isCommandActive {
            mode = .terminal
        }
        focusAuthoritativeTerminal()
    }

    func focusComposer() {
        guard !isSecureInputActive else { return }
        setMode(.blocks)
        inputRequirement = isCommandActive ? .lineOriented : .shellIdle
    }

    func focusDirectTerminal() {
        enterDirectInput()
    }

    func copyLocalDiagnostics(includeSanitizedCommandContext: Bool = false) {
        let paneVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"
        let persistenceStatus = runtimeStateDiagnostic == nil ? "available" : "degraded"
        let databaseHealth = runtimeStateDiagnostic == nil ? "healthy" : "warning"
        var lines = [
            "Pane version: \(paneVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(Self.architectureName)",
            "Shell: \(shellConfiguration.executable)",
            "Presentation: \(mode.rawValue)",
            "Input requirement: \(String(describing: inputRequirement))",
            "Secure input active: \(isSecureInputActive)",
            "Alternate screen active: \(isAlternateScreenActive)",
            "PTY size: \(windowSize.ws_col)x\(windowSize.ws_row)",
            "Persistence: \(persistenceStatus)",
            "Database health: \(databaseHealth)",
            "SwiftTerm: 1.14.0"
        ]
        if includeSanitizedCommandContext, let block = selectedBlock {
            lines.append("Sanitized command: \(sensitiveDataSanitizer.sanitizeCommand(block.command).value)")
        }
        writeToPasteboard(lines.joined(separator: "\n"))
    }

    func enterSecureInput() {
        manualSecureInputActive = true
        activateSecureInput(source: .manualOverride)
        modeAttribution = .secureInput
        inputRequirement = .secure
        if !isCommandActive {
            mode = .terminal
        }
        focusAuthoritativeTerminal()
    }

    func exitSecureInput() {
        manualSecureInputActive = false
        updateSecurityState(echoEnabled: true, source: .manualOverride)
    }

    func clearTerminal() {
        terminalView?.feed(text: "\u{001B}[2J\u{001B}[3J\u{001B}[H")
    }

    private func handleProcessData(_ bytes: [UInt8], generation: UInt64) {
        guard generation == processGeneration, process != nil else { return }
        refreshForegroundProcessMode()

        // The persistent direct terminal is fed exactly once. The live block
        // terminal below is an independent emulator and receives parsed block
        // output, never a second feed through this primary view.
        terminalView?.feed(byteArray: bytes[...])

        let transcriptBytes = transcriptFilter.consume(Data(bytes))
        handleStreamEvents(streamParser.consume(transcriptBytes))
    }

    private func handleStreamEvents(_ events: [BlockStreamParser.Event]) {
        for event in events {
            switch event {
            case .output(let data):
                routeActiveBlockOutput(data)

            case .commandStarted(let command):
                // The bootstrap command installs these hooks. Existing hooks
                // in a user's zshrc may emit START for that bootstrap itself;
                // it is intentionally not represented as a user block.
                guard isShellIntegrationReady else { continue }
                if commandAwaitingStartID == nil, let command {
                    enqueueDirectTerminalCommand(command)
                }
                if let id = blockTimeline.beginNext() {
                    commandAwaitingStartID = nil
                    beginActiveBlockCapture(blockID: id)
                    selectedBlockID = id
                }

            case .commandFinished(let exitCode, let workingDirectory):
                handleNormalPromptBoundary()
                if currentDirectory != workingDirectory {
                    currentDirectory = workingDirectory
                }
                if let runtimeStateController {
                    Task { [weak self] in
                        if let diagnostic = await runtimeStateController.updateCurrentSessionActivity(
                            workingDirectory: workingDirectory
                        ) {
                            self?.runtimeStateDiagnostic = diagnostic
                        }
                    }
                }

                if !isShellIntegrationReady {
                    isShellIntegrationReady = true
                    dispatchNextQueuedCommandIfNeeded()
                    continue
                }

                if blockTimeline.activeBlockID != nil {
                    let output = finalizedActiveBlockOutput()
                    if exitCode == 128 + SIGINT,
                       let activeID = blockTimeline.activeBlockID {
                        blockTimeline.interruptActive(
                            exitCode: exitCode,
                            output: output
                        )
                        selectedBlockID = activeID
                        persistCompletedBlock(id: activeID)
                    } else {
                        if let id = blockTimeline.finishActive(
                            exitCode: exitCode,
                            output: output
                        ) {
                            selectedBlockID = id
                            persistCompletedBlock(id: id)
                        }
                    }
                    clearActiveBlockCapture()
                } else if let awaitingID = commandAwaitingStartID {
                    // zsh emits precmd after an interrupted/incomplete buffer
                    // without ever running preexec. Finalize that pending
                    // command so the local queue cannot remain wedged.
                    blockTimeline.interruptQueued(
                        id: awaitingID,
                        exitCode: exitCode
                    )
                    commandAwaitingStartID = nil
                    selectedBlockID = awaitingID
                }
                dispatchNextQueuedCommandIfNeeded()
            }
        }
    }

    private func scheduleProcessTermination(
        _ source: LocalProcess,
        waitStatus: Int32?,
        generation: UInt64
    ) {
        // SwiftTerm's process monitor can fire before its already-read PTY
        // chunks have drained onto the main queue. One short turn preserves
        // the final prompt/output without keeping terminal frames in SwiftUI.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self, weak source] in
            guard let self, let source else { return }
            self.handleProcessTermination(
                source,
                waitStatus: waitStatus,
                generation: generation
            )
        }
    }

    private func handleProcessTermination(
        _ source: LocalProcess,
        waitStatus: Int32?,
        generation: UInt64
    ) {
        guard generation == processGeneration, process === source else { return }
        let exitCode = Self.normalizedExitCode(fromWaitStatus: waitStatus)

        let transcriptRemainder = transcriptFilter.flush()
        if !transcriptRemainder.isEmpty {
            handleStreamEvents(streamParser.consume(transcriptRemainder))
        }
        handleStreamEvents(streamParser.flush())

        let activeOutput = finalizedActiveBlockOutput()
        blockTimeline.interruptUnfinished(
            exitCode: exitCode,
            activeOutput: activeOutput
        )
        clearActiveBlockCapture()
        process = nil
        processBridge = nil
        isShellRunning = false
        isShellIntegrationReady = false
        commandAwaitingStartID = nil
        invalidateCompletionEndpoint()
        stopForegroundProcessMonitoring()
        shellExitStatus = exitCode
        leaveAlternateScreenIfNeeded()
        terminalView?.feed(
            text: "\r\n[Shell exited\(exitCode.map { " with status \($0)" } ?? "")]\r\n"
        )
    }

    /// SwiftTerm 1.14 reports the raw `waitpid` status on its forkpty path.
    /// Convert it to the conventional shell exit code shown to users.
    nonisolated static func normalizedExitCode(fromWaitStatus waitStatus: Int32?) -> Int32? {
        guard let waitStatus else { return nil }
        let terminatingSignal = waitStatus & 0x7F
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        if terminatingSignal == 0x7F {
            return nil
        }
        return 128 + terminatingSignal
    }

    private func terminateAndReap(_ process: LocalProcess?) {
        guard let process else { return }
        let pid = process.shellPid
        process.terminate()
        guard pid > 0 else { return }

        // LocalProcess.cancel() removes its process monitor before it can call
        // waitpid. Reap explicit restarts/shutdowns off the main actor so they
        // cannot leave zombie shells or stall AppKit teardown.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) == -1 {
                guard errno == EINTR else { return }
            }
        }
    }

    private func beginActiveBlockCapture(blockID: UUID) {
        guard blockTimeline.activeBlockID == blockID else { return }
        activeBlockOutput.removeAll()
        resetActiveCommandLineEstimate()
        pendingLiveCommandOutput.removeAll(keepingCapacity: true)
        isLiveCommandFlushScheduled = false
        liveCommandTerminalView = nil
        liveCommandTerminalBlockID = nil
        persistPendingBlock(id: blockID)
    }

    private func persistPendingBlock(id: UUID) {
        guard let runtimeStateController,
              let block = blockTimeline.block(id: id),
              block.isRerunnable else { return }
        let event = PersistedCommandEvent(
            blockID: block.id,
            sessionID: runtimeSessionID,
            timestamp: block.startedAt ?? Date(),
            workingDirectory: block.workingDirectory,
            command: block.command,
            exitCode: nil,
            durationMilliseconds: nil,
            sanitizedOutputSummary: nil,
            sanitizedErrorSummary: nil,
            predictionSource: nil,
            predictionAction: nil,
            completion: .unknown,
            isCollapsed: block.isCollapsed
        )
        let startTask = runtimeStateStartTask
        Task { [weak self] in
            await startTask?.value
            self?.runtimeStateDiagnostic = await runtimeStateController.persistCommandEvent(event)
        }
    }

    private func dispatchNextQueuedCommandIfNeeded() {
        guard isShellIntegrationReady, !isCommandActive else { return }
        guard let nextCommand = blockTimeline.blocks.first(where: { block in
            if case .queued = block.state { return true }
            return false
        }) else { return }

        guard send(bytes: CommandSerializer.serializeCommand(nextCommand.command)) else { return }
        commandAwaitingStartID = nextCommand.id
        if mode == .blocks {
            inputRequirement = .lineOriented
        }
    }

    private func prepareRuntimeStateAndStartShell() {
        guard runtimeStateStartTask == nil, let runtimeStateController else { return }
        let directory = currentDirectory ?? shellConfiguration.workingDirectory
        let session = RuntimeSession(
            id: runtimeSessionID,
            workspaceID: Self.workspaceIdentifier(for: directory),
            repositoryID: nil,
            shell: shellConfiguration.executable,
            initialWorkingDirectory: directory,
            lastWorkingDirectory: directory,
            startedAt: runtimeSessionStartedAt,
            lastActiveAt: Date(),
            lifecycle: .active
        )

        runtimeStateStartTask = Task { [weak self] in
            let result = await runtimeStateController.startSession(session)
            guard let self else { return }
            self.runtimeStateDiagnostic = result.diagnostic
            if let context = result.restoredContext {
                self.restoreRuntimeContext(
                    context,
                    restoreCommandHistory: result.restoresCommandHistory,
                    restoreVisibleBlocks: result.restoresVisibleBlocks
                )
            }
            self.isRuntimeStatePrepared = true
            self.startShell()
        }
    }

    func restoreRuntimeContext(
        _ context: PersistedRuntimeContext,
        restoreCommandHistory: Bool,
        restoreVisibleBlocks: Bool
    ) {
        if restoreCommandHistory { restorePredictionHistory(from: context) }
        guard restoreVisibleBlocks else { return }
        let previousSessions = context.sessions.filter { $0.id != runtimeSessionID }
        guard let previous = previousSessions.max(by: { $0.lastActiveAt < $1.lastActiveAt }) else { return }

        let preferredDirectory = previous.lastWorkingDirectory.isEmpty
            ? previous.initialWorkingDirectory
            : previous.lastWorkingDirectory
        let latestEventDirectory = context.commandEvents
            .filter { $0.sessionID == previous.id }
            .max(by: { $0.timestamp < $1.timestamp })?
            .workingDirectory
        let directoryCandidates: [String?] = [
            preferredDirectory,
            latestEventDirectory,
            previous.initialWorkingDirectory,
            shellConfiguration.workingDirectory,
            FileManager.default.homeDirectoryForCurrentUser.path
        ]
        let restoredDirectory = directoryCandidates
            .compactMap(Self.validatedWorkingDirectory)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.path
        shellConfiguration.workingDirectory = restoredDirectory
        currentDirectory = restoredDirectory

        let sessionIDs = Set(previousSessions.map(\.id))
        var eventByBlockID: [UUID: PersistedCommandEvent] = [:]
        for event in context.commandEvents where sessionIDs.contains(event.sessionID) {
            guard let existing = eventByBlockID[event.blockID] else {
                eventByBlockID[event.blockID] = event
                continue
            }
            if Self.preferredRestorationEvent(event, over: existing) {
                eventByBlockID[event.blockID] = event
            }
        }
        let restoredBlocks = eventByBlockID.values
            .filter { sessionIDs.contains($0.sessionID) }
            .sorted { $0.timestamp < $1.timestamp }
            .map { event -> CommandBlock in
                let duration = TimeInterval(event.durationMilliseconds ?? 0) / 1_000
                let state: CommandBlock.ExecutionState
                switch event.completion {
                case .completed:
                    state = event.exitCode.map { .completed(exitCode: Int32($0)) } ?? .unknown
                case .interrupted:
                    state = .interrupted(exitCode: event.exitCode.map(Int32.init))
                case .unknown:
                    state = .unknown
                }
                return CommandBlock(
                    id: event.blockID,
                    command: event.command,
                    workingDirectory: event.workingDirectory,
                    submittedAt: event.timestamp.addingTimeInterval(-duration),
                    startedAt: event.timestamp.addingTimeInterval(-duration),
                    completedAt: event.timestamp,
                    state: state,
                    output: event.sanitizedOutputSummary ?? event.sanitizedErrorSummary ?? "",
                    isCollapsed: event.isCollapsed,
                    isRerunnable: Self.isRestoredCommandRerunnable(event.command),
                    origin: .restored(sessionID: event.sessionID),
                    outputKind: event.outputKind
                )
            }
        blockTimeline.restore(restoredBlocks)
        restoredBlockIDs.formUnion(restoredBlocks.map(\.id))
        sessionBoundaries = Dictionary(uniqueKeysWithValues: previousSessions.map { session in
            let workingDirectory = session.lastWorkingDirectory.isEmpty
                ? session.initialWorkingDirectory
                : session.lastWorkingDirectory
            return (session.id, SessionBoundary(
                sessionID: session.id,
                lifecycle: session.lifecycle,
                startedAt: session.startedAt,
                lastActiveAt: session.lastActiveAt,
                workingDirectory: workingDirectory,
                shell: session.shell
            ))
        })
        let sessionsWithCommands = Set(restoredBlocks.compactMap { block -> UUID? in
            if case .restored(let sessionID) = block.origin { return sessionID }
            return nil
        })
        restoredSessionOrder = previousSessions
            .filter { sessionsWithCommands.contains($0.id) || $0.lifecycle == .interrupted }
            .sorted {
                if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.startedAt < $1.startedAt
            }
            .map(\.id)
        newShellBoundary = NewShellBoundary(
            workingDirectory: restoredDirectory,
            previousDirectoryUnavailable: !preferredDirectory.isEmpty && restoredDirectory != preferredDirectory
        )
    }

    private static func preferredRestorationEvent(
        _ candidate: PersistedCommandEvent,
        over existing: PersistedCommandEvent
    ) -> Bool {
        if candidate.timestamp != existing.timestamp { return candidate.timestamp > existing.timestamp }
        func completeness(_ event: PersistedCommandEvent) -> Int {
            var score = event.completion == .unknown ? 0 : 4
            if event.exitCode != nil { score += 2 }
            if event.sanitizedOutputSummary != nil || event.sanitizedErrorSummary != nil { score += 1 }
            return score
        }
        return completeness(candidate) > completeness(existing)
    }

    private func persistCompletedBlock(id: UUID) {
        guard let runtimeStateController,
              let block = blockTimeline.block(id: id),
              block.origin == .live else { return }

        let exitCode: Int?
        switch block.state {
        case .completed(let code):
            exitCode = Int(code)
        case .interrupted(let code):
            exitCode = code.map(Int.init)
        case .queued, .running, .unknown:
            return
        }

        let sanitizedCommand = sensitiveDataSanitizer.sanitizeCommand(block.command)
        // A redacted string is not an exact, safely rerunnable command. Keep
        // the transient block, but do not turn it into durable history.
        guard sanitizedCommand.redactionCount == 0 else { return }
        let command = sanitizedCommand.value
        let output = sensitiveDataSanitizer.sanitizeOutput(block.output).value
        let summary = output.isEmpty ? nil : String(output.prefix(1_000))
        let durationMilliseconds = block.duration.map {
            max(0, Int(($0 * 1_000).rounded()))
        }
        let event = PersistedCommandEvent(
            blockID: block.id,
            sessionID: runtimeSessionID,
            timestamp: block.completedAt ?? Date(),
            workingDirectory: block.workingDirectory,
            command: command,
            exitCode: exitCode,
            durationMilliseconds: durationMilliseconds,
            sanitizedOutputSummary: exitCode == 0 ? summary : nil,
            sanitizedErrorSummary: exitCode == 0 ? nil : summary,
            predictionSource: nil,
            predictionAction: nil,
            completion: {
                if case .interrupted = block.state { return .interrupted }
                return .completed
            }(),
            isCollapsed: block.isCollapsed,
            outputKind: summary == nil ? .none : .excerpt
        )

        let startTask = runtimeStateStartTask
        Task { [weak self] in
            await startTask?.value
            let diagnostic = await runtimeStateController.persistCommandEvent(event)
            self?.runtimeStateDiagnostic = diagnostic
        }
    }

    private static func isRestoredCommandRerunnable(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(SensitiveDataSanitizer.redaction) else { return false }
        return trimmed != "[command omitted]" && trimmed != "<command omitted>"
    }

    private func restorePredictionHistory(from context: PersistedRuntimeContext) {
        for event in context.commandEvents.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = "\(event.sessionID.uuidString)|\(event.timestamp.timeIntervalSince1970)|\(event.command)"
            guard restoredRuntimeEventKeys.insert(key).inserted,
                  !event.command.contains(SensitiveDataSanitizer.redaction) else { continue }
            history.append(event.command)
        }
    }

    func applyRuntimeStateConfiguration(_ configuration: RuntimeStateConfiguration) {
        isCommandHistoryEnabled = configuration.commandHistoryEnabled
        if !configuration.commandHistoryEnabled {
            history = CommandHistory()
            restoredRuntimeEventKeys.removeAll()
        }
        guard let runtimeStateController else { return }
        Task { [weak self] in
            let result = await runtimeStateController.updateConfiguration(configuration)
            guard let self else { return }
            self.runtimeStateDiagnostic = result.diagnostic
            if let context = result.restoredContext {
                self.restoreRuntimeContext(
                    context,
                    restoreCommandHistory: result.restoresCommandHistory,
                    restoreVisibleBlocks: result.restoresVisibleBlocks
                )
            }
        }
    }

    func clearCurrentSessionPredictionHistory() {
        history = CommandHistory()
        restoredRuntimeEventKeys.removeAll()
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.deleteCurrentSession()
        }
    }

    func clearCurrentWorkspacePredictionHistory() {
        history = CommandHistory()
        restoredRuntimeEventKeys.removeAll()
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.deleteCurrentWorkspace()
        }
    }

    func clearAllPredictionHistory() {
        history = CommandHistory()
        restoredRuntimeEventKeys.removeAll()
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.deleteAllState()
        }
    }

    func clearPreviousSessions() {
        for id in restoredBlockIDs { blockTimeline.remove(id: id) }
        restoredBlockIDs.removeAll()
        sessionBoundaries.removeAll()
        restoredSessionOrder.removeAll()
        newShellBoundary = nil
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.deletePreviousSessions()
        }
    }

    func clearExactCommandHistory() {
        history = CommandHistory()
        blockTimeline.clearFinalized()
        restoredBlockIDs.removeAll()
        sessionBoundaries.removeAll()
        restoredSessionOrder.removeAll()
        newShellBoundary = nil
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.deleteExactCommandHistory()
        }
    }

    func clearPersistedBlockOutput() {
        blockTimeline.clearFinalizedOutput()
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.clearPersistedBlockOutput()
        }
    }

    func revealLocalDataLocation() {
        guard let runtimeStateController else { return }
        Task {
            let url = await runtimeStateController.localDataDirectory()
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealRecoveryFile() {
        guard let runtimeStateController else { return }
        Task {
            guard let url = await runtimeStateController.recoveryFile() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func clearRecoveryFile() {
        guard let runtimeStateController else { return }
        Task { [weak self] in
            self?.runtimeStateDiagnostic = await runtimeStateController.clearRecoveryFile()
        }
    }

    nonisolated private static func validatedWorkingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    nonisolated private static func workspaceIdentifier(for directory: String) -> String {
        URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL.path
    }

    private func routeActiveBlockOutput(_ data: Data) {
        guard !data.isEmpty, let activeBlockID = blockTimeline.activeBlockID else { return }
        activeBlockOutput.append(data)
        updateActiveCommandLineEstimate(with: data)

        guard liveCommandTerminalBlockID == activeBlockID,
              liveCommandTerminalView != nil else { return }
        pendingLiveCommandOutput.append(data)
        scheduleLiveCommandOutputFlush()
    }

    private func finalizedActiveBlockOutput() -> String {
        guard blockTimeline.activeBlockID != nil else { return "" }

        flushPendingLiveCommandOutput()

        if liveCommandTerminalBlockID == blockTimeline.activeBlockID,
           let liveCommandTerminalView {
            return Self.renderedTranscript(from: liveCommandTerminalView)
        }

        return BlockOutputSanitizer.sanitize(activeBlockOutput.data)
    }

    private func clearActiveBlockCapture() {
        activeBlockOutput.removeAll()
        resetActiveCommandLineEstimate()
        pendingLiveCommandOutput.removeAll(keepingCapacity: true)
        isLiveCommandFlushScheduled = false
        liveCommandTerminalView = nil
        liveCommandTerminalBlockID = nil
    }

    private func scheduleLiveCommandOutputFlush() {
        guard !isLiveCommandFlushScheduled else { return }
        isLiveCommandFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingLiveCommandOutput()
        }
    }

    private func flushPendingLiveCommandOutput() {
        isLiveCommandFlushScheduled = false
        guard !pendingLiveCommandOutput.isEmpty else { return }
        let output = pendingLiveCommandOutput
        pendingLiveCommandOutput.removeAll(keepingCapacity: true)

        guard liveCommandTerminalBlockID == blockTimeline.activeBlockID,
              let liveCommandTerminalView else { return }
        liveCommandTerminalView.feed(byteArray: Array(output)[...])
    }

    /// Estimate only the number of newline-delimited rows needed by the live
    /// composer, capped at ten. This publishes at most nine small layout
    /// changes per command instead of sending terminal frames through SwiftUI.
    private func updateActiveCommandLineEstimate(with data: Data) {
        guard activeCommandVisibleLineCount < 10 else { return }

        for byte in data {
            switch byte {
            case 0x0A:
                activeCommandCompletedLineCount += 1
                activeCommandHasCurrentLineContent = false
            case 0x0D:
                // Carriage-return progress replaces the current row.
                break
            default:
                activeCommandHasCurrentLineContent = true
            }

            if activeCommandCompletedLineCount >= 10 { break }
        }

        let estimate = min(
            10,
            max(
                1,
                activeCommandCompletedLineCount
                    + (activeCommandHasCurrentLineContent ? 1 : 0)
            )
        )
        if activeCommandVisibleLineCount != estimate {
            activeCommandVisibleLineCount = estimate
        }
    }

    private func resetActiveCommandLineEstimate() {
        activeCommandCompletedLineCount = 0
        activeCommandHasCurrentLineContent = false
        if activeCommandVisibleLineCount != 1 {
            activeCommandVisibleLineCount = 1
        }
    }

    static func renderedTranscript(from terminalView: TerminalView) -> String {
        guard let terminal = terminalView.terminal else { return "" }

        var row = terminal.buffer.totalLinesTrimmed
        var lines: [String] = []

        while let line = terminal.getScrollInvariantLine(row: row) {
            lines.append(line.translateToString(trimRight: true))
            row += 1
        }

        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        return lines
            .joined(separator: "\n")
    }

    private func moveSelection(by offset: Int) {
        let blocks = blockTimeline.blocks
        guard !blocks.isEmpty else { return }

        guard let selectedBlockID,
              let currentIndex = blocks.firstIndex(where: { $0.id == selectedBlockID }) else {
            self.selectedBlockID = offset < 0 ? blocks.last?.id : blocks.first?.id
            return
        }

        let targetIndex = min(max(0, currentIndex + offset), blocks.count - 1)
        self.selectedBlockID = blocks[targetIndex].id
    }

    private func moveSearchSelection(by offset: Int) {
        let matches = visibleBlocks
        guard !matches.isEmpty else { return }
        guard let selectedBlockID,
              let index = matches.firstIndex(where: { $0.id == selectedBlockID }) else {
            self.selectedBlockID = offset < 0 ? matches.last?.id : matches.first?.id
            return
        }
        let next = (index + offset + matches.count) % matches.count
        self.selectedBlockID = matches[next].id
    }

    nonisolated private static var architectureName: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private func writeToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func handleAlternateScreenChanged(_ isActive: Bool) {
        guard isAlternateScreenActive != isActive else { return }
        isAlternateScreenActive = isActive

        if isActive {
            if mode == .blocks {
                shouldReturnToBlocksAfterAlternateScreen = true
                // TUIs commonly disable ECHO immediately before entering the
                // alternate screen. If that brief transition was classified
                // as secure input, the alternate-screen protocol is the more
                // specific signal: keep routing bytes through SwiftTerm, but
                // do not label the entire TUI as a password prompt. An
                // explicit manual Secure Input choice remains sticky.
                if isSecureInputActive, !manualSecureInputActive {
                    updateSecurityState(
                        echoEnabled: true,
                        source: .applicationSignal
                    )
                }
                modeAttribution = .alternateScreen
                inputRequirement = .direct
                announceAccessibility("Direct terminal input activated")
                focusAuthoritativeTerminal()
            } else {
                shouldReturnToBlocksAfterAlternateScreen = false
            }
        } else {
            if shouldReturnToBlocksAfterAlternateScreen {
                shouldRestoreBlocksViewportAfterAlternateScreen = true
                modeAttribution = .manual
                inputRequirement = isCommandActive ? .lineOriented : .shellIdle
                // Re-evaluate immediately after the protocol-owned mode ends.
                // The same foreground process may still require raw input.
                lastForegroundSnapshot = nil
            }
            shouldReturnToBlocksAfterAlternateScreen = false
        }
    }

    func consumeBlocksViewportRestoreRequest() -> Bool {
        guard shouldRestoreBlocksViewportAfterAlternateScreen else { return false }
        shouldRestoreBlocksViewportAfterAlternateScreen = false
        return true
    }

    private func startForegroundProcessMonitoring() {
        foregroundProcessTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshForegroundProcessMode()
            }
        }
        foregroundProcessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshForegroundProcessMode()
    }

    private func stopForegroundProcessMonitoring() {
        foregroundProcessTimer?.invalidate()
        foregroundProcessTimer = nil
        lastForegroundSnapshot = nil
        updateSecurityState(echoEnabled: true, source: .terminalEchoState)
        if modeAttribution != .manual {
            modeAttribution = .manual
        }
    }

    private func refreshForegroundProcessMode() {
        guard isShellRunning, !isAlternateScreenActive else { return }
        guard let snapshot = foregroundProcessSnapshot() else { return }

        // zsh's idle ZLE can temporarily disable ECHO while it owns the
        // foreground process group. That is ordinary prompt editing, not a
        // password request. Once preexec has started a tracked command, an
        // ECHO-off shell foreground is meaningful again (for example read -s).
        let isIdleShellLineEditor = snapshot.isShellForeground
            && blockTimeline.activeBlockID == nil
        updateSecurityState(
            echoEnabled: isIdleShellLineEditor ? true : snapshot.echoEnabled,
            source: .terminalEchoState
        )

        guard snapshot != lastForegroundSnapshot else { return }
        lastForegroundSnapshot = snapshot

        if let attribution = snapshot.terminalModeAttribution {
            if mode != .terminal {
                let wasDirect = inputRequirement == .direct || inputRequirement == .secure
                inputRequirement = terminalSecurityState.inputMode == .secure ? .secure : .direct
                modeAttribution = terminalSecurityState.inputMode == .secure
                    ? .secureInput
                    : attribution
                if !wasDirect {
                    announceAccessibility("Direct terminal input activated")
                }
                focusAuthoritativeTerminal()
            } else if terminalSecurityState.inputMode == .secure {
                modeAttribution = .secureInput
            } else if modeAttribution != attribution {
                modeAttribution = attribution
            }
        } else if snapshot.isShellForeground, modeAttribution != .manual {
            modeAttribution = .manual
            inputRequirement = isCommandActive ? .lineOriented : .shellIdle
        } else if snapshot.isShellForeground {
            inputRequirement = isCommandActive ? .lineOriented : .shellIdle
        }
    }

    private func updateSecurityState(
        echoEnabled: Bool,
        source: SecureInputDetectionSource
    ) {
        let inputMode: TerminalInputMode = echoEnabled ? .normal : .secure
        if manualSecureInputActive, inputMode == .normal {
            return
        }
        guard terminalSecurityState.inputMode != inputMode
            || terminalSecurityState.echoEnabled != echoEnabled else { return }

        if inputMode == .secure {
            activateSecureInput(source: source)
            return
        } else if !manualSecureInputActive, terminalSecurityState.inputMode == .secure {
            if commandDraft.isEmpty, let suspendedCommandDraft {
                commandDraft = suspendedCommandDraft
            }
            suspendedCommandDraft = nil
            inputRequirement = isCommandActive ? .lineOriented : .shellIdle
        }
        terminalSecurityState = TerminalSecurityState(
            inputMode: inputMode,
            echoEnabled: echoEnabled,
            detectedAt: Date(),
            source: source
        )
    }

    private func activateSecureInput(source: SecureInputDetectionSource) {
        let wasSecure = terminalSecurityState.inputMode == .secure
        if !wasSecure {
            if !commandDraft.isEmpty {
                suspendedCommandDraft = commandDraft
            }
            commandDraft = ""
            history.resetNavigation()
        }
        modeAttribution = .secureInput
        inputRequirement = .secure
        terminalSecurityState = TerminalSecurityState(
            inputMode: .secure,
            echoEnabled: false,
            detectedAt: Date(),
            source: source
        )
        if !wasSecure {
            announceAccessibility("Secure input activated")
        }
    }

    private func announceAccessibility(_ message: String) {
        let element: Any
        if let terminalView {
            element = terminalView
        } else {
            element = NSApplication.shared
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func focusAuthoritativeTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let terminalView = self?.terminalView else { return }
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    var shouldEmbedAuthoritativeTerminalInActiveBlock: Bool {
        activeTerminalPresentation != .none
    }

    var activeTerminalPresentation: ActiveTerminalPresentation {
        guard mode == .blocks, isCommandActive else { return .none }
        if isAlternateScreenActive { return .expanded }
        if inputRequirement == .direct || inputRequirement == .secure {
            return .compact
        }
        return .none
    }

    var shouldPresentExpandedAuthoritativeTerminal: Bool {
        activeTerminalPresentation == .expanded
    }

    var shouldPresentCompactAuthoritativeTerminal: Bool {
        activeTerminalPresentation == .compact
    }

    /// Pane's precmd marker is emitted only after the foreground command has
    /// returned to the persistent shell. It is the authoritative boundary for
    /// leaving secure input; a termios poll can otherwise miss a short ECHO
    /// transition or observe the shell line editor changing flags again.
    private func handleNormalPromptBoundary() {
        manualSecureInputActive = false
        updateSecurityState(echoEnabled: true, source: .applicationSignal)
        lastForegroundSnapshot = nil

        guard !isAlternateScreenActive else { return }
        if mode == .terminal {
            inputRequirement = .direct
            return
        }
        modeAttribution = .manual
        inputRequirement = .shellIdle
    }

    private func enqueueDirectTerminalCommand(_ command: String) {
        let sanitized = sensitiveDataSanitizer.sanitizeCommand(command)
        let visibleCommand = sanitized.redactionCount == 0
            ? sanitized.value
            : "[Sensitive command omitted]"
        let id = blockTimeline.enqueue(
            command: visibleCommand,
            workingDirectory: currentDirectory ?? shellConfiguration.workingDirectory,
            isRerunnable: sanitized.redactionCount == 0
        )
        commandAwaitingStartID = id
        selectedBlockID = id
        if isCommandHistoryEnabled, sanitized.redactionCount == 0 {
            history.append(sanitized.value)
        } else {
            history.resetNavigation()
        }
    }

    private func foregroundProcessSnapshot() -> ForegroundProcessSnapshot? {
        guard let process, process.childfd >= 0 else { return nil }
        let foregroundPGID = tcgetpgrp(process.childfd)
        guard foregroundPGID > 0 else { return nil }

        var termiosState = termios()
        let hasTermios = tcgetattr(process.childfd, &termiosState) == 0
        let localFlags = hasTermios ? termiosState.c_lflag : 0
        let echoEnabled = !hasTermios || (localFlags & tcflag_t(ECHO) != 0)
        let isRawInput = hasTermios
            && (localFlags & tcflag_t(ICANON) == 0 || !echoEnabled)
        let shellPGID = process.shellPid > 0 ? getpgid(process.shellPid) : -1

        return ForegroundProcessSnapshot(
            processGroupID: foregroundPGID,
            shellProcessGroupID: shellPGID > 0 ? shellPGID : nil,
            processName: Self.processName(forProcessGroupID: foregroundPGID),
            isRawInput: isRawInput,
            echoEnabled: echoEnabled
        )
    }

    nonisolated private static func processName(forProcessGroupID pgid: pid_t) -> String? {
        if let groupLeaderName = processName(forPID: pgid) {
            return groupLeaderName
        }

        let requiredBytes = proc_listpgrppids(pgid, nil, 0)
        guard requiredBytes > 0 else { return nil }

        let pidSize = MemoryLayout<pid_t>.stride
        var groupPIDs = [pid_t](
            repeating: 0,
            count: (Int(requiredBytes) + pidSize - 1) / pidSize
        )
        let copiedBytes = groupPIDs.withUnsafeMutableBytes { buffer in
            proc_listpgrppids(pgid, buffer.baseAddress, Int32(buffer.count))
        }
        guard copiedBytes > 0 else { return nil }

        for pid in groupPIDs.prefix(Int(copiedBytes) / pidSize) where pid > 0 {
            if let name = processName(forPID: pid) {
                return name
            }
        }
        return nil
    }

    nonisolated private static func processName(forPID pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else {
            return nil
        }
        let name = String(cString: nameBuffer)
        return name.isEmpty ? nil : name
    }

    private func leaveAlternateScreenIfNeeded() {
        guard terminalView?.terminal.isCurrentBufferAlternate == true else {
            handleAlternateScreenChanged(false)
            return
        }

        terminalView?.feed(text: "\u{001B}[?1049l")
        handleAlternateScreenChanged(false)
    }

    private func send(bytes: [UInt8]) -> Bool {
        guard let process, process.running else { return false }
        process.send(data: bytes[...])
        return true
    }

    private func shellEnvironmentValue(named name: String) -> String? {
        let prefix = name + "="
        guard let entry = shellConfiguration.environment.first(where: {
            $0.hasPrefix(prefix)
        }) else { return nil }
        return String(entry.dropFirst(prefix.count))
    }

    private func invalidateCompletionEndpoint() {
        guard let endpoint = zshCompletionEndpoint else { return }
        zshCompletionEndpoint = nil
        zshCompletionClient.invalidate(endpoint)
    }

    private func updateWindowSize(from source: TerminalView) {
        let scale = source.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let columns = max(1, min(source.terminal.cols, Int(UInt16.max)))
        let rows = max(1, min(source.terminal.rows, Int(UInt16.max)))
        let pixelWidth = max(1, min(Int(source.bounds.width * scale), Int(UInt16.max)))
        let pixelHeight = max(1, min(Int(source.bounds.height * scale), Int(UInt16.max)))

        let newWindowSize = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: UInt16(pixelWidth),
            ws_ypixel: UInt16(pixelHeight)
        )

        guard newWindowSize.ws_row != windowSize.ws_row
            || newWindowSize.ws_col != windowSize.ws_col
            || newWindowSize.ws_xpixel != windowSize.ws_xpixel
            || newWindowSize.ws_ypixel != windowSize.ws_ypixel else { return }

        windowSize = newWindowSize

        if let process, process.running, process.childfd >= 0 {
            var size = windowSize
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: process.childfd,
                windowSize: &size
            )
        }
    }
}

extension TerminalSession: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated {
            guard self.terminalView === source,
                  self.mode == .terminal || self.inputRequirement == .direct || self.inputRequirement == .secure else { return }
            _ = self.send(bytes: bytes)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard self.terminalView === source else { return }
            self.updateWindowSize(from: source)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            guard self.terminalView === source else { return }
            if self.terminalTitle != title {
                self.terminalTitle = title
            }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            guard self.terminalView === source else { return }
            if self.currentDirectory != directory {
                self.currentDirectory = directory
            }
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    nonisolated func clipboardRead(source: TerminalView) -> Data? {
        MainActor.assumeIsolated {
            NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
