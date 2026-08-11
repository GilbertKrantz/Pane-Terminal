import AppKit
import Combine
import Darwin
import Foundation
@preconcurrency import SwiftTerm

enum PaneFocusTarget: Equatable, Sendable {
    case composer
    case authoritativeTerminal
    case none
}

enum CommandInterruptionReason: String, Codable, Sendable {
    case shellRestart
    case controlledShutdown
    case applicationExit
    case shellExit
}

/// Test-only crash simulation can terminate an isolated host when one of these
/// checkpoints is observed. Production callers leave the handler unset; the
/// hook deliberately does not alter lifecycle semantics or recover a live PTY.
enum PaneLifecycleFaultCheckpoint: String, Sendable {
    case shellRestartRequested
    case shellRestartCommandFinalized
    case shellRestartPTYTerminated
    case shellRestartStartingReplacement
    case commandFinalizationStarted
    case commandFinalizationCompleted
    case interruptedCommandFinalizationStarted
    case interruptedCommandFinalizationCompleted
    case tabCreationStarted
    case tabCreationPTYStarted
    case tabCreationInstalled
    case tabCloseStarted
    case tabCloseRemoved
    case tabCloseCleanupCompleted
}

enum ShellReadiness: Equatable, Sendable {
    case starting
    case initializing
    case ready
    case stopped
}

struct TerminalSessionDebugSnapshot: Equatable, Sendable {
    let interactionState: TerminalInteractionState
    let shellReadiness: ShellReadiness
    let processGeneration: UInt64
    let activeBlockID: UUID?
    let alternateScreenActive: Bool
    let keyboardOwner: PaneFocusTarget
    let terminalMount: ActiveTerminalPresentation
    let focusGeneration: UInt64
    let securityState: TerminalSecurityState
}

struct SessionShutdownResult: Equatable, Sendable {
    let sessionID: UUID
    let processTermination: PTYTerminationResult
    let unfinishedCommandFinalized: Bool
}

@MainActor
final class TerminalSession: NSObject, ObservableObject {
    let tabID: UUID
    let sessionID = UUID()
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
    @Published var isShellRunning = false
    @Published var shellExitStatus: Int32?
    @Published private(set) var terminalTitle = "Pane"
    @Published var currentDirectory: String?
    @Published private(set) var blockTimeline = CommandBlockTimeline()
    @Published private(set) var blockTimelineGeneration: UInt64 = 0
    @Published private(set) var isAlternateScreenActive = false
    @Published private(set) var modeAttribution: InputModeAttribution = .manual
    @Published private(set) var inputRequirement: TerminalInputRequirement = .unknown
    @Published private(set) var terminalSecurityState: TerminalSecurityState = .normal
    @Published var runtimeStateDiagnostic: String?
    @Published private(set) var activeCommandVisibleLineCount = 1
    @Published var selectedBlockID: UUID?
    @Published var commandDraft = ""
    @Published var blockSearchText = "" {
        didSet { scheduleBlockSearch() }
    }
    @Published var blockSearchFilter: BlockSearchFilter = .all {
        didSet { scheduleBlockSearch() }
    }
    @Published private(set) var scrollbackPruningNotice: ScrollbackPruningNotice?
    @Published private var indexedBlockSearchIDs: [UUID]?
    @Published private var indexedBlockSearchQuery: BlockSearchQuery?
    @Published private(set) var isBlockSearchPresented = false
    @Published var blockSearchFocusGeneration: UInt64 = 0
    @Published private(set) var sessionBoundaries: [UUID: SessionBoundary] = [:]
    @Published private(set) var restoredSessionOrder: [UUID] = []
    @Published private(set) var newShellBoundary: NewShellBoundary?
    @Published private(set) var restoredBlockIDs: Set<UUID> = []
    @Published var isRestartConfirmationPresented = false
    @Published var terminalMountRecoveryRequired = false
    @Published var lastShellRestartAt: Date?
    @Published private(set) var focusTarget: PaneFocusTarget = .none
    private var focusBeforeSearch: PaneFocusTarget = .none
    private var modeBeforeSearch: InputMode?
    @Published var isRestartInProgress = false
    @Published var isShuttingDown = false
    @Published var shellReadiness: ShellReadiness = .starting
    private var isShellStartScheduled = false
    @Published var composerContextGeneration: UInt64 = 0
    @Published var visibilityState: SessionVisibilityState = .selected {
        didSet {
            if visibilityState != .selected {
                requestFocus(.none)
            } else if oldValue != .selected {
                lastForegroundSnapshot = nil
            }
            if let terminalView = terminalView as? PaneTerminalView {
                terminalView.caretViewTracksFocus = visibilityState == .selected
            }
            if oldValue != visibilityState {
                composerContextGeneration &+= 1
            }
            updateForegroundProcessMonitoring(
                refreshImmediately: visibilityState == .selected
            )
        }
    }

    var onMeaningfulBackgroundOutput: (() -> Void)?

    private(set) var history = CommandHistory()
    let ptyController: PTYController
    let lifecycleFaultCheckpointHandler:
        (@MainActor @Sendable (PaneLifecycleFaultCheckpoint) -> Void)?
    let blockLifecycleController = BlockLifecycleController()
    private let focusCoordinator = FocusCoordinator()
    let interactionController = TerminalInteractionController(
        debugLoggingEnabled: ProcessInfo.processInfo.environment[
            "PANE_INTERACTION_DEBUG"
        ] == "1"
    )
    var terminalView: TerminalView?
    var authoritativeTerminalHostView: AuthoritativeTerminalHostView?
    lazy var terminalMountCoordinator = TerminalMountCoordinator(session: self)
    private var suspendedCommandDraft: String?
    private var pendingRestoredMode: InputMode?
    private var manualSecureInputActive = false
    private var behaviorallyIneligibleBlockIDs: Set<UUID> = []
    var previousCompletedCommandSummary: CompletedCommandSummary?
    private var modeBeforeManualSecureInput: InputMode?
    weak var liveCommandTerminalView: TerminalView?
    private var liveCommandTerminalBlockID: UUID?
    var streamParser = BlockStreamParser()
    var transcriptFilter = AlternateScreenTranscriptFilter()
    private var pendingLiveCommandOutput = Data()
    private var isLiveCommandFlushScheduled = false
    private var activeCommandCompletedLineCount = 0
    private var activeCommandHasCurrentLineContent = false
    var shellConfiguration: ShellConfiguration
    let commandAutocomplete = CommandAutocomplete()
    let zshCompletionClient = WarmZshCompletionClient()
    let completionService = CompletionService()
    let blockSearchIndex = BlockSearchIndex()
    let runtimeStateController: RuntimeStateController?
    private let runtimeSessionID = UUID()
    private let runtimeSessionStartedAt = Date()
    private let sensitiveDataSanitizer = SensitiveDataSanitizer()
    private var restoredRuntimeEventKeys: Set<String> = []
    private var isCommandHistoryEnabled: Bool
    var runtimeStateStartTask: Task<Void, Never>?
    var isRuntimeStatePrepared: Bool
    var zshCompletionEndpoint: WarmZshCompletionEndpoint?
    var isApplicationExitFinalized = false
    private var shouldReturnToBlocksAfterAlternateScreen = false
    private var shouldRestoreBlocksViewportAfterAlternateScreen = false
    private var foregroundProcessTimer: Timer?
    private var foregroundProcessTimerInterval: TimeInterval?
    private var lastForegroundInspectionAt: Date?
    private var lastForegroundSnapshot: ForegroundProcessSnapshot?
    private(set) var focusGeneration: UInt64 = 0
    private var pendingAuthoritativeFocusRepairGeneration: UInt64?
    private var lastAuthoritativeGeometrySignature: AuthoritativeTerminalGeometrySignature?
    var restartTask: Task<Void, Never>?
    var shutdownTask: Task<SessionShutdownResult, Never>?
    var completedShutdownResult: SessionShutdownResult?
    var blockSearchTask: Task<Void, Never>?
#if DEBUG
    let lifecycleDebugID = UUID()
    var debugShutdownCompleted = false
#endif

