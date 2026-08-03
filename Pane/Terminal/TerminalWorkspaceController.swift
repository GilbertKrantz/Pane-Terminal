import Combine
import Foundation

enum NewTabDirectoryPolicy: Sendable {
    case defaultDirectory
    case homeDirectory
    case selectedTabDirectory
    case explicit(URL)
}

enum TabTitleSource: String, Codable, Sendable {
    case automatic, shell, process, directory, custom
}

enum TabActivityState: String, Codable, Equatable, Sendable {
    case idle, running, waitingForInput, secureInput, alternateScreen, exited, failed
}

enum TabActivityIndicator: Equatable, Sendable {
    case dot
    case symbol(String)
}

enum TabActivityColorRole: Equatable, Sendable {
    case muted
    case accent
    case failure
}

struct TabActivityPresentation: Equatable, Sendable {
    let indicator: TabActivityIndicator
    let colorRole: TabActivityColorRole
    let indicatorSize: CGFloat
    let animates: Bool
    let tooltip: String
    let accessibilityLabel: String
}

enum TabTitleTruncation: Equatable, Sendable {
    case middle, tail
}

struct TabPresentationModel: Equatable, Sendable {
    let title: String
    let tooltip: String
    let accessibilityLabel: String
    let activity: TabActivityPresentation
    let truncation: TabTitleTruncation
    let isSelected: Bool
}

enum TabStartupState: Equatable, Sendable {
    case creating, startingShell, ready, failed(String)
}

enum SessionVisibilityState: Equatable, Sendable {
    case selected, background, closing
}

enum TabClosePolicy: Sendable {
    case requestUserConfirmation, force, closeIfIdle
}

enum TabCloseResult: Equatable, Sendable {
    case closed, requiresConfirmation(processName: String), notFound
}

enum TerminalWorkspaceLifecycleState: Sendable {
    case initializing, ready, restoring, shuttingDown
}

struct TerminalSessionConfiguration: Sendable {
    let tabID: UUID
    let initialDirectory: URL
    let shellConfiguration: ShellConfiguration
    let restoredMode: InputMode?
    let restoredDraft: String?
    let restoredTitle: String?
}

@MainActor
protocol TerminalSessionFactory {
    func makeSession(configuration: TerminalSessionConfiguration) -> TerminalSession
}

@MainActor
final class DefaultTerminalSessionFactory: TerminalSessionFactory {
    private let runtimeStateControllerProvider: () -> RuntimeStateController?
    private let commandHistoryEnabledProvider: () -> Bool

    init(runtimeStateControllerProvider: @escaping () -> RuntimeStateController?, commandHistoryEnabled: Bool) {
        self.runtimeStateControllerProvider = runtimeStateControllerProvider
        self.commandHistoryEnabledProvider = { commandHistoryEnabled }
    }

    init(
        runtimeStateControllerProvider: @escaping () -> RuntimeStateController?,
        commandHistoryEnabledProvider: @escaping () -> Bool
    ) {
        self.runtimeStateControllerProvider = runtimeStateControllerProvider
        self.commandHistoryEnabledProvider = commandHistoryEnabledProvider
    }

    func makeSession(configuration: TerminalSessionConfiguration) -> TerminalSession {
        var shell = configuration.shellConfiguration
        shell.workingDirectory = configuration.initialDirectory.path
        let session = TerminalSession(
            tabID: configuration.tabID,
            shellConfiguration: shell,
            runtimeStateController: runtimeStateControllerProvider(),
            commandHistoryEnabled: commandHistoryEnabledProvider()
        )
        if let mode = configuration.restoredMode { session.restoreModeWhenReady(mode) }
        if let draft = configuration.restoredDraft { session.commandDraft = draft }
        return session
    }
}

struct TerminalTabRestorationMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let order: Int
    let title: String?
    let titleSource: TabTitleSource
    let workingDirectoryPath: String
    let shellConfigurationID: String?
    let mode: InputMode
    let safeComposerDraft: String?
    let createdAt: Date
    let lastSelectedAt: Date
    let hadActiveWork: Bool
}

