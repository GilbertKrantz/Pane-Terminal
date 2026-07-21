import Foundation

struct RuntimeStateConfiguration: Sendable, Equatable {
    var persistenceEnabled: Bool
    var predictionHistoryEnabled: Bool
    var outputSummariesEnabled: Bool
    var filePathCollectionEnabled: Bool
}

struct RuntimeStateOperationResult: Sendable {
    let restoredContext: PersistedRuntimeContext?
    let diagnostic: String?
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
        guard configuration.predictionHistoryEnabled, let currentSession else {
            return RuntimeStateOperationResult(restoredContext: nil, diagnostic: nil)
        }

        do {
            try await ephemeralStore.startSession(currentSession)
        } catch {
            return RuntimeStateOperationResult(
                restoredContext: nil,
                diagnostic: "Ephemeral prediction history is unavailable."
            )
        }

        guard configuration.persistenceEnabled else {
            return RuntimeStateOperationResult(
                restoredContext: try? await ephemeralStore.loadRecentContext(
                    workspaceID: currentSession.workspaceID,
                    repositoryID: currentSession.repositoryID,
                    limit: restoreLimit
                ),
                diagnostic: nil
            )
        }

        do {
            let store = try durableStateStore()
            try await store.startSession(currentSession)
            try await store.applyRetentionPolicy()
            let context = try await store.loadRecentContext(
                workspaceID: currentSession.workspaceID,
                repositoryID: currentSession.repositoryID,
                limit: restoreLimit
            )
            return RuntimeStateOperationResult(restoredContext: context, diagnostic: nil)
        } catch {
            let fallback = try? await ephemeralStore.loadRecentContext(
                workspaceID: currentSession.workspaceID,
                repositoryID: currentSession.repositoryID,
                limit: restoreLimit
            )
            return RuntimeStateOperationResult(
                restoredContext: fallback,
                diagnostic: "Prediction history could not be opened; Pane is using memory-only history."
            )
        }
    }

    func persistCommandEvent(_ event: PersistedCommandEvent) async -> String? {
        guard configuration.predictionHistoryEnabled else { return nil }
        let event = storageSafeEvent(event)

        do {
            try await ephemeralStore.persistCommandEvent(event)
        } catch {
            return "Prediction history could not be cached in memory."
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
            return "Prediction history could not be saved; Pane is continuing with memory-only history."
        }
    }

    func updateConfiguration(
        _ newConfiguration: RuntimeStateConfiguration,
        restoreLimit: Int = 200
    ) async -> RuntimeStateOperationResult {
        let shouldRestore = (!configuration.persistenceEnabled && newConfiguration.persistenceEnabled)
            || (!configuration.predictionHistoryEnabled && newConfiguration.predictionHistoryEnabled)
        configuration = newConfiguration

        guard newConfiguration.predictionHistoryEnabled else {
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
                if configuration.predictionHistoryEnabled {
                    try await store.startSession(currentSession)
                }
            }
            if configuration.predictionHistoryEnabled {
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
                if configuration.predictionHistoryEnabled {
                    try await store.startSession(currentSession)
                }
            }
            if configuration.predictionHistoryEnabled {
                try await ephemeralStore.startSession(currentSession)
            }
            return nil
        } catch {
            return "Current workspace history could not be cleared completely."
        }
    }

    func deleteAllState() async -> String? {
        do {
            try await ephemeralStore.deleteAllState()
            if let store = try durableStateStoreIfPresentOrEnabled() {
                try await store.deleteAllState()
                if configuration.predictionHistoryEnabled, let currentSession {
                    try await store.startSession(currentSession)
                }
            }
            if configuration.predictionHistoryEnabled, let currentSession {
                try await ephemeralStore.startSession(currentSession)
            }
            return nil
        } catch {
            return "Prediction history could not be cleared completely."
        }
    }

    private func durableStateStore() throws -> SQLiteRuntimeStateStore {
        if let durableStore { return durableStore }
        let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        durableStore = store
        return store
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
                startedAt: session.startedAt,
                lastActiveAt: session.lastActiveAt
            )
        }
        return session
    }

    private func storageSafeEvent(_ event: PersistedCommandEvent) -> PersistedCommandEvent {
        PersistedCommandEvent(
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
            predictionAction: event.predictionAction
        )
    }
}
