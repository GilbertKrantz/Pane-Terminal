import Foundation

struct RuntimeStateConfiguration: Sendable, Equatable {
    var persistenceEnabled: Bool
    var commandHistoryEnabled: Bool
    var visibleSessionRecoveryEnabled: Bool
    var predictionContextEnabled: Bool
    var outputSummariesEnabled: Bool
    var filePathCollectionEnabled: Bool
    var restoreAcrossWorkspacesEnabled: Bool = false
    var maximumRestoredSessions: Int = 3
    var maximumRestoredCommands: Int = 200
    var maximumRestoredOutputBytes: Int = 2 * 1_024 * 1_024
}

struct RuntimeStateOperationResult: Sendable {
    let restoredContext: PersistedRuntimeContext?
    let diagnostic: String?
    let restoresCommandHistory: Bool
    let restoresVisibleBlocks: Bool

    init(
        restoredContext: PersistedRuntimeContext?,
        diagnostic: String?,
        restoresCommandHistory: Bool = false,
        restoresVisibleBlocks: Bool = false
    ) {
        self.restoredContext = restoredContext
        self.diagnostic = diagnostic
        self.restoresCommandHistory = restoresCommandHistory
        self.restoresVisibleBlocks = restoresVisibleBlocks
    }
}

/// Owns durable and ephemeral runtime history without putting SQLite work on
/// the terminal session's MainActor. Callers must provide already-sanitized
/// events; the SQLite store performs a second sanitization pass before writes.
actor RuntimeStateController {
    private let databaseURL: URL
    private let persistenceCoordinator: RuntimeStatePersistenceCoordinator
    private let ephemeralStore: InMemoryRuntimeStateStore
    private var configuration: RuntimeStateConfiguration
    private var currentSession: RuntimeSession?
    private var previousBehavioralCommand: BehavioralCommandRecord?

    init(
        databaseURL: URL,
        configuration: RuntimeStateConfiguration,
        ephemeralStore: InMemoryRuntimeStateStore = InMemoryRuntimeStateStore()
    ) {
        self.databaseURL = databaseURL
        self.configuration = configuration
        self.ephemeralStore = ephemeralStore
        self.persistenceCoordinator = RuntimeStatePersistenceCoordinator(
            databaseURL: databaseURL,
            ephemeralStore: ephemeralStore
        )
    }

    init(
        persistenceCoordinator: RuntimeStatePersistenceCoordinator,
        configuration: RuntimeStateConfiguration
    ) {
        self.databaseURL = persistenceCoordinator.databaseURL
        self.configuration = configuration
        self.ephemeralStore = persistenceCoordinator.ephemeralStore
        self.persistenceCoordinator = persistenceCoordinator
    }

    /// Releases the durable SQLite handle when a controller is used outside
    /// Pane's shared application coordinator, such as isolated test or tool
    /// runs. The application continues to shut its shared coordinator down
    /// once after every workspace session has finalized.
    func shutdown() async {
        await persistenceCoordinator.shutdown()
        currentSession = nil
        previousBehavioralCommand = nil
    }

    func startSession(_ session: RuntimeSession, restoreLimit: Int = 200) async -> RuntimeStateOperationResult {
        previousBehavioralCommand = nil
        currentSession = storageSafeSession(session)
        guard let currentSession else {
            return RuntimeStateOperationResult(restoredContext: nil, diagnostic: nil)
        }

        do {
            try await ephemeralStore.startSession(currentSession)
        } catch {
            return RuntimeStateOperationResult(
                restoredContext: nil,
                diagnostic: "Ephemeral session history is unavailable."
            )
        }

        guard configuration.persistenceEnabled else {
            let scope = restorationScope(for: currentSession)
            return RuntimeStateOperationResult(
                restoredContext: try? await ephemeralStore.loadRecentContext(
                    workspaceID: scope.workspaceID,
                    repositoryID: scope.repositoryID,
                    limits: restorationLimits(commandLimit: restoreLimit)
                ),
                diagnostic: nil,
                restoresCommandHistory: configuration.commandHistoryEnabled,
                restoresVisibleBlocks: false
            )
        }

        do {
            _ = try await persistenceCoordinator.prepareCurrentLaunch()
            let store = try await durableStateStore()
            let scope = restorationScope(for: currentSession)
            let context = try await store.loadRecentContext(
                workspaceID: scope.workspaceID,
                repositoryID: scope.repositoryID,
                limits: restorationLimits(commandLimit: restoreLimit)
            )
            try await store.startSession(currentSession)
            await persistenceCoordinator.scheduleMaintenance()
            if configuration.predictionContextEnabled,
               await store.needsBehavioralBackfill() {
                Task {
                    // Keep migration/backfill completely off the shell-start
                    // critical path and away from the initial restore reads.
                    try? await Task.sleep(for: .milliseconds(500))
                    try? await store.backfillBehavioralHistory()
                }
            }
            return RuntimeStateOperationResult(
                restoredContext: context,
                diagnostic: await persistenceCoordinator.diagnostic().message,
                restoresCommandHistory: configuration.commandHistoryEnabled,
                restoresVisibleBlocks: configuration.visibleSessionRecoveryEnabled
            )
        } catch {
            let scope = restorationScope(for: currentSession)
            let fallback = try? await ephemeralStore.loadRecentContext(
                workspaceID: scope.workspaceID,
                repositoryID: scope.repositoryID,
                limit: restoreLimit
            )
            return RuntimeStateOperationResult(
                restoredContext: fallback,
                diagnostic: "Session history could not be opened; Pane is using memory-only history.",
                restoresCommandHistory: configuration.commandHistoryEnabled,
                restoresVisibleBlocks: false
            )
        }
    }

    private func restorationScope(for session: RuntimeSession) -> (workspaceID: String?, repositoryID: String?) {
        guard configuration.restoreAcrossWorkspacesEnabled else {
            guard configuration.filePathCollectionEnabled else {
                return ("pane-anonymous-local-scope", "pane-anonymous-local-scope")
            }
            return (session.workspaceID, session.repositoryID)
        }
        return (nil, nil)
    }

    private func restorationLimits(commandLimit: Int) -> RuntimeStateRestoreLimits {
        RuntimeStateRestoreLimits(
            maximumSessions: configuration.maximumRestoredSessions,
            maximumCommands: min(max(0, commandLimit), max(0, configuration.maximumRestoredCommands)),
            maximumOutputBytes: configuration.maximumRestoredOutputBytes
        )
    }

    private var storesSessionMetadata: Bool {
        configuration.commandHistoryEnabled
            || configuration.visibleSessionRecoveryEnabled
            || configuration.predictionContextEnabled
    }

    func persistCommandEvent(
        _ event: PersistedCommandEvent,
        behavioralEligible: Bool = true
    ) async -> String? {
        guard configuration.commandHistoryEnabled || configuration.visibleSessionRecoveryEnabled else { return nil }
        let event = storageSafeEvent(event)

        do {
            try await ephemeralStore.persistCommandEvent(event)
        } catch {
            return "Session history could not be cached in memory."
        }

        guard configuration.persistenceEnabled else { return nil }
        do {
            let store = try await durableStateStore()
            if let currentSession {
                try await store.startSession(currentSession)
            }
            try await store.persistCommandEvent(event)
            if configuration.predictionContextEnabled, behavioralEligible {
                try await recordBehavioralEvidence(for: event, in: store)
            } else if event.completion != .unknown {
                previousBehavioralCommand = nil
            }
            return nil
        } catch {
            return "Session history could not be saved; Pane is continuing with memory-only history."
        }
    }

    func resetBehavioralTransitionContinuity() {
        previousBehavioralCommand = nil
    }

    func recordCompletionFeedback(_ record: CompletionFeedbackRecord) async -> String? {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else {
            return nil
        }
        do {
            try await durableStateStore().recordFeedback(record)
            return nil
        } catch {
            return "Local completion feedback could not be saved."
        }
    }

    private func recordBehavioralEvidence(
        for event: PersistedCommandEvent,
        in store: SQLiteRuntimeStateStore
    ) async throws {
        guard event.completion != .unknown else { return }
        let sanitized = SensitiveDataSanitizer().sanitizeCommand(event.command)
        let normalized = NormalizedCommand(sanitized.value)
        guard sanitized.redactionCount == 0,
              !normalized.full.isEmpty,
              let commandKey = normalized.commandKey,
              !normalized.full.contains(SensitiveDataSanitizer.redaction),
              !normalized.full.hasPrefix("[Sensitive command"),
              normalized.full != "[command omitted]",
              normalized.full != "<command omitted>" else {
            previousBehavioralCommand = nil
            return
        }
        let outcome: BehavioralCommandOutcome
        switch event.completion {
        case .interrupted:
            outcome = .interrupted
        case .completed:
            outcome = event.exitCode == 0 ? .succeeded : .failed
        case .unknown:
            return
        }
        let record = BehavioralCommandRecord(
            eventID: event.blockID,
            normalizedCommand: normalized.full,
            commandKey: commandKey,
            projectID: currentSession?.repositoryID,
            directoryIdentity: event.workingDirectory,
            outcome: outcome,
            observedAt: event.timestamp
        )
        try await store.recordCommand(record)
        if let previousBehavioralCommand,
           event.timestamp.timeIntervalSince(previousBehavioralCommand.observedAt) >= 0,
           event.timestamp.timeIntervalSince(previousBehavioralCommand.observedAt) <= 30 * 60 {
            try await store.recordTransition(
                previousCommandKey: previousBehavioralCommand.commandKey,
                next: record
            )
        }
        previousBehavioralCommand = record
    }

    func persistFeatures(_ features: [RuntimeFeature]) async -> String? {
        guard configuration.predictionContextEnabled, !features.isEmpty else { return nil }
        do {
            try await ephemeralStore.persistFeatures(features)
            if configuration.persistenceEnabled {
                try await durableStateStore().persistFeatures(features)
            }
            return nil
        } catch {
            return "Local prediction context could not be saved."
        }
    }

    func updateCurrentSessionActivity(workingDirectory: String, at date: Date = Date()) async -> String? {
        guard let currentSession else { return nil }
        let updated = storageSafeSession(RuntimeSession(
            id: currentSession.id,
            workspaceID: Self.workspaceIdentifier(for: workingDirectory),
            repositoryID: currentSession.repositoryID,
            shell: currentSession.shell,
            initialWorkingDirectory: currentSession.initialWorkingDirectory,
            lastWorkingDirectory: workingDirectory,
            startedAt: currentSession.startedAt,
            lastActiveAt: date,
            lifecycle: .active,
            paneVersion: currentSession.paneVersion,
            schemaVersion: currentSession.schemaVersion
        ))
        self.currentSession = updated
        do {
            try await ephemeralStore.startSession(updated)
            if configuration.persistenceEnabled { try await durableStateStore().startSession(updated) }
            return nil
        } catch {
            return "Session activity could not be saved; Pane is continuing with memory-only context."
        }
    }

    func updateCurrentProjectIdentity(_ projectID: String?) async -> String? {
        guard let currentSession, currentSession.repositoryID != projectID else { return nil }
        let updated = storageSafeSession(RuntimeSession(
            id: currentSession.id,
            workspaceID: currentSession.workspaceID,
            repositoryID: projectID,
            shell: currentSession.shell,
            initialWorkingDirectory: currentSession.initialWorkingDirectory,
            lastWorkingDirectory: currentSession.lastWorkingDirectory,
            startedAt: currentSession.startedAt,
            lastActiveAt: currentSession.lastActiveAt,
            lifecycle: currentSession.lifecycle,
            paneVersion: currentSession.paneVersion,
            schemaVersion: currentSession.schemaVersion
        ))
        self.currentSession = updated
        do {
            try await ephemeralStore.startSession(updated)
            if configuration.persistenceEnabled {
                try await durableStateStore().startSession(updated)
            }
            return nil
        } catch {
            return "Project context could not be saved."
        }
    }

    func updateCommandEventCollapsed(_ blockID: UUID, isCollapsed: Bool) async -> String? {
        do {
            try await ephemeralStore.updateCommandEventCollapsed(blockID, isCollapsed: isCollapsed)
            if configuration.persistenceEnabled {
                try await durableStateStore().updateCommandEventCollapsed(blockID, isCollapsed: isCollapsed)
            }
            return nil
        } catch {
            return "Collapsed block state could not be saved."
        }
    }

    func updateConfiguration(
        _ newConfiguration: RuntimeStateConfiguration,
        restoreLimit: Int = 200
    ) async -> RuntimeStateOperationResult {
        let shouldRestore = (!configuration.persistenceEnabled && newConfiguration.persistenceEnabled)
            || (!configuration.visibleSessionRecoveryEnabled && newConfiguration.visibleSessionRecoveryEnabled)
            || (!configuration.commandHistoryEnabled && newConfiguration.commandHistoryEnabled)
            || (!configuration.predictionContextEnabled && newConfiguration.predictionContextEnabled)
        configuration = newConfiguration

        guard storesSessionMetadata else {
            try? await ephemeralStore.deleteAllState()
            return RuntimeStateOperationResult(restoredContext: nil, diagnostic: nil)
        }
        guard shouldRestore, let currentSession else {
            return RuntimeStateOperationResult(restoredContext: nil, diagnostic: nil)
        }
        return await startSession(currentSession, restoreLimit: restoreLimit)
    }

    func deleteCurrentSession() async -> String? {
        guard let currentSession else { return nil }
        do {
            try await ephemeralStore.deleteSession(currentSession.id)
            if let store = try await durableStateStoreIfPresentOrEnabled() {
                try await store.deleteSession(currentSession.id)
                if storesSessionMetadata {
                    try await store.startSession(currentSession)
                }
            }
            if storesSessionMetadata {
                try await ephemeralStore.startSession(currentSession)
            }
            return nil
        } catch {
            return "Current session history could not be cleared completely."
        }
    }

    func deleteCurrentWorkspace() async -> String? {
        guard let currentSession, let workspaceID = currentSession.workspaceID else {
            return "Workspace history is unavailable because file-path collection is disabled."
        }
        do {
            try await ephemeralStore.deleteWorkspace(workspaceID)
            if let store = try await durableStateStoreIfPresentOrEnabled() {
                try await store.deleteWorkspace(workspaceID)
                if storesSessionMetadata {
                    try await store.startSession(currentSession)
                }
            }
            if storesSessionMetadata {
                try await ephemeralStore.startSession(currentSession)
            }
            return nil
        } catch {
            return "Current workspace history could not be cleared completely."
        }
    }

    func closeCurrentSessionCleanly(at date: Date = Date()) async -> String? {
        guard let currentSession else { return nil }
        do {
            try await ephemeralStore.updateSessionLifecycle(currentSession.id, lifecycle: .closedCleanly, lastActiveAt: date)
            if let store = try await durableStateStoreIfPresentOrEnabled() {
                try await store.updateSessionLifecycle(currentSession.id, lifecycle: .closedCleanly, lastActiveAt: date)
            }
            self.currentSession = RuntimeSession(
                id: currentSession.id,
                workspaceID: currentSession.workspaceID,
                repositoryID: currentSession.repositoryID,
                shell: currentSession.shell,
                initialWorkingDirectory: currentSession.initialWorkingDirectory,
                lastWorkingDirectory: currentSession.lastWorkingDirectory,
                startedAt: currentSession.startedAt,
                lastActiveAt: date,
                lifecycle: .closedCleanly,
                paneVersion: currentSession.paneVersion,
                schemaVersion: currentSession.schemaVersion
            )
            return nil
        } catch {
            return "Session shutdown state could not be saved."
        }
    }

    func recoverInterruptedSessions(excludingCurrentSession: Bool = true) async -> [RuntimeSession] {
        _ = excludingCurrentSession // Recovery is launch-scoped for shared multi-tab storage.
        guard configuration.persistenceEnabled else { return [] }
        return ((try? await persistenceCoordinator.prepareCurrentLaunch()) ?? [])
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    func deleteAllState() async -> String? {
        do {
            try await ephemeralStore.deleteAllState()
            if let store = try await durableStateStoreIfPresentOrEnabled() {
                try await store.deleteAllState()
                if storesSessionMetadata, let currentSession {
                    try await store.startSession(currentSession)
                }
            }
            if storesSessionMetadata, let currentSession {
                try await ephemeralStore.startSession(currentSession)
            }
            return nil
        } catch {
            return "Session history could not be cleared completely."
        }
    }

    func deletePreviousSessions() async -> String? {
        guard let currentSession else { return nil }
        do {
            try await ephemeralStore.deleteSessions(excluding: currentSession.id)
            if let store = try await durableStateStoreIfPresentOrEnabled() {
                try await store.deleteSessions(excluding: currentSession.id)
            }
            return nil
        } catch {
            return "Previous sessions could not be cleared completely."
        }
    }

    func deleteExactCommandHistory() async -> String? {
        do {
            try await ephemeralStore.deleteAllCommandEvents()
            if let store = try await durableStateStoreIfPresentOrEnabled() { try await store.deleteAllCommandEvents() }
            return nil
        } catch {
            return "Exact command history could not be cleared completely."
        }
    }

    func clearPersistedBlockOutput() async -> String? {
        do {
            try await ephemeralStore.clearPersistedOutput()
            if let store = try await durableStateStoreIfPresentOrEnabled() { try await store.clearPersistedOutput() }
            return nil
        } catch {
            return "Persisted block output could not be cleared completely."
        }
    }

    func localDataDirectory() -> URL {
        databaseURL.deletingLastPathComponent()
    }

    func recoveryFile() async -> URL? {
        await persistenceCoordinator.recoveryFile()
    }

    func clearRecoveryFile() async -> String? {
        do {
            try await persistenceCoordinator.clearRecoveryFile()
            return nil
        } catch {
            return "The local recovery file could not be cleared."
        }
    }

    func persistenceDiagnosticSnapshot() async -> PersistenceDiagnostic {
        await persistenceCoordinator.diagnostic()
    }

    private func durableStateStore() async throws -> SQLiteRuntimeStateStore {
        try await persistenceCoordinator.store()
    }

    private func durableStateStoreIfPresentOrEnabled() async throws -> SQLiteRuntimeStateStore? {
        guard configuration.persistenceEnabled || FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }
        return try await durableStateStore()
    }

    private func storageSafeSession(_ session: RuntimeSession) -> RuntimeSession {
        guard configuration.filePathCollectionEnabled else {
            return RuntimeSession(
                id: session.id,
                workspaceID: nil,
                repositoryID: session.repositoryID,
                shell: session.shell,
                initialWorkingDirectory: "",
                lastWorkingDirectory: "",
                startedAt: session.startedAt,
                lastActiveAt: session.lastActiveAt,
                lifecycle: session.lifecycle,
                paneVersion: session.paneVersion,
                schemaVersion: session.schemaVersion
            )
        }
        return session
    }

    private func storageSafeEvent(_ event: PersistedCommandEvent) -> PersistedCommandEvent {
        PersistedCommandEvent(
            blockID: event.blockID,
            sessionID: event.sessionID,
            timestamp: event.timestamp,
            workingDirectory: configuration.filePathCollectionEnabled ? event.workingDirectory : "",
            command: event.command,
            exitCode: event.exitCode,
            durationMilliseconds: event.durationMilliseconds,
            sanitizedOutputSummary: configuration.outputSummariesEnabled
                ? event.sanitizedOutputSummary
                : nil,
            sanitizedErrorSummary: configuration.outputSummariesEnabled
                ? event.sanitizedErrorSummary
                : nil,
            predictionSource: event.predictionSource,
            predictionAction: event.predictionAction,
            completion: event.completion,
            isCollapsed: event.isCollapsed,
            outputKind: configuration.outputSummariesEnabled ? event.outputKind : .none
        )
    }

    nonisolated private static func workspaceIdentifier(for directory: String) -> String {
        URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
    }
}