struct TerminalWorkspaceSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let selectedTabID: UUID?
    let orderedTabs: [TerminalTabRestorationMetadata]
    let savedAt: Date
}

struct WorkspaceFocusGeneration: Equatable, Sendable {
    let selectedTabID: UUID
    let generation: UInt64
}

struct TerminalWorkspaceDebugSnapshot: Sendable {
    let lifecycleState: TerminalWorkspaceLifecycleState
    let selectedTabID: UUID?
    let orderedTabIDs: [UUID]
    let sessionCount: Int
    let closingTabIDs: Set<UUID>
    let selectionGeneration: UInt64
    let pendingFocusTabID: UUID?
}

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id: UUID
    let session: TerminalSession
    @Published var title: String
    @Published var titleSource: TabTitleSource
    @Published var isPinned = false
    @Published var activityState: TabActivityState = .idle
    @Published var hasUnreadActivity = false
    @Published var startupState: TabStartupState = .creating
    @Published var lastSelectedAt: Date
    @Published var showsInterruptedSessionNotice: Bool
    let createdAt: Date
    var onRestorationMetadataChange: (() -> Void)?
    private var observations: Set<AnyCancellable> = []
    private var lastObservedRestorationMetadata: TerminalTabRestorationMetadata?

    var currentDirectory: URL {
        URL(fileURLWithPath: session.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    init(id: UUID, session: TerminalSession, title: String?, titleSource: TabTitleSource = .automatic,
         createdAt: Date = Date(), lastSelectedAt: Date = Date(),
         showsInterruptedSessionNotice: Bool = false) {
        self.id = id
        self.session = session
        self.title = Self.sanitize(title) ?? "Pane"
        self.titleSource = titleSource
        self.createdAt = createdAt
        self.lastSelectedAt = lastSelectedAt
        self.showsInterruptedSessionNotice = showsInterruptedSessionNotice
        observeSession()
    }

    var restorationMetadata: TerminalTabRestorationMetadata {
        TerminalTabRestorationMetadata(
            id: id, order: 0, title: titleSource == .custom ? title : nil,
            titleSource: titleSource, workingDirectoryPath: currentDirectory.path,
            shellConfigurationID: nil, mode: session.mode,
            safeComposerDraft: session.isSecureInputActive ? nil : session.commandDraft,
            createdAt: createdAt, lastSelectedAt: lastSelectedAt,
            hadActiveWork: session.hasActiveWork
        )
    }

    func presentation(isSelected: Bool, index: Int, count: Int) -> TabPresentationModel {
        let activity = activityState.presentation(hasUnreadActivity: hasUnreadActivity)
        return TabPresentationModel(
            title: title,
            tooltip: "\(title)\n\(currentDirectory.path)\n\(session.activeProcessLabel) · \(activity.tooltip)",
            accessibilityLabel: "\(isSelected ? "Selected tab" : "Tab \(index + 1) of \(count)"), \(title), \(activity.accessibilityLabel)",
            activity: activity,
            truncation: title.contains("@") ? .middle : .tail,
            isSelected: isSelected
        )
    }

    func rename(_ value: String) {
        guard let value = Self.sanitize(value) else { return }
        title = value
        titleSource = .custom
        notifyIfRestorationMetadataChanged()
    }

    func resetAutomaticTitle() {
        titleSource = .automatic
        refreshAutomaticTitle()
        notifyIfRestorationMetadataChanged()
    }

    private func observeSession() {
        observe(session.$terminalTitle)
        observe(session.$currentDirectory)
        observe(session.$blockTimeline)
        observe(session.$mode)
        observe(session.$inputRequirement)
        observe(session.$isShellRunning)
        observe(session.$shellExitStatus)
        observe(session.$shellReadiness)
        observe(session.$terminalSecurityState)
        observe(session.$isAlternateScreenActive)
        observe(session.$isRestartInProgress)
        observe(session.$isShuttingDown)
        observe(session.$commandDraft)
        session.onMeaningfulBackgroundOutput = { [weak self] in
            guard let self, !self.hasUnreadActivity else { return }
            self.hasUnreadActivity = true
        }
        refreshDerivedState()
    }

    private func observe<Value: Equatable>(
        _ publisher: Published<Value>.Publisher
    ) {
        publisher
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshDerivedState()
            }
            .store(in: &observations)
    }

    private func refreshDerivedState() {
        if titleSource != .custom { refreshAutomaticTitle() }
        if session.isShuttingDown { return }
        if !session.isShellRunning && session.shellReadiness == .stopped {
            activityState = session.shellExitStatus.map { $0 == 0 ? .exited : .failed } ?? .exited
        } else if session.isSecureInputActive {
            activityState = .secureInput
        } else if session.isAlternateScreenActive {
            activityState = .alternateScreen
        } else if session.inputRequirement == .direct {
            activityState = .waitingForInput
        } else if session.hasActiveWork {
            activityState = .running
        } else {
            activityState = .idle
        }
        startupState = session.isShellReadyForInput ? .ready : .startingShell
        notifyIfRestorationMetadataChanged()
    }

    private func refreshAutomaticTitle() {
        let candidate: String
        if session.hasActiveWork, let process = session.foregroundProcessName { candidate = process }
        else {
            let url = currentDirectory
            if url.path != FileManager.default.homeDirectoryForCurrentUser.path {
                candidate = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
            } else if session.terminalTitle != "Pane" {
                candidate = session.terminalTitle
            } else {
                candidate = "Home"
            }
        }
        if let sanitized = Self.sanitize(candidate) { title = sanitized }
    }

    static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.map(String.init).joined()
            .split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(200))
    }

    private func notifyIfRestorationMetadataChanged() {
        let metadata = restorationMetadata
        guard metadata != lastObservedRestorationMetadata else { return }
        lastObservedRestorationMetadata = metadata
        onRestorationMetadataChange?()
    }
}