    var blocks: [CommandBlock] {
        blockTimeline.blocks
    }

    var visibleBlocks: [CommandBlock] {
        // A dismissed search must not keep filtering the timeline invisibly.
        // Preserve the query for the next search presentation, but show every
        // block whenever the search UI is not present.
        guard isBlockSearchPresented else {
            return blockTimeline.blocks
        }
        let query = BlockSearchQuery(text: blockSearchText, filter: blockSearchFilter)
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return blockTimeline.blocks
        }
        guard indexedBlockSearchQuery == query,
              let indexedBlockSearchIDs else {
            return []
        }
        let matches = Set(indexedBlockSearchIDs)
        return blockTimeline.blocks.filter { matches.contains($0.id) }
    }

    var blockSearchMatches: [CommandBlock] {
        visibleBlocks.filter(\.isFinalized)
    }

    var selectedBlock: CommandBlock? {
        guard let selectedBlockID else { return nil }
        return blockTimeline.block(id: selectedBlockID)
    }

    var isCommandActive: Bool {
        blockLifecycleController.isCommandActive
    }

    var hasActiveWork: Bool {
        isCommandActive || isAlternateScreenActive || isSecureInputActive
            || inputRequirement == .direct || inputRequirement == .secure
            || isRestartInProgress || (lastForegroundSnapshot.map { !$0.isShellForeground } ?? false)
    }

    var foregroundProcessName: String? {
        guard let snapshot = lastForegroundSnapshot, !snapshot.isShellForeground else { return nil }
        return snapshot.processName
    }

    var isShellReadyForInput: Bool {
        shellReadiness == .ready
            && isShellRunning
            && !isRestartInProgress
            && !isShuttingDown
    }

    var interactionState: TerminalInteractionState {
        interactionController.state
    }

    var composerEnabled: Bool {
        interactionController.composerEnabled
    }

    var terminalAcceptsInput: Bool {
        interactionController.state.terminalAcceptsInput
    }

    var processGeneration: UInt64 {
        ptyController.generation
    }

    var debugSnapshot: TerminalSessionDebugSnapshot {
        TerminalSessionDebugSnapshot(
            interactionState: interactionState,
            shellReadiness: shellReadiness,
            processGeneration: processGeneration,
            activeBlockID: blockLifecycleController.activeOrAwaitingBlockID,
            alternateScreenActive: isAlternateScreenActive,
            keyboardOwner: focusTarget,
            terminalMount: activeTerminalPresentation,
            focusGeneration: focusGeneration,
            securityState: terminalSecurityState
        )
    }

    var isShellIntegrationReady: Bool {
        shellReadiness == .ready
    }

    var activeCommandBlock: CommandBlock? {
        blockLifecycleController.activeBlock
    }

    var isSecureInputActive: Bool {
        terminalSecurityState.inputMode == .secure
    }

    var activeProcessLabel: String {
        if isShuttingDown { return "Closing shell…" }
        if isRestartInProgress { return "Restarting shell…" }
        switch shellReadiness {
        case .starting:
            return "Starting shell…"
        case .initializing:
            return "Initializing shell…"
        case .stopped:
            return "Shell stopped"
        case .ready:
            break
        }
        if let activeBlock = activeCommandBlock {
            return activeBlock.processName
        }
        return "zsh · idle"
    }

    var shellDisplayName: String {
        URL(fileURLWithPath: shellConfiguration.executable).lastPathComponent
    }

    init(
        tabID: UUID = UUID(),
        shellConfiguration: ShellConfiguration = .loginZsh(),
        runtimeStateController: RuntimeStateController? = nil,
        commandHistoryEnabled: Bool = true,
        ptyController: PTYController? = nil,
        lifecycleFaultCheckpointHandler:
            (@MainActor @Sendable (PaneLifecycleFaultCheckpoint) -> Void)? = nil
    ) {
        self.tabID = tabID
        self.shellConfiguration = shellConfiguration
        self.runtimeStateController = runtimeStateController
        self.isCommandHistoryEnabled = commandHistoryEnabled
        self.isRuntimeStatePrepared = runtimeStateController == nil
        self.currentDirectory = shellConfiguration.workingDirectory
        self.ptyController = ptyController ?? PTYController()
        self.lifecycleFaultCheckpointHandler = lifecycleFaultCheckpointHandler
        super.init()
        PaneResourceCounters.increment(.session)
        self.ptyController.onEvent = { [weak self] event in
            self?.handlePTYEvent(event)
        }
        blockLifecycleController.onTimelineChanged = { [weak self] timeline in
            guard let self else { return }
            self.blockTimeline = timeline
            self.blockTimelineGeneration &+= 1
            self.rebuildBlockSearchIndex(with: timeline.blocks)
        }
        blockLifecycleController.onTimelinePruned = { [weak self] notice in
            guard let self else { return }
            self.scrollbackPruningNotice = notice
            self.selectedBlockID = notice.replacementSelection(
                for: self.selectedBlockID
            )
        }
        interactionController.onTransition = { [weak self] _, _, nextState in
            self?.applyInteractionProjection(nextState)
        }
        applyInteractionProjection(interactionController.state)
        Task {
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .sessionCreated,
                tabID: tabID,
                sessionID: sessionID,
                outcome: .succeeded
            ))
        }
#if DEBUG
        lifecycleLog("created")