extension RuntimeStateController: BehavioralCompletionStore {
    func recordCommand(_ record: BehavioralCommandRecord) async throws {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return }
        try await durableStateStore().recordCommand(record)
    }

    func recordTransition(
        previousCommandKey: String,
        next: BehavioralCommandRecord
    ) async throws {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return }
        try await durableStateStore().recordTransition(
            previousCommandKey: previousCommandKey,
            next: next
        )
    }

    func commandAggregates(
        matchingPrefix prefix: String,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandAggregate] {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return [] }
        return try await durableStateStore().commandAggregates(
            matchingPrefix: prefix,
            projectID: projectID,
            directoryIdentity: directoryIdentity,
            limit: limit
        )
    }

    func mostRecentCommands(
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandAggregate] {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return [] }
        return try await durableStateStore().mostRecentCommands(
            projectID: projectID,
            directoryIdentity: directoryIdentity,
            limit: limit
        )
    }

    func commandTransitions(
        after previousCommandKey: String,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandTransitionAggregate] {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return [] }
        return try await durableStateStore().commandTransitions(
            after: previousCommandKey,
            projectID: projectID,
            directoryIdentity: directoryIdentity,
            limit: limit
        )
    }

    func recordFeedback(_ record: CompletionFeedbackRecord) async throws {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return }
        try await durableStateStore().recordFeedback(record)
    }

    func feedbackAggregates(
        candidateIdentities: [String],
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CompletionFeedbackAggregate] {
        guard configuration.persistenceEnabled, configuration.predictionContextEnabled else { return [] }
        return try await durableStateStore().feedbackAggregates(
            candidateIdentities: candidateIdentities,
            projectID: projectID,
            directoryIdentity: directoryIdentity,
            limit: limit
        )
    }
}