extension TabActivityState {
    func presentation(hasUnreadActivity: Bool) -> TabActivityPresentation {
        let base: TabActivityPresentation
        switch self {
        case .idle:
            base = TabActivityPresentation(
                indicator: .dot,
                colorRole: hasUnreadActivity ? .accent : .muted,
                indicatorSize: 5,
                animates: false,
                tooltip: hasUnreadActivity ? "unread activity" : "idle",
                accessibilityLabel: hasUnreadActivity ? "Unread activity" : "Idle"
            )
        case .running:
            base = TabActivityPresentation(
                indicator: .dot,
                colorRole: .accent,
                indicatorSize: 6,
                animates: false,
                tooltip: hasUnreadActivity ? "running · unread activity" : "running",
                accessibilityLabel: hasUnreadActivity ? "Running, unread activity" : "Running"
            )
        case .waitingForInput:
            base = TabActivityPresentation(
                indicator: .symbol("keyboard"),
                colorRole: .muted,
                indicatorSize: 8,
                animates: false,
                tooltip: hasUnreadActivity ? "waiting for input · unread activity" : "waiting for input",
                accessibilityLabel: hasUnreadActivity ? "Waiting for input, unread activity" : "Waiting for input"
            )
        case .secureInput:
            base = TabActivityPresentation(
                indicator: .symbol("lock.fill"),
                colorRole: .muted,
                indicatorSize: 8,
                animates: false,
                tooltip: "secure input",
                accessibilityLabel: "Secure input"
            )
        case .alternateScreen:
            base = TabActivityPresentation(
                indicator: .dot,
                colorRole: .accent,
                indicatorSize: 6,
                animates: false,
                tooltip: hasUnreadActivity ? "alternate screen · unread activity" : "alternate screen",
                accessibilityLabel: hasUnreadActivity ? "Alternate screen, unread activity" : "Alternate screen"
            )
        case .exited:
            base = TabActivityPresentation(
                indicator: .symbol("xmark.circle"),
                colorRole: .failure,
                indicatorSize: 8,
                animates: false,
                tooltip: "exited",
                accessibilityLabel: "Exited"
            )
        case .failed:
            base = TabActivityPresentation(
                indicator: .symbol("exclamationmark.circle.fill"),
                colorRole: .failure,
                indicatorSize: 8,
                animates: false,
                tooltip: "failed",
                accessibilityLabel: "Failed"
            )
        }
        return base
    }
}

