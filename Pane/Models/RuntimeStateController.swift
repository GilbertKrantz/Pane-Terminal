import Foundation

struct RuntimeStateConfiguration: Sendable, Equatable {
    var persistenceEnabled: Bool
    var commandHistoryEnabled: Bool
    var visibleSessionRecoveryEnabled: Bool
    var predictionContextEnabled: Bool
    var outputSummariesEnabled: Bool
    var filePathCollectionEnabled: Bool
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
    private let ephemeralStore: InMemoryRuntimeStateStore
    private var durableStore: SQLiteRuntimeStateStore?
    private var configuration: RuntimeStateConfiguration
    private var currentSession: RuntimeSession?
    private var recoveryDiagnostic: String?
    private var recoveryFileURL: URL?

    init(
        databaseURL: URL,
        configuration: RuntimeStateConfiguration,
        ephemeralStore: InMemoryRuntimeStateStore = InMemoryRuntimeStateStore()
    ) {
        self.databaseURL = databaseURL
        self.configuration = configuration
        self.ephemeralStore = ephemeralStore
    }

    func startSession(_ session: RuntimeSession, restoreLimit: Int = 200) async -> RuntimeStateOperationResult {
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
            return RuntimeStateOperationResult(
                restoredContext: try? await ephemeralStore.loadRecentContext(
                    workspaceID: currentSession.workspaceID,
                    repositoryID: currentSession.repositoryID,
                    limits: restorationLimits(commandLimit: restoreLimit)
                ),
                diagnostic: nil,
                restoresCommandHistory: configuration.commandHistoryEnabled,
                restoresVisibleBlocks: false
            )
        }

        do {
            let store = try durableStateStore()
            _ = try await store.markActiveSessionsInterrupted(excluding: currentSession.id)
            let context = try await store.loadRecentContext(
                workspaceID: nil,
                repositoryID: nil,
                limits: restorationLimits(commandLimit: restoreLimit)
            )
            try await store.startSession(currentSession)
            try await store.applyRetentionPolicy()
            return RuntimeStateOperationResult(
                restoredContext: context,
                diagnostic: recoveryDiagnostic,
                restoresCommandHistory: configuration.commandHistoryEnabled,
                restoresVisibleBlocks: configuration.visibleSessionRecoveryEnabled
            )
        } catch {
            let fallback = try? await ephemeralStore.loadRecentContext(
                workspaceID: currentSession.workspaceID,
                repositoryID: currentSession.repositoryID,
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

    func persistCommandEvent(_ event: PersistedCommandEvent) async -> String? {
        guard configuration.commandHistoryEnabled || configuration.visibleSessionRecoveryEnabled else { return nil }
        let event = storageSafeEvent(event)

        do {
            try await ephemeralStore.persistCommandEvent(event)
        } catch {
            return "Session history could not be cached in memory."
        }

        guard configuration.persistenceEnabled else { return nil }
        do {
            let store = try durableStateStore()
            if let currentSession {
                try await store.startSession(currentSession)
            }
            try await store.persistCommandEvent(event)
            return nil
        } catch {
            return "Session history could not be saved; Pane is continuing with memory-only history."
        }
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
            if let store = try durableStateStoreIfPresentOrEnabled() {
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
            if let store = try durableStateStoreIfPresentOrEnabled() {
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
            if let store = try durableStateStoreIfPresentOrEnabled() {
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
        let excluded = excludingCurrentSession ? currentSession?.id : nil
        var recovered = (try? await ephemeralStore.markActiveSessionsInterrupted(excluding: excluded)) ?? []
        if let store = try? durableStateStoreIfPresentOrEnabled(),
           let durable = try? await store.markActiveSessionsInterrupted(excluding: excluded) {
            recovered.append(contentsOf: durable)
        }
        return recovered.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    func deleteAllState() async -> String? {
        do {
            try await ephemeralStore.deleteAllState()
            if let store = try durableStateStoreIfPresentOrEnabled() {
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
            if let store = try durableStateStoreIfPresentOrEnabled() {
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
            if let store = try durableStateStoreIfPresentOrEnabled() { try await store.deleteAllCommandEvents() }
            return nil
        } catch {
            return "Exact command history could not be cleared completely."
        }
    }

    func clearPersistedBlockOutput() async -> String? {
        do {
            try await ephemeralStore.clearPersistedOutput()
            if let store = try durableStateStoreIfPresentOrEnabled() { try await store.clearPersistedOutput() }
            return nil
        } catch {
            return "Persisted block output could not be cleared completely."
        }
    }

    func localDataDirectory() -> URL {
        databaseURL.deletingLastPathComponent()
    }

    func recoveryFile() -> URL? { recoveryFileURL }

    func clearRecoveryFile() -> String? {
        guard let recoveryFileURL else { return nil }
        do {
            try FileManager.default.removeItem(at: recoveryFileURL)
            self.recoveryFileURL = nil
            recoveryDiagnostic = nil
            return nil
        } catch {
            return "The local recovery file could not be cleared."
        }
    }

    private func durableStateStore() throws -> SQLiteRuntimeStateStore {
        if let durableStore { return durableStore }
        do {
            let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
            durableStore = store
            return store
        } catch {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw error }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let recoveryURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("runtime-state-recovery-\(formatter.string(from: Date()))-\(UUID().uuidString).sqlite")
            try FileManager.default.moveItem(at: databaseURL, to: recoveryURL)
            let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
            durableStore = store
            recoveryDiagnostic = "Pane recovered from an unreadable local database. The recovery file remains local at \(recoveryURL.lastPathComponent)."
            recoveryFileURL = recoveryURL
            return store
        }
    }

    private func durableStateStoreIfPresentOrEnabled() throws -> SQLiteRuntimeStateStore? {
        if let durableStore { return durableStore }
        guard configuration.persistenceEnabled || FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }
        return try durableStateStore()
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