#endif
    }

    deinit {
        PaneResourceCounters.decrement(.session)
#if DEBUG
        print("Pane lifecycle session[\(lifecycleDebugID.uuidString)] deallocated")
#endif
    }

    func diagnostics() async -> TerminalSessionDiagnostics {
#if DEBUG
        let completionGeneration = await completionService.debugSnapshot().generation
#else
        let completionGeneration = processGeneration
#endif
        let retainedOutputBytes = blockTimeline.blocks.reduce(into: 0) { total, block in
            total += block.output.utf8.count
            total += block.terminalSnapshot?.bytes.count ?? 0
        }
        let mount = terminalMountCoordinator.healthSnapshot()
        return TerminalSessionDiagnostics(
            tabID: tabID,
            sessionID: sessionID,
            ptyGeneration: processGeneration,
            interactionState: String(describing: interactionState),
            focusTarget: String(describing: focusTarget),
            visibilityState: String(describing: visibilityState),
            shellReadiness: String(describing: shellReadiness),
            foregroundProcessName: foregroundProcessName.map {
                URL(fileURLWithPath: $0).lastPathComponent
            },
            activeBlockID: blockLifecycleController.activeOrAwaitingBlockID,
            isAlternateScreenActive: isAlternateScreenActive,
            isSecureInputActive: isSecureInputActive,
            completionGeneration: completionGeneration,
            contextRefreshStatus: "generation-\(composerContextGeneration)",
            blockCount: blockTimeline.blocks.count,
            estimatedRetainedOutputBytes: retainedOutputBytes,
            terminalMount: TerminalMountDiagnostics(
                expectedPlacement: String(describing: mount.expectedPlacement),
                leaseID: mount.leaseID,
                mountID: mount.mountID.map { String(describing: $0) },
                hostParentID: mount.hostParentID.map { String(describing: $0) },
                hasWindow: mount.hasWindow,
                isUnderExpectedMount: mount.isUnderExpectedMount,
                width: Double(mount.width),
                height: Double(mount.height),
                terminalColumns: mount.terminalColumns,
                terminalRows: mount.terminalRows,
                ptyRunning: mount.ptyRunning,
                claimCount: terminalMountCoordinator.claimCount,
                releaseCount: terminalMountCoordinator.releaseCount,
                staleUpdateRejectionCount: terminalMountCoordinator.staleUpdateRejectionCount,
                validationFailureCount: terminalMountCoordinator.validationFailureCount,
                automaticRepairCount: terminalMountCoordinator.automaticRepairCount,
                successfulRepairCount: terminalMountCoordinator.successfulRepairCount,
                terminalIdentityChangeCount: terminalMountCoordinator.terminalIdentityChangeCount,
                ptyGenerationChangeCount: terminalMountCoordinator.ptyGenerationChangeCount,
                lastMountAt: terminalMountCoordinator.lastMountAt,
                lastDetachAt: terminalMountCoordinator.lastDetachAt,
                lastFailedValidationAt: terminalMountCoordinator.lastFailedValidationAt,
                lastRepairAttemptAt: terminalMountCoordinator.lastRepairAttemptAt,
                lastRepairResultAt: terminalMountCoordinator.lastRepairResultAt
            )
        )
    }

    private func applyInteractionProjection(_ state: TerminalInteractionState) {
        let projectedMode = interactionController.presentationMode
        let projectedInput = interactionController.effectiveInputRequirement
        if mode != projectedMode {
            mode = projectedMode
        }
        if inputRequirement != projectedInput {
            inputRequirement = projectedInput
        }
        if blockTimeline.activeBlockID != nil,
           !isAlternateScreenActive,
           projectedInput == .direct || projectedInput == .secure {
            blockLifecycleController.markDirectInteraction()
        }
        requestFocus(state.focusTarget)
    }

    func makeAuthoritativeTerminalView() -> PaneTerminalView {
        if let terminalView = terminalView as? PaneTerminalView { return terminalView }
        let terminalView = PaneTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        terminalView.autoresizingMask = [.width, .height]
        terminalView.changeScrollback(
            ScrollbackPolicy.standard.terminalLineLimit
        )
        terminalView.optionAsMetaKey = false
        terminalView.allowMouseReporting = true
        terminalView.caretViewTracksFocus = visibilityState == .selected
        attach(terminalView: terminalView)
        return terminalView
    }

    func applyAppearancePreferences(_ preferences: AppearancePreferences) {
        guard let terminalView = terminalView as? PaneTerminalView else { return }
        let size = CGFloat(preferences.terminalFont.size)
        if let name = preferences.terminalFont.postScriptName,
           let font = NSFont(name: name, size: size) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func applyKeyboardPreferences(_ preferences: TerminalPreferences) {
        (terminalView as? PaneTerminalView)?.optionAsMetaKey = preferences.optionKeyBehaviour == .meta
    }

    func applyScrollbackPreference(_ preferences: TerminalPreferences) {
        // SwiftTerm updates the existing buffer in place, so this does not
        // rebuild the authoritative view or disturb its PTY/focus ownership.
        (terminalView as? PaneTerminalView)?.changeScrollback(preferences.scrollbackLimit)
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

        scheduleShellStartIfNeeded()
    }

    /// Attaching happens while SwiftUI is creating or updating an AppKit
    /// representable. Starting zsh changes published session state, so defer
    /// that work until the current view transaction has completed.
    private func scheduleShellStartIfNeeded() {
        guard !ptyController.isRunning,
              !isShuttingDown,
              !isShellStartScheduled else { return }
        isShellStartScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isShellStartScheduled = false
            guard self.terminalView != nil,
                  !self.ptyController.isRunning,
                  !self.isShuttingDown else { return }
            self.startShell()
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

        if !blockLifecycleController.capturedOutputData.isEmpty {
            terminalView.feed(
                byteArray: Array(blockLifecycleController.capturedOutputData)[...]
            )
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


    func submitDraft() {
        guard isShellReadyForInput else { return }
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

        if blockLifecycleController.awaitingStartID != nil {
            let continuation = commandDraft
            guard send(bytes: CommandSerializer.serializeInputLine(continuation)) else { return }
            if let fullCommand = blockLifecycleController.appendContinuation(
                continuation
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
        guard !isShuttingDown,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let blockID = blockLifecycleController.queue(
            command: command,
            workingDirectory: currentDirectory ?? shellConfiguration.workingDirectory,
            isRerunnable: sensitiveDataSanitizer.sanitizeCommand(command).redactionCount == 0
        )

        if !isCommandActive, isShellIntegrationReady {
            guard send(bytes: CommandSerializer.serializeCommand(command)) else {
                blockLifecycleController.remove(id: blockID)
                return
            }
            _ = interactionController.handle(.commandSubmitted)
            blockLifecycleController.markAwaitingStart(blockID)
        }

        selectedBlockID = blockID
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
        guard isShellReadyForInput else { return }
        shouldReturnToBlocksAfterAlternateScreen = false
        setMode(mode == .terminal ? .blocks : .terminal)
    }

    func setMode(_ newMode: InputMode) {
        guard newMode == .blocks || isShellReadyForInput else { return }
        guard mode != newMode else { return }
        _ = interactionController.handle(
            newMode == .terminal ? .userOpenedFullTerminal : .userReturnedToBlocks
        )
        shouldReturnToBlocksAfterAlternateScreen = false
        if newMode == .terminal {
            focusAuthoritativeTerminal()
        } else {
            // Re-evaluate the still-running foreground process even when the
            // timer last observed the same snapshot in Full Terminal.
            lastForegroundSnapshot = nil
            refreshForegroundProcessMode()
            let interactionRemainsTerminalOwned = inputRequirement == .direct
                || inputRequirement == .secure
                || isAlternateScreenActive
            if interactionRemainsTerminalOwned {
                requestFocus(.authoritativeTerminal)
            } else {
                modeAttribution = .manual
                requestFocus(.composer)
            }
        }
    }

    func restoreModeWhenReady(_ restoredMode: InputMode) {
        guard restoredMode != .blocks else { return }
        if isShellReadyForInput {
            setMode(restoredMode)
        } else {
            pendingRestoredMode = restoredMode
        }
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
        writeToPasteboard(sensitiveDataSanitizer.sanitizeCommand(block.command).value)
    }

    func copyOutput(id: UUID) {
        guard let block = blockTimeline.block(id: id) else { return }
        writeToPasteboard(sensitiveDataSanitizer.sanitizeOutput(block.output).value)
    }

    func copyCommandAndOutput(id: UUID) {
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
        guard isShellReadyForInput,
              let block = blockTimeline.block(id: id),
              block.isRerunnable else { return }
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
        setMode(.blocks)
    }

    func editSelectedBlock() {
        guard let selectedBlockID else { return }
        editBlock(id: selectedBlockID)
    }

    func toggleBlockCollapsed(id: UUID) {
        blockLifecycleController.toggleCollapsed(id: id)
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
        blockLifecycleController.setAllCompletedCollapsed(collapsed)
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

    func presentBlockSearch() {
        if !isBlockSearchPresented {
            focusBeforeSearch = focusTarget
            modeBeforeSearch = mode
            if mode == .terminal {
                setMode(.blocks)
            }
        }
        isBlockSearchPresented = true
        scheduleBlockSearch()
        ensureBlockSearchSelection()
        // Searching temporarily owns AppKit focus. Advancing the shared
        // generation prevents a delayed composer or terminal remount callback
        // from stealing it while the field is active.
        requestFocus(.none)
        blockSearchFocusGeneration &+= 1
    }

    func dismissBlockSearch() {
        guard isBlockSearchPresented else { return }
        isBlockSearchPresented = false
        let priorMode = modeBeforeSearch
        modeBeforeSearch = nil
        if priorMode == .terminal, isShellReadyForInput {
            setMode(.terminal)
        } else {
            requestFocus(focusBeforeSearch == .none ? .composer : focusBeforeSearch)
        }
    }

    func dismissScrollbackPruningNotice() {
        scrollbackPruningNotice = nil
        blockLifecycleController.dismissPruningNotice()
    }

    private func rebuildBlockSearchIndex(with blocks: [CommandBlock]) {
        blockSearchTask?.cancel()
        let query = BlockSearchQuery(
            text: blockSearchText,
            filter: blockSearchFilter
        )
        blockSearchTask = Task { @MainActor [weak self, blockSearchIndex] in
            await blockSearchIndex.replace(blocks: blocks)
            guard let self, !Task.isCancelled else { return }
            await self.performBlockSearch(query)
        }
    }

    private func scheduleBlockSearch() {
        let query = BlockSearchQuery(
            text: blockSearchText,
            filter: blockSearchFilter
        )
        if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockSearchTask?.cancel()
            blockSearchTask = nil
            indexedBlockSearchQuery = query
            indexedBlockSearchIDs = blockTimeline.blocks.map(\.id)
            if isBlockSearchPresented {
                ensureBlockSearchSelection()
            }
            return
        }
        blockSearchTask?.cancel()
        blockSearchTask = Task { @MainActor [weak self] in
            await self?.performBlockSearch(query)
        }
    }

    private func performBlockSearch(_ query: BlockSearchQuery) async {
        guard !Task.isCancelled,
              let result = await blockSearchIndex.search(
                  query,
                  debounce: PanePerformanceThresholds.searchDebounce
              ),
              !Task.isCancelled,
              result.query == BlockSearchQuery(
                  text: blockSearchText,
                  filter: blockSearchFilter
              ) else { return }
        indexedBlockSearchQuery = result.query
        indexedBlockSearchIDs = result.blockIDs
        blockSearchTask = nil
        if isBlockSearchPresented {
            ensureBlockSearchSelection()
        }
    }

    func ensureBlockSearchSelection() {
        guard isBlockSearchPresented else { return }
        let matches = blockSearchMatches
        guard !matches.isEmpty else {
            selectedBlockID = nil
            return
        }
        if !matches.contains(where: { $0.id == selectedBlockID }) {
            selectedBlockID = matches[0].id
        }
    }

    func removeBlock(id: UUID) {
        if blockTimeline.activeBlockID == id {
            clearActiveBlockCapture()
        }
        blockLifecycleController.remove(id: id)
        if selectedBlockID == id {
            selectedBlockID = blockTimeline.blocks.last?.id
        }
    }

    func clearBlocks() {
        blockLifecycleController.clearFinalized()
        if let selectedBlockID,
           blockTimeline.block(id: selectedBlockID) == nil {
            self.selectedBlockID = nil
        }
    }

    func sendInterrupt() {
        guard isShellReadyForInput else { return }
        _ = send(bytes: [0x03])
    }

    func sendEndOfFile() {
        guard isShellReadyForInput else { return }
        _ = send(bytes: [0x04])
    }

    func enterDirectInput() {
        guard isShellReadyForInput else { return }
        _ = interactionController.handle(
            isCommandActive ? .directInputRequired : .userOpenedFullTerminal
        )
        modeAttribution = .manual
        focusAuthoritativeTerminal()
    }

    func focusComposer() {
        guard !isSecureInputActive else { return }
        setMode(.blocks)
        requestFocus(.composer)
    }

    func focusDirectTerminal() {
        enterDirectInput()
    }

    func copyLocalDiagnostics(includeSanitizedCommandContext: Bool = false) {
        let paneVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"
        let persistenceStatus = runtimeStateDiagnostic == nil ? "available" : "degraded"
        let databaseHealth = runtimeStateDiagnostic == nil ? "healthy" : "warning"
        let windowSize = ptyController.windowSize
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
        let mount = terminalMountCoordinator.healthSnapshot()
        lines.append(contentsOf: [
            "Expected terminal placement: \(String(describing: mount.expectedPlacement))",
            "Mount lease: \(mount.leaseID?.uuidString ?? "none")",
            "Mount ID: \(mount.mountID.map { String(describing: $0) } ?? "none")",
            "Host parent ID: \(mount.hostParentID.map { String(describing: $0) } ?? "none")",
            "Mount has window: \(mount.hasWindow)",
            "Host under expected mount: \(mount.isUnderExpectedMount)",
            "Terminal bounds: \(Int(mount.width))x\(Int(mount.height))",
            "Terminal grid: \(mount.terminalColumns)x\(mount.terminalRows)",
            "Mount claims/releases: \(terminalMountCoordinator.claimCount)/\(terminalMountCoordinator.releaseCount)",
            "Stale mount updates rejected: \(terminalMountCoordinator.staleUpdateRejectionCount)",
            "Mount validation failures: \(terminalMountCoordinator.validationFailureCount)",
            "Automatic repairs: \(terminalMountCoordinator.automaticRepairCount)",
            "Successful repairs: \(terminalMountCoordinator.successfulRepairCount)"
        ])
        if includeSanitizedCommandContext, let block = selectedBlock {
            lines.append("Sanitized command: \(sensitiveDataSanitizer.sanitizeCommand(block.command).value)")
        }
        writeToPasteboard(lines.joined(separator: "\n"))
    }

    func enterSecureInput() {
        guard isShellReadyForInput else { return }
        let previousMode = mode
        if !manualSecureInputActive {
            modeBeforeManualSecureInput = previousMode
        }
        if !isCommandActive {
            _ = interactionController.handle(.userOpenedFullTerminal)
        }
        manualSecureInputActive = true
        activateSecureInput(source: .manualOverride)
        modeAttribution = .secureInput
        focusAuthoritativeTerminal()
    }

    func exitSecureInput() {
        let previousMode = modeBeforeManualSecureInput
        modeBeforeManualSecureInput = nil
        manualSecureInputActive = false
        updateSecurityState(echoEnabled: true, source: .manualOverride)
        if previousMode == .blocks {
            setMode(.blocks)
        }
    }

    func clearTerminal() {
        terminalView?.feed(text: "\u{001B}[2J\u{001B}[3J\u{001B}[H")
    }

    private func handlePTYEvent(_ event: PTYController.Event) {
        switch event {
        case .received(let data):
            handleProcessData(Array(data))
        case .terminated(let waitStatus):
            handleProcessTermination(waitStatus: waitStatus)
        }
    }

    private func handleProcessData(_ bytes: [UInt8]) {
        guard ptyController.isRunning else { return }
        if visibilityState == .background, !bytes.isEmpty {
            onMeaningfulBackgroundOutput?()
        }
        refreshForegroundProcessModeForOutputIfNeeded()

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
                blockLifecycleController.consumeTerminalBytes(data)
                routeActiveBlockOutput(data)

            case .commandStarted(let command):
                // The bootstrap command installs these hooks. Existing hooks
                // in a user's zshrc may emit START for that bootstrap itself;
                // it is intentionally not represented as a user block.
                guard isShellIntegrationReady else { continue }
                if blockLifecycleController.awaitingStartID == nil, let command {
                    enqueueDirectTerminalCommand(command)
                }
                if let id = blockLifecycleController.commandStarted() {
                    _ = interactionController.handle(.commandStarted)
                    beginActiveBlockCapture(blockID: id)
                    selectedBlockID = id
                    updateForegroundProcessMonitoring(refreshImmediately: true)
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
                    shellReadiness = .ready
                    _ = interactionController.handle(.shellReady)
                    if let pendingRestoredMode {
                        self.pendingRestoredMode = nil
                        setMode(pendingRestoredMode)
                    }
                    dispatchNextQueuedCommandIfNeeded()
                    continue
                }

                if blockTimeline.activeBlockID != nil {
                    lifecycleFaultCheckpointHandler?(.commandFinalizationStarted)
                    let signpost = PanePerformanceSignposts.beginBlockFinalization()
                    let windowSize = ptyController.windowSize
                    if let id = blockLifecycleController.completeActive(
                        exitCode: exitCode,
                        renderedOutput: renderedActiveBlockOutput(),
                        columns: Int(windowSize.ws_col),
                        rows: Int(windowSize.ws_row)
                    ) {
                        selectedBlockID = id
                        if let command = blockTimeline.block(id: id)?.command {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                await self.completionService.commandDidComplete(command)
                                if NormalizedCommand(command).executable == "git" {
                                    self.composerContextGeneration &+= 1
                                }
                            }
                        }
                        persistCompletedBlock(id: id)
                    }
                    lifecycleFaultCheckpointHandler?(.commandFinalizationCompleted)
                    PanePerformanceSignposts.endBlockFinalization(signpost)
                    clearActiveBlockCapture()
                } else if blockLifecycleController.awaitingStartID != nil {
                    // zsh emits precmd after an interrupted/incomplete buffer
                    // without ever running preexec. Finalize that pending
                    // command so the local queue cannot remain wedged.
                    selectedBlockID = blockLifecycleController.interruptAwaiting(
                        exitCode: exitCode
                    )
                }
                _ = interactionController.handle(
                    exitCode == 128 + SIGINT ? .commandInterrupted : .commandCompleted
                )
                updateForegroundProcessMonitoring(refreshImmediately: false)
                dispatchNextQueuedCommandIfNeeded()
            }
        }
    }

    private func handleProcessTermination(waitStatus: Int32?) {
        let exitCode = Self.normalizedExitCode(fromWaitStatus: waitStatus)

        let transcriptRemainder = transcriptFilter.flush()
        if !transcriptRemainder.isEmpty {
            handleStreamEvents(streamParser.consume(transcriptRemainder))
        }
        handleStreamEvents(streamParser.flush())

        Task { @MainActor [weak self] in
            await self?.finalizeUnfinishedCommand(
                exitCode: exitCode,
                reason: .shellExit
            )
        }
        isShellRunning = false
        shellReadiness = .stopped
        _ = interactionController.handle(.shellExited)
        invalidateCompletionEndpoint()
        stopForegroundProcessMonitoring()
        Task {
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .ptyStopped,
                tabID: tabID,
                sessionID: sessionID,
                outcome: .succeeded
            ))
        }
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

    func finalizeUnfinishedCommand(
        exitCode: Int32? = nil,
        reason: CommandInterruptionReason,
        renderedOutput: String? = nil
    ) async {
        lifecycleFaultCheckpointHandler?(.interruptedCommandFinalizationStarted)
        let blockID = blockLifecycleController.activeOrAwaitingBlockID

        guard let blockID else {
            clearActiveBlockCapture()
            blockLifecycleController.markAwaitingStart(nil)
            return
        }

        let windowSize = ptyController.windowSize
        _ = blockLifecycleController.interruptUnfinished(
            exitCode: exitCode,
            renderedOutput: renderedOutput ?? renderedActiveBlockOutput(),
            columns: Int(windowSize.ws_col),
            rows: Int(windowSize.ws_row)
        )

        defer {
            clearActiveBlockCapture()
            blockLifecycleController.markAwaitingStart(nil)
        }

        guard let block = blockTimeline.block(id: blockID),
              block.origin == .live else {
            lifecycleFaultCheckpointHandler?(.interruptedCommandFinalizationCompleted)
            return
        }

        await persistInterruptedBlock(block, reason: reason)
        lifecycleFaultCheckpointHandler?(.interruptedCommandFinalizationCompleted)
    }

    private func persistInterruptedBlock(
        _ block: CommandBlock,
        reason: CommandInterruptionReason
    ) async {
        guard let runtimeStateController else { return }
        let sanitizedCommand = sensitiveDataSanitizer.sanitizeCommand(block.command)
        let sanitizedOutput = sensitiveDataSanitizer.sanitizeOutput(block.output)

        let command: String
        let outputSummary: String?
        let outputKind: PersistedOutputKind
        if sanitizedCommand.redactionCount > 0 || !block.isRerunnable {
            command = "[Sensitive command interrupted]"
            outputSummary = nil
            outputKind = .none
        } else {
            command = sanitizedCommand.value
            let output = sanitizedOutput.value
            outputSummary = output.isEmpty ? nil : String(output.prefix(1_000))
            outputKind = outputSummary == nil ? .none : .excerpt
        }

        let event = PersistedCommandEvent(
            blockID: block.id,
            sessionID: runtimeSessionID,
            timestamp: block.completedAt ?? Date(),
            workingDirectory: block.workingDirectory,
            command: command,
            exitCode: { if case .interrupted(let code) = block.state { return code.map(Int.init) }; return nil }(),
            durationMilliseconds: block.duration.map { Int(($0 * 1_000).rounded()) },
            sanitizedOutputSummary: outputSummary,
            sanitizedErrorSummary: nil,
            predictionSource: nil,
            predictionAction: nil,
            completion: .interrupted,
            isCollapsed: block.isCollapsed,
            outputKind: outputKind
        )
        let startTask = runtimeStateStartTask
        await startTask?.value
        let behavioralEligible = behaviorallyIneligibleBlockIDs.remove(block.id) == nil
        updatePreviousCommandSummary(
            for: event,
            behavioralEligible: behavioralEligible
        )
        runtimeStateDiagnostic = await runtimeStateController.persistCommandEvent(
            event,
            behavioralEligible: behavioralEligible
        )
    }

    private func beginActiveBlockCapture(blockID: UUID) {
        guard blockTimeline.activeBlockID == blockID else { return }
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
        _ = interactionController.handle(.commandSubmitted)
        blockLifecycleController.markAwaitingStart(nextCommand.id)
    }

    func prepareRuntimeStateAndStartShell() {
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
            guard let self, !Task.isCancelled, !self.isShuttingDown else {
                _ = await runtimeStateController.closeCurrentSessionCleanly()
                return
            }
            self.runtimeStateDiagnostic = result.diagnostic
            if let context = result.restoredContext {
                self.restoreRuntimeContext(
                    context,
                    restoreCommandHistory: result.restoresCommandHistory,
                    restoreVisibleBlocks: result.restoresVisibleBlocks
                )
            }
            self.isRuntimeStatePrepared = true
            if !Task.isCancelled, !self.isShuttingDown {
                self.startShell()
            }
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
        blockLifecycleController.restore(restoredBlocks)
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

        let behavioralEligible = behaviorallyIneligibleBlockIDs.remove(block.id) == nil
        updatePreviousCommandSummary(
            for: event,
            behavioralEligible: behavioralEligible
        )
        let startTask = runtimeStateStartTask
        Task { [weak self] in
            await startTask?.value
            let directory = URL(
                fileURLWithPath: event.workingDirectory,
                isDirectory: true
            )
            let project = await self?.completionService.projectDefinition(for: directory)
            _ = await runtimeStateController.updateCurrentProjectIdentity(project?.identity)
            let diagnostic = await runtimeStateController.persistCommandEvent(
                event,
                behavioralEligible: behavioralEligible
            )
            self?.runtimeStateDiagnostic = diagnostic
        }
    }

    private func updatePreviousCommandSummary(
        for event: PersistedCommandEvent,
        behavioralEligible: Bool
    ) {
        guard behavioralEligible, event.completion != .unknown else {
            previousCompletedCommandSummary = nil
            return
        }
        let normalized = NormalizedCommand(event.command)
        guard !normalized.full.isEmpty, let commandKey = normalized.commandKey else {
            previousCompletedCommandSummary = nil
            return
        }
        previousCompletedCommandSummary = CompletedCommandSummary(
            normalizedCommand: normalized.full,
            commandKey: commandKey,
            exitCode: event.exitCode.map(Int32.init),
            projectID: nil,
            directoryIdentity: event.workingDirectory,
            completedAt: event.timestamp
        )
    }

    private static func isRestoredCommandRerunnable(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(SensitiveDataSanitizer.redaction) else { return false }
        return trimmed != "[command omitted]"
            && trimmed != "<command omitted>"
            && trimmed != "[Sensitive command interrupted]"
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
        for id in restoredBlockIDs { blockLifecycleController.remove(id: id) }
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
        blockLifecycleController.clearFinalized()
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
        blockLifecycleController.clearFinalizedOutput()
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

    nonisolated static func validatedWorkingDirectory(_ path: String?) -> String? {
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
        updateActiveCommandLineEstimate(with: data)

        guard liveCommandTerminalBlockID == activeBlockID,
              liveCommandTerminalView != nil else { return }
        pendingLiveCommandOutput.append(data)
        scheduleLiveCommandOutputFlush()
    }

    func renderedActiveBlockOutput() -> String? {
        flushPendingLiveCommandOutput()
        if liveCommandTerminalBlockID == blockTimeline.activeBlockID,
           let liveCommandTerminalView {
            return Self.renderedTranscript(from: liveCommandTerminalView)
        }
        return nil
    }

    nonisolated static func requiresRichTerminalRendering(_ data: Data) -> Bool {
        BlockLifecycleController.requiresRichTerminalRendering(data)
    }

    private func clearActiveBlockCapture() {
        blockLifecycleController.clearCapture()
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
        _ = interactionController.handle(
            isActive ? .alternateScreenEntered : .alternateScreenExited
        )
        isAlternateScreenActive = isActive

        if isActive {
            if blockTimeline.activeBlockID != nil {
                blockLifecycleController.markAlternateScreenEntered()
            }
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
                announceAccessibility("Direct terminal input activated")
                focusAuthoritativeTerminal()
            } else {
                shouldReturnToBlocksAfterAlternateScreen = false
            }
        } else {
            if shouldReturnToBlocksAfterAlternateScreen {
                shouldRestoreBlocksViewportAfterAlternateScreen = true
                modeAttribution = .manual
                requestFocus(.composer)
                // Re-evaluate immediately after the protocol-owned mode ends.
                // The same foreground process may still require raw input.
                lastForegroundSnapshot = nil
            }
            shouldReturnToBlocksAfterAlternateScreen = false
        }
        updateForegroundProcessMonitoring(refreshImmediately: !isActive)
    }

    func consumeBlocksViewportRestoreRequest() -> Bool {
        guard shouldRestoreBlocksViewportAfterAlternateScreen else { return false }
        shouldRestoreBlocksViewportAfterAlternateScreen = false
        return true
    }

    func startForegroundProcessMonitoring() {
        updateForegroundProcessMonitoring(refreshImmediately: true)
    }

    private func updateForegroundProcessMonitoring(refreshImmediately: Bool) {
        let desiredInterval = foregroundProcessMonitoringInterval
        if desiredInterval != foregroundProcessTimerInterval {
            foregroundProcessTimer?.invalidate()
            foregroundProcessTimer = nil
            foregroundProcessTimerInterval = desiredInterval
            if let desiredInterval {
                let timer = Timer(timeInterval: desiredInterval, repeats: true) { [weak self] _ in
                    assert(Thread.isMainThread)
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.refreshForegroundProcessMode()
                        self.updateForegroundProcessMonitoring(refreshImmediately: false)
                    }
                }
                foregroundProcessTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        if refreshImmediately, desiredInterval != nil {
            refreshForegroundProcessMode()
        }
    }

    private var foregroundProcessMonitoringInterval: TimeInterval? {
        guard isShellRunning,
              !isShuttingDown,
              !isAlternateScreenActive,
              visibilityState != .closing else { return nil }
        let needsInspection = shellReadiness != .ready
            || blockLifecycleController.activeOrAwaitingBlockID != nil
            || inputRequirement == .direct
            || inputRequirement == .secure
            || mode == .terminal
            || lastForegroundSnapshot.map { !$0.isShellForeground } == true
        guard needsInspection else { return nil }
        return visibilityState == .selected ? 0.25 : 2
    }

    private func refreshForegroundProcessModeForOutputIfNeeded() {
        let minimumInterval = visibilityState == .selected ? 0.25 : 2
        if let lastForegroundInspectionAt,
           Date().timeIntervalSince(lastForegroundInspectionAt) < minimumInterval {
            return
        }
        refreshForegroundProcessMode()
    }

    func stopForegroundProcessMonitoring() {
        foregroundProcessTimer?.invalidate()
        foregroundProcessTimer = nil
        foregroundProcessTimerInterval = nil
        lastForegroundInspectionAt = nil
        lastForegroundSnapshot = nil
        updateSecurityState(echoEnabled: true, source: .terminalEchoState)
        if modeAttribution != .manual {
            modeAttribution = .manual
        }
    }

    private func refreshForegroundProcessMode() {
        guard isShellRunning, !isAlternateScreenActive else { return }
        lastForegroundInspectionAt = Date()
        guard let snapshot = foregroundProcessSnapshot() else { return }

        // zsh's idle ZLE can temporarily disable ECHO while it owns the
        // foreground process group. That is ordinary prompt editing, not a
        // password request. Once preexec has started a tracked command, an
        // ECHO-off shell foreground is meaningful again (for example read -s).
        let isIdleShellLineEditor = snapshot.isShellForeground
            && blockTimeline.activeBlockID == nil
        updateSecurityState(
            echoEnabled: isIdleShellLineEditor ? true : snapshot.echoEnabled,
            secureInputRequired: isIdleShellLineEditor
                ? false
                : snapshot.requiresSecureInputFromTermios,
            source: .terminalEchoState
        )

        guard snapshot != lastForegroundSnapshot else { return }
        lastForegroundSnapshot = snapshot

        if let attribution = snapshot.terminalModeAttribution {
            if terminalSecurityState.inputMode == .normal,
               (
                   interactionController.state == .commandRunningLineInput
                       || interactionController.state == .commandRunningSecure
                       || interactionController.state == .fullTerminal
               ) {
                _ = interactionController.handle(.directInputRequired)
            }
            if mode != .terminal {
                let wasDirect = inputRequirement == .direct || inputRequirement == .secure
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
            if isCommandActive,
               terminalSecurityState.inputMode == .normal {
                _ = interactionController.handle(.lineInputRequired)
            }
        } else if snapshot.isShellForeground {
            if isCommandActive,
               terminalSecurityState.inputMode == .normal {
                _ = interactionController.handle(.lineInputRequired)
            }
        }
    }

    private func updateSecurityState(
        echoEnabled: Bool,
        secureInputRequired: Bool? = nil,
        source: SecureInputDetectionSource
    ) {
        let inputMode: TerminalInputMode =
            (secureInputRequired ?? !echoEnabled) ? .secure : .normal
        if manualSecureInputActive, inputMode == .normal {
            return
        }
        guard terminalSecurityState.inputMode != inputMode
            || terminalSecurityState.echoEnabled != echoEnabled else { return }

        if inputMode == .secure {
            activateSecureInput(source: source)
            return
        } else if !manualSecureInputActive, terminalSecurityState.inputMode == .secure {
            _ = interactionController.handle(.secureInputEnded)
            if commandDraft.isEmpty, let suspendedCommandDraft {
                commandDraft = suspendedCommandDraft
            }
            suspendedCommandDraft = nil
        }
        terminalSecurityState = TerminalSecurityState(
            inputMode: inputMode,
            echoEnabled: echoEnabled,
            detectedAt: Date(),
            source: source
        )
        if mode == .blocks,
           inputRequirement != .direct,
           inputRequirement != .secure {
            requestFocus(.composer)
        }
    }

    private func activateSecureInput(source: SecureInputDetectionSource) {
        let wasSecure = terminalSecurityState.inputMode == .secure
        if !wasSecure {
            _ = interactionController.handle(.secureInputRequired)
        }
        if !wasSecure {
            if let blockID = blockLifecycleController.activeOrAwaitingBlockID {
                behaviorallyIneligibleBlockIDs.insert(blockID)
            }
            Task { [weak self] in
                await self?.runtimeStateController?.resetBehavioralTransitionContinuity()
            }
            previousCompletedCommandSummary = nil
            if !commandDraft.isEmpty {
                suspendedCommandDraft = commandDraft
            }
            commandDraft = ""
            history.resetNavigation()
        }
        modeAttribution = .secureInput
        terminalSecurityState = TerminalSecurityState(
            inputMode: .secure,
            echoEnabled: false,
            detectedAt: Date(),
            source: source
        )
        focusAuthoritativeTerminal()
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

    func requestFocus(_ target: PaneFocusTarget) {
        guard visibilityState == .selected || target == .none else { return }
        focusCoordinator.request(target)
        focusGeneration = focusCoordinator.generation
        focusTarget = focusCoordinator.target
    }

    var shouldAuthoritativeTerminalOwnFocus: Bool {
        mode == .terminal || inputRequirement == .direct || inputRequirement == .secure
    }

    private func focusAuthoritativeTerminal() {
        guard visibilityState == .selected else { return }
        requestFocus(.authoritativeTerminal)
        let generation = focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.visibilityState == .selected,
                  self.focusGeneration == generation,
                  self.focusTarget == .authoritativeTerminal,
                  self.shouldAuthoritativeTerminalOwnFocus,
                  let terminalView = self.terminalView else { return }
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    func restoreExpectedFocus() {
        guard visibilityState == .selected, isShellReadyForInput else { return }
        if shouldAuthoritativeTerminalOwnFocus {
            focusAuthoritativeTerminal()
        } else {
            requestFocus(.composer)
        }
    }

    /// Repairs an existing terminal focus intent after AppKit reparents the
    /// persistent host. It deliberately neither creates intent nor advances
    /// the generation, so a newer composer request always wins.
    func restoreAuthoritativeFocusAfterMount() {
        guard visibilityState == .selected,
              focusTarget == .authoritativeTerminal,
              shouldAuthoritativeTerminalOwnFocus,
              terminalMountCoordinator.isTerminalMountedAsExpected,
              let terminalView,
              let window = terminalView.window,
              window.firstResponder !== terminalView else { return }
        let generation = focusGeneration
        guard pendingAuthoritativeFocusRepairGeneration != generation else { return }
        pendingAuthoritativeFocusRepairGeneration = generation
#if DEBUG
        AuthoritativeTerminalRenderInstrumentation.recordFocusRepairAttempt()
#endif
        DispatchQueue.main.async { [weak self] in
            self?.repairAuthoritativeFocus(generation: generation)
        }
        // Returning to compact Blocks can mount the terminal before SwiftUI
        // finishes inserting the adjacent composer. AppKit may reset the
        // responder while that sibling hierarchy settles, so revalidate the
        // same intent once more after the transaction has completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.repairAuthoritativeFocus(generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.repairAuthoritativeFocus(generation: generation)
            if self?.pendingAuthoritativeFocusRepairGeneration == generation {
                self?.pendingAuthoritativeFocusRepairGeneration = nil
            }
        }
    }

    private func repairAuthoritativeFocus(generation: UInt64) {
        guard visibilityState == .selected,
              focusGeneration == generation,
              focusTarget == .authoritativeTerminal,
              shouldAuthoritativeTerminalOwnFocus,
              let terminalView,
              let window = terminalView.window else { return }
        if window.firstResponder !== terminalView {
            window.makeFirstResponder(terminalView)
#if DEBUG
            AuthoritativeTerminalRenderInstrumentation.recordFocusResponderChange()
#endif
        }
    }

    /// Applies geometry and repaint work once for a real mount, presentation,
    /// appearance, or drawable-window transition. Normal terminal output uses
    /// SwiftTerm's own damage path and never enters this method.
    func applyAuthoritativeTerminalAttachmentGeometry(
        lease: TerminalMountLease,
        mount: AuthoritativeTerminalMountView,
        transitionRequiresRedraw: Bool
    ) {
        guard terminalMountCoordinator.isCurrent(lease: lease, mount: mount),
              expectedAuthoritativeTerminalPlacement == lease.placement,
              let host = authoritativeTerminalHostView,
              host.superview === mount,
              let terminalView,
              let window = terminalView.window else {
            lastAuthoritativeGeometrySignature = nil
            return
        }
        let signature = AuthoritativeTerminalGeometrySignature(
            hostID: ObjectIdentifier(host),
            mountID: ObjectIdentifier(mount),
            leaseID: lease.id,
            placement: lease.placement,
            viewportInsets: host.viewportInsets,
            windowID: ObjectIdentifier(window),
            windowAttachmentGeneration: mount.windowAttachmentGeneration,
            mountSize: mount.bounds.size,
            appearanceSignature: paneTerminalAppearanceSignature(for: terminalView)
        )
        guard lastAuthoritativeGeometrySignature != signature else { return }

        let paletteChanged = applyPaneTerminalPalette(to: terminalView)
        mount.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        guard terminalView.bounds.width > 0, terminalView.bounds.height > 0 else { return }
        updateWindowSize(from: terminalView)
        lastAuthoritativeGeometrySignature = signature
        if transitionRequiresRedraw || paletteChanged {
            terminalView.isHidden = false
            terminalView.terminal.updateFullScreen()
            terminalView.setNeedsDisplay(terminalView.bounds)
            terminalView.layer?.setNeedsDisplay()
#if DEBUG
            AuthoritativeTerminalRenderInstrumentation.recordFullScreenInvalidation()
#endif
        }
    }

    func repairTerminalView() {
        terminalMountCoordinator.repairCurrentMount(manual: true)
    }

    var expectedAuthoritativeTerminalPlacement: AuthoritativeTerminalPlacement? {
        guard visibilityState == .selected else { return nil }
        switch activeTerminalPresentation {
        case .fullTerminal:
            return .fullTerminal
        case .authoritativeInBlock:
            guard let blockID = activeCommandBlock?.id else { return nil }
            return .embeddedDirect(blockID: blockID)
        case .expanded:
            guard let blockID = activeCommandBlock?.id else { return nil }
            return .expandedAlternateScreen(blockID: blockID)
        case .hidden, .liveMirror:
            return nil
        }
    }

    var shouldEmbedAuthoritativeTerminalInActiveBlock: Bool {
        activeTerminalPresentation == .authoritativeInBlock
            || activeTerminalPresentation == .expanded
    }

    var activeTerminalPresentation: ActiveTerminalPresentation {
        guard isCommandActive else { return mode == .terminal ? .fullTerminal : .hidden }
        if mode == .terminal { return .fullTerminal }
        if isAlternateScreenActive { return .expanded }
        if inputRequirement == .direct || inputRequirement == .secure {
            return .authoritativeInBlock
        }
        return .liveMirror
    }

#if DEBUG
    var debugAuthoritativeTerminalView: TerminalView? { terminalView }
    var debugAuthoritativeHostView: NSView? { authoritativeTerminalHostView }
    var debugProcessGeneration: UInt64 { processGeneration }
    var debugPTYWindowSize: winsize { ptyController.windowSize }
    var debugHasForegroundProcess: Bool {
        guard let status = ptyController.foregroundStatus() else { return false }
        return status.processGroupID != status.shellProcessGroupID
    }
#endif

    var shouldPresentExpandedAuthoritativeTerminal: Bool {
        activeTerminalPresentation == .expanded
    }

    var shouldPresentCompactAuthoritativeTerminal: Bool {
        activeTerminalPresentation == .authoritativeInBlock
    }

    /// Pane's precmd marker is emitted only after the foreground command has
    /// returned to the persistent shell. It is the authoritative boundary for
    /// leaving secure input; a termios poll can otherwise miss a short ECHO
    /// transition or observe the shell line editor changing flags again.
    private func handleNormalPromptBoundary() {
        let modeBeforeSecureInput = modeBeforeManualSecureInput
        modeBeforeManualSecureInput = nil
        manualSecureInputActive = false
        updateSecurityState(echoEnabled: true, source: .applicationSignal)
        if modeBeforeSecureInput == .blocks {
            setMode(.blocks)
        }
        lastForegroundSnapshot = nil

        guard !isAlternateScreenActive else { return }
        if mode == .terminal {
            return
        }
        modeAttribution = .manual
        requestFocus(.composer)
    }

    private func enqueueDirectTerminalCommand(_ command: String) {
        let sanitized = sensitiveDataSanitizer.sanitizeCommand(command)
        let visibleCommand = sanitized.redactionCount == 0
            ? sanitized.value
            : "[Sensitive command omitted]"
        let id = blockLifecycleController.queue(
            command: visibleCommand,
            workingDirectory: currentDirectory ?? shellConfiguration.workingDirectory,
            isRerunnable: sanitized.redactionCount == 0
        )
        blockLifecycleController.markAwaitingStart(id)
        selectedBlockID = id
        if isCommandHistoryEnabled, sanitized.redactionCount == 0 {
            history.append(sanitized.value)
        } else {
            history.resetNavigation()
        }
    }

    private func foregroundProcessSnapshot() -> ForegroundProcessSnapshot? {
        guard let status = ptyController.foregroundStatus() else { return nil }

        return ForegroundProcessSnapshot(
            processGroupID: status.processGroupID,
            shellProcessGroupID: status.shellProcessGroupID,
            processName: Self.processName(forProcessGroupID: status.processGroupID),
            isRawInput: status.isRawInput,
            echoEnabled: status.echoEnabled
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

    func leaveAlternateScreenIfNeeded() {
        guard terminalView?.terminal.isCurrentBufferAlternate == true else {
            handleAlternateScreenChanged(false)
            return
        }

        terminalView?.feed(text: "\u{001B}[?1049l")
        handleAlternateScreenChanged(false)
    }

    private func send(bytes: [UInt8]) -> Bool {
        ptyController.write(bytes)
    }

    private func acceptsUserTerminalInteraction(from source: TerminalView) -> Bool {
        terminalView === source
            && visibilityState == .selected
            && !isShuttingDown
            && isShellReadyForInput
            && (
                mode == .terminal
                    || inputRequirement == .direct
                    || inputRequirement == .secure
            )
    }

    func shellEnvironmentValue(named name: String) -> String? {
        let prefix = name + "="
        guard let entry = shellConfiguration.environment.first(where: {
            $0.hasPrefix(prefix)
        }) else { return nil }
        return String(entry.dropFirst(prefix.count))
    }

    func invalidateCompletionEndpoint() {
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

        _ = ptyController.resize(to: newWindowSize)
    }
}

extension TerminalSession: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        assert(Thread.isMainThread)
        MainActor.assumeIsolated {
            guard self.acceptsUserTerminalInteraction(from: source) else { return }
            _ = self.send(bytes: bytes)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        assert(Thread.isMainThread)
        MainActor.assumeIsolated {
            guard self.terminalView === source,
                  !self.isShuttingDown,
                  self.visibilityState != .closing else { return }
            self.updateWindowSize(from: source)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        assert(Thread.isMainThread)
        MainActor.assumeIsolated {
            guard self.terminalView === source,
                  !self.isShuttingDown,
                  self.visibilityState != .closing else { return }
            if self.terminalTitle != title {
                self.terminalTitle = title
            }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        assert(Thread.isMainThread)
        MainActor.assumeIsolated {
            guard self.terminalView === source,
                  !self.isShuttingDown,
                  self.visibilityState != .closing else { return }
            if self.currentDirectory != directory {
                self.currentDirectory = directory
            }
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        assert(Thread.isMainThread)
        MainActor.assumeIsolated {
            guard self.acceptsUserTerminalInteraction(from: source) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    nonisolated func clipboardRead(source: TerminalView) -> Data? {
        assert(Thread.isMainThread)
        return MainActor.assumeIsolated {
            guard self.acceptsUserTerminalInteraction(from: source) else { return nil }
            return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