@MainActor
final class TerminalWorkspaceController: ObservableObject {
    static let maximumLiveTabs = 32
    @Published private(set) var tabs: [TerminalTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published private(set) var lifecycleState: TerminalWorkspaceLifecycleState = .initializing
    @Published var pendingCloseTab: TerminalTab?
    @Published private(set) var creationLimitReached = false
    @Published private(set) var persistenceStatus = PersistenceDiagnostic(
        status: .ready,
        failureCategory: nil,
        schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
        recoveryFileName: nil,
        message: nil
    )

    private let factory: TerminalSessionFactory
    private let snapshotURL: URL
    private let snapshotStore: WorkspaceSnapshotStore
    private let defaultShell: ShellConfiguration
    private var preferenceSnapshot = PanePreferencesSnapshot.defaults
    private var selectionGeneration: UInt64 = 0
    private var closingTabs: [UUID: TerminalTab] = [:]
    private var persistTask: Task<Void, Never>?
    private let lifecycleFaultCheckpointHandler:
        (@MainActor @Sendable (PaneLifecycleFaultCheckpoint) -> Void)?

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }
    private var closingTabIDs: Set<UUID> { Set(closingTabs.keys) }
    var debugSnapshot: TerminalWorkspaceDebugSnapshot {
        TerminalWorkspaceDebugSnapshot(lifecycleState: lifecycleState, selectedTabID: selectedTabID,
            orderedTabIDs: tabs.map(\.id), sessionCount: tabs.count, closingTabIDs: closingTabIDs,
            selectionGeneration: selectionGeneration, pendingFocusTabID: selectedTabID)
    }

    init(
        factory: TerminalSessionFactory,
        snapshotURL: URL,
        defaultShell: ShellConfiguration = .loginZsh(),
        snapshotStore: WorkspaceSnapshotStore? = nil,
        lifecycleFaultCheckpointHandler:
            (@MainActor @Sendable (PaneLifecycleFaultCheckpoint) -> Void)? = nil
    ) {
        self.factory = factory
        self.snapshotURL = snapshotURL
        self.snapshotStore = snapshotStore
            ?? WorkspaceSnapshotStore(snapshotURL: snapshotURL)
        self.defaultShell = defaultShell
        self.lifecycleFaultCheckpointHandler = lifecycleFaultCheckpointHandler
    }

    @discardableResult
    func createTab(
        configuration: TerminalSessionConfiguration,
        select: Bool = true,
        at index: Int? = nil,
        restorationMetadata: TerminalTabRestorationMetadata? = nil
    ) async -> UUID {
        guard tabs.count < Self.maximumLiveTabs else {
            creationLimitReached = true
            return selectedTabID ?? configuration.tabID
        }
        creationLimitReached = false
        lifecycleFaultCheckpointHandler?(.tabCreationStarted)
        let session = factory.makeSession(configuration: configuration)
        session.applyRuntimeStateConfiguration(preferenceSnapshot.history.runtimeConfiguration)
        session.visibilityState = select ? .selected : .background
        // Starting is independent of mounting: background tabs must own a
        // live PTY and continue receiving output before they are first shown.
        session.ensureAuthoritativeTerminalIsRunning()
        session.applyAppearancePreferences(preferenceSnapshot.appearance)
        session.applyKeyboardPreferences(preferenceSnapshot.terminal)
        session.applyScrollbackPreference(preferenceSnapshot.terminal)
        lifecycleFaultCheckpointHandler?(.tabCreationPTYStarted)
        let tab = TerminalTab(
            id: configuration.tabID,
            session: session,
            title: configuration.restoredTitle,
            titleSource: restorationMetadata?.titleSource ?? .automatic,
            createdAt: restorationMetadata?.createdAt ?? Date(),
            lastSelectedAt: restorationMetadata?.lastSelectedAt ?? Date(),
            showsInterruptedSessionNotice: restorationMetadata?.hadActiveWork ?? false
        )
        tab.onRestorationMetadataChange = { [weak self] in
            self?.schedulePersistence()
        }
        let insertion = min(max(index ?? tabs.count, 0), tabs.count)
        tabs.insert(tab, at: insertion)
        lifecycleFaultCheckpointHandler?(.tabCreationInstalled)
        if select || selectedTabID == nil { selectTab(id: tab.id) }
        schedulePersistence()
        return tab.id
    }

    @discardableResult
    func createTab(directoryPolicy: NewTabDirectoryPolicy? = nil, inBackground: Bool = false) async -> UUID? {
        guard lifecycleState != .shuttingDown else { return nil }
        guard tabs.count < Self.maximumLiveTabs else { creationLimitReached = true; return nil }
        let directory = resolvedDirectory(for: directoryPolicy ?? preferredNewTabDirectoryPolicy)
        let id = UUID()
        let config = TerminalSessionConfiguration(tabID: id, initialDirectory: directory,
            shellConfiguration: configuredShell, restoredMode: preferenceSnapshot.general.defaultInputMode,
            restoredDraft: nil, restoredTitle: nil)
        return await createTab(configuration: config, select: !inBackground)
    }

    func selectTab(id: UUID) {
        guard lifecycleState != .shuttingDown else { return }
        guard !closingTabIDs.contains(id), let tab = tabs.first(where: { $0.id == id }) else { return }
        let signpost = PanePerformanceSignposts.beginTabSwitch()
        defer { PanePerformanceSignposts.endTabSwitch(signpost) }
        tabs.forEach { $0.session.visibilityState = $0.id == id ? .selected : .background }
        selectedTabID = id
        tab.lastSelectedAt = Date()
        tab.hasUnreadActivity = false
        selectionGeneration &+= 1
        Task {
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .sessionSelected,
                tabID: tab.id,
                sessionID: tab.session.sessionID,
                outcome: .succeeded
            ))
        }
        let focus = WorkspaceFocusGeneration(selectedTabID: id, generation: selectionGeneration)
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.selectedTabID == focus.selectedTabID,
                  self.selectionGeneration == focus.generation else { return }
            tab.session.restoreExpectedFocus()
        }
        schedulePersistence()
    }

    func closeTab(id: UUID, policy: TabClosePolicy) async -> TabCloseResult {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return .notFound }
        let tab = tabs[index]
        if tab.session.hasActiveWork && policy != .force {
            if policy == .requestUserConfirmation { pendingCloseTab = tab }
            return .requiresConfirmation(processName: tab.session.foregroundProcessName ?? tab.session.shellDisplayName)
        }
        lifecycleFaultCheckpointHandler?(.tabCloseStarted)
        closingTabs[id] = tab
        tab.session.visibilityState = .closing
        tabs.remove(at: index)
        lifecycleFaultCheckpointHandler?(.tabCloseRemoved)
        pendingCloseTab = nil
        if selectedTabID == id {
            selectedTabID = nil
            if !tabs.isEmpty { selectTab(id: tabs[min(index, tabs.count - 1)].id) }
            else { _ = await createTab(directoryPolicy: .defaultDirectory) }
        }
        schedulePersistence()
        _ = await tab.session.shutdownAndWait()
        closingTabs.removeValue(forKey: id)
        lifecycleFaultCheckpointHandler?(.tabCloseCleanupCompleted)
        return .closed
    }

    func moveTab(id: UUID, to destinationIndex: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(max(destinationIndex, 0), tabs.count))
        schedulePersistence()
    }

    func duplicateTab(id: UUID) async -> UUID? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        return await createTab(directoryPolicy: .explicit(tab.currentDirectory))
    }

    func selectRelative(offset: Int) {
        guard !tabs.isEmpty, let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectTab(id: tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func applyRuntimeStateConfiguration(_ configuration: RuntimeStateConfiguration) {
        tabs.forEach { $0.session.applyRuntimeStateConfiguration(configuration) }
    }

    /// Central propagation boundary: sessions consume targeted configuration,
    /// never the mutable application preference owner.
    func applyPreferences(_ snapshot: PanePreferencesSnapshot, changedKeys: Set<PanePreferenceKey>) {
        preferenceSnapshot = snapshot
        if changedKeys.contains(.historyConfiguration) {
            applyRuntimeStateConfiguration(snapshot.history.runtimeConfiguration)
        }
        if !changedKeys.isDisjoint(with: [.appearanceMode, .terminalFont, .terminalFontSize]) {
            tabs.forEach { $0.session.applyAppearancePreferences(snapshot.appearance) }
        }
        if changedKeys.contains(.optionKeyBehaviour) {
            tabs.forEach { $0.session.applyKeyboardPreferences(snapshot.terminal) }
        }
        if changedKeys.contains(.scrollbackLimit) {
            tabs.forEach { $0.session.applyScrollbackPreference(snapshot.terminal) }
        }
        // Presentation, keyboard, and completion propagation are deliberately
        // routed here as their session configuration APIs evolve; shell values
        // are only consumed by newly-created or explicitly restarted shells.
    }

    func restoreWorkspace() async {
        guard lifecycleState == .initializing else { return }
        lifecycleState = .restoring
        defer { lifecycleState = .ready }
        guard let snapshot = await snapshotStore.load() else {
            persistenceStatus = await snapshotStore.diagnostic()
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .persistenceRead,
                tabID: nil,
                sessionID: nil,
                outcome: .fallbackUsed
            ))
            _ = await createTab(directoryPolicy: .defaultDirectory)
            return
        }
        persistenceStatus = await snapshotStore.diagnostic()
        await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
            timestamp: Date(),
            kind: .persistenceRead,
            tabID: nil,
            sessionID: nil,
            outcome: persistenceStatus.status == .ready ? .succeeded : .fallbackUsed
        ))
        var seen: Set<UUID> = []
        for metadata in snapshot.orderedTabs.sorted(by: { $0.order < $1.order }) where seen.insert(metadata.id).inserted {
            let directory = Self.nearestExistingDirectory(metadata.workingDirectoryPath)
            let config = TerminalSessionConfiguration(tabID: metadata.id, initialDirectory: directory,
                shellConfiguration: defaultShell, restoredMode: metadata.mode,
                restoredDraft: metadata.safeComposerDraft, restoredTitle: metadata.title)
            _ = await createTab(
                configuration: config,
                select: false,
                restorationMetadata: metadata
            )
            if let tab = tabs.first(where: { $0.id == metadata.id }) {
                if metadata.titleSource == .custom, let title = metadata.title {
                    tab.rename(title)
                }
            }
        }
        if tabs.isEmpty { _ = await createTab(directoryPolicy: .defaultDirectory) }
        selectTab(id: tabs.contains(where: { $0.id == snapshot.selectedTabID }) ? snapshot.selectedTabID! : tabs[0].id)
    }

    func persistWorkspace() async {
        let signpost = PanePerformanceSignposts.beginWorkspacePersistence()
        defer { PanePerformanceSignposts.endWorkspacePersistence(signpost) }
        let metadata = tabs.enumerated().map { index, tab -> TerminalTabRestorationMetadata in
            let value = tab.restorationMetadata
            return TerminalTabRestorationMetadata(id: value.id, order: index, title: value.title,
                titleSource: value.titleSource, workingDirectoryPath: value.workingDirectoryPath,
                shellConfigurationID: value.shellConfigurationID, mode: value.mode,
                safeComposerDraft: value.safeComposerDraft, createdAt: value.createdAt,
                lastSelectedAt: value.lastSelectedAt, hadActiveWork: value.hadActiveWork)
        }
        let snapshot = TerminalWorkspaceSnapshot(schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            selectedTabID: selectedTabID, orderedTabs: metadata, savedAt: Date())
        do {
            try await snapshotStore.save(snapshot)
        } catch {
            // Persistence is deliberately non-fatal to live terminals. The
            // typed, sanitized status remains available to diagnostics/UI.
        }
        persistenceStatus = await snapshotStore.diagnostic()
        await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
            timestamp: Date(),
            kind: .persistenceWrite,
            tabID: nil,
            sessionID: nil,
            outcome: persistenceStatus.status == .ready ? .succeeded : .failed
        ))
    }

    func diagnosticsSnapshot(
        persistenceStatus: PersistenceDiagnostic? = nil
    ) async -> PaneDiagnosticsSnapshot {
        var sessionDiagnostics: [TerminalSessionDiagnostics] = []
        sessionDiagnostics.reserveCapacity(tabs.count + closingTabs.count)
        for tab in tabs + Array(closingTabs.values) {
            sessionDiagnostics.append(await tab.session.diagnostics())
        }
        sessionDiagnostics.sort {
            if $0.tabID == $1.tabID {
                return $0.sessionID.uuidString < $1.sessionID.uuidString
            }
            return $0.tabID.uuidString < $1.tabID.uuidString
        }
        let events = await PaneLifecycleEventRing.shared.snapshot()
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        return PaneDiagnosticsSnapshot(
            workspace: PaneWorkspaceDiagnostics(
                lifecycleState: String(describing: lifecycleState),
                selectedTabID: selectedTabID,
                tabCount: tabs.count
            ),
            sessions: sessionDiagnostics,
            resourceCounters: PaneResourceCounters.snapshot,
            processMetrics: PaneProcessMetrics.snapshot(),
            persistenceStatus: persistenceStatus ?? self.persistenceStatus,
            lifecycleEvents: events,
            appVersion: appVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            timestamp: Date()
        )
    }

    func shutdown() async {
        guard lifecycleState != .shuttingDown else { return }
        lifecycleState = .shuttingDown
        persistTask?.cancel()
        let sessions = Array(
            Dictionary(
                uniqueKeysWithValues: (tabs + Array(closingTabs.values)).map {
                    ($0.session.sessionID, $0.session)
                }
            ).values
        )
        // Detach every PTY before workspace persistence. A slow state store
        // must not keep shells, completion sockets, or terminal callbacks alive
        // while application termination is already in progress.
        sessions.forEach { $0.terminateForApplicationExit() }
        await persistWorkspace()
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { @MainActor in
                    await session.finalizeApplicationExit()
                }
            }
            await group.waitForAll()
        }
        closingTabs.removeAll()
    }

    func terminateAllForApplicationExit() {
        let sessions = Dictionary(
            uniqueKeysWithValues: (tabs + Array(closingTabs.values)).map {
                ($0.session.sessionID, $0.session)
            }
        ).values
        sessions.forEach { $0.terminateForApplicationExit() }
    }

    private func schedulePersistence() {
        guard lifecycleState != .restoring, lifecycleState != .shuttingDown else { return }
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.persistWorkspace()
        }
    }

    private func resolvedDirectory(for policy: NewTabDirectoryPolicy) -> URL {
        let proposed: URL
        switch policy {
        case .defaultDirectory: proposed = URL(fileURLWithPath: defaultShell.workingDirectory)
        case .homeDirectory: proposed = FileManager.default.homeDirectoryForCurrentUser
        case .selectedTabDirectory: proposed = selectedTab?.currentDirectory ?? URL(fileURLWithPath: defaultShell.workingDirectory)
        case .explicit(let url): proposed = url
        }
        return Self.nearestExistingDirectory(proposed.path)
    }

    private var preferredNewTabDirectoryPolicy: NewTabDirectoryPolicy {
        switch preferenceSnapshot.general.newTabDirectoryPolicy {
        case .selectedTabDirectory: return .selectedTabDirectory
        case .homeDirectory: return .homeDirectory
        case .customDirectory:
            guard let path = preferenceSnapshot.general.customDefaultDirectoryPath else {
                return .homeDirectory
            }
            return .explicit(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private var configuredShell: ShellConfiguration {
        var shell = defaultShell
        if preferenceSnapshot.terminal.shellSelection == .customExecutable,
           let executable = preferenceSnapshot.terminal.customShellPath,
           FileManager.default.isExecutableFile(atPath: executable) {
            shell.executable = executable
        }
        shell.arguments = preferenceSnapshot.terminal.launchAsLoginShell ? ["-l", "-i"] : ["-i"]
        return shell
    }

    static func nearestExistingDirectory(_ path: String) -> URL {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return FileManager.default.homeDirectoryForCurrentUser }
            url = parent
        }
        return url
    }
}
