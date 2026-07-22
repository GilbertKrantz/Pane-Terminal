import Foundation

/// Ephemeral runtime-state cache used when durable prediction history is
/// disabled or when the persistent store fails closed. It stores only already
/// sanitized command events supplied by callers and never writes to disk.
actor InMemoryRuntimeStateStore: RuntimeStateStore {
    private var sessions: [UUID: RuntimeSession] = [:]
    private var commandEvents: [PersistedCommandEvent] = []
    private var features: [RuntimeFeature] = []
    private let maximumCommandEvents: Int

    init(maximumCommandEvents: Int = 1_000) {
        self.maximumCommandEvents = max(0, maximumCommandEvents)
    }

    func startSession(_ session: RuntimeSession) async throws {
        sessions[session.id] = session
    }

    func persistCommandEvent(_ event: PersistedCommandEvent) async throws {
        if let index = commandEvents.firstIndex(where: { $0.blockID == event.blockID }) {
            commandEvents[index] = event
        } else {
            commandEvents.append(event)
        }
        if commandEvents.count > maximumCommandEvents {
            commandEvents.removeFirst(commandEvents.count - maximumCommandEvents)
        }
    }

    func updateCommandEventCollapsed(_ blockID: UUID, isCollapsed: Bool) async throws {
        guard let index = commandEvents.firstIndex(where: { $0.blockID == blockID }) else { return }
        let event = commandEvents[index]
        commandEvents[index] = PersistedCommandEvent(
            blockID: event.blockID,
            sessionID: event.sessionID,
            timestamp: event.timestamp,
            workingDirectory: event.workingDirectory,
            command: event.command,
            exitCode: event.exitCode,
            durationMilliseconds: event.durationMilliseconds,
            sanitizedOutputSummary: event.sanitizedOutputSummary,
            sanitizedErrorSummary: event.sanitizedErrorSummary,
            predictionSource: event.predictionSource,
            predictionAction: event.predictionAction,
            completion: event.completion,
            isCollapsed: isCollapsed
        )
    }

    func persistFeatures(_ features: [RuntimeFeature]) async throws {
        self.features.append(contentsOf: features)
    }

    func loadRecentContext(
        workspaceID: String?,
        repositoryID: String?,
        limit: Int
    ) async throws -> PersistedRuntimeContext {
        let matchingSessions = sessions.values.filter { session in
            let workspaceMatches = workspaceID == nil || session.workspaceID == workspaceID
            let repositoryMatches = repositoryID == nil || session.repositoryID == repositoryID
            return workspaceMatches && repositoryMatches
        }
        let sessionIDs = Set(matchingSessions.map(\.id))
        let boundedLimit = max(0, limit)
        let events = commandEvents
            .filter { sessionIDs.contains($0.sessionID) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(boundedLimit)
        let runtimeFeatures = features
            .filter { sessionIDs.contains($0.sessionID) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(boundedLimit)

        return PersistedRuntimeContext(
            sessions: Array(matchingSessions),
            commandEvents: Array(events),
            features: Array(runtimeFeatures)
        )
    }

    func deleteSession(_ sessionID: UUID) async throws {
        sessions.removeValue(forKey: sessionID)
        commandEvents.removeAll { $0.sessionID == sessionID }
        features.removeAll { $0.sessionID == sessionID }
    }

    func deleteWorkspace(_ workspaceID: String) async throws {
        let sessionIDs = Set(sessions.values
            .filter { $0.workspaceID == workspaceID }
            .map(\.id))
        sessions = sessions.filter { !sessionIDs.contains($0.key) }
        commandEvents.removeAll { sessionIDs.contains($0.sessionID) }
        features.removeAll { sessionIDs.contains($0.sessionID) }
    }

    func deleteAllState() async throws {
        sessions.removeAll()
        commandEvents.removeAll()
        features.removeAll()
    }

    func deleteSessions(excluding sessionID: UUID) async throws {
        let deleted = Set(sessions.keys.filter { $0 != sessionID })
        sessions = sessions.filter { $0.key == sessionID }
        commandEvents.removeAll { deleted.contains($0.sessionID) }
        features.removeAll { deleted.contains($0.sessionID) }
    }

    func deleteAllCommandEvents() async throws {
        commandEvents.removeAll()
    }

    func clearPersistedOutput() async throws {
        commandEvents = commandEvents.map { event in
            PersistedCommandEvent(
                blockID: event.blockID, sessionID: event.sessionID, timestamp: event.timestamp,
                workingDirectory: event.workingDirectory, command: event.command,
                exitCode: event.exitCode, durationMilliseconds: event.durationMilliseconds,
                sanitizedOutputSummary: nil, sanitizedErrorSummary: nil,
                predictionSource: event.predictionSource, predictionAction: event.predictionAction,
                completion: event.completion, isCollapsed: event.isCollapsed
            )
        }
    }

    func updateSessionLifecycle(_ sessionID: UUID, lifecycle: PersistedSessionLifecycle, lastActiveAt: Date) async throws {
        guard let session = sessions[sessionID] else { return }
        sessions[sessionID] = RuntimeSession(
            id: session.id,
            workspaceID: session.workspaceID,
            repositoryID: session.repositoryID,
            shell: session.shell,
            initialWorkingDirectory: session.initialWorkingDirectory,
            startedAt: session.startedAt,
            lastActiveAt: lastActiveAt,
            lifecycle: lifecycle,
            paneVersion: session.paneVersion,
            schemaVersion: session.schemaVersion
        )
    }

    func markActiveSessionsInterrupted(excluding sessionID: UUID?) async throws -> [RuntimeSession] {
        var interrupted: [RuntimeSession] = []
        for session in sessions.values where session.lifecycle == .active && session.id != sessionID {
            let updated = RuntimeSession(
                id: session.id,
                workspaceID: session.workspaceID,
                repositoryID: session.repositoryID,
                shell: session.shell,
                initialWorkingDirectory: session.initialWorkingDirectory,
                startedAt: session.startedAt,
                lastActiveAt: session.lastActiveAt,
                lifecycle: .interrupted,
                paneVersion: session.paneVersion,
                schemaVersion: session.schemaVersion
            )
            sessions[session.id] = updated
            interrupted.append(updated)
        }
        return interrupted.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    func applyRetentionPolicy() async throws {
        if commandEvents.count > maximumCommandEvents {
            commandEvents.removeFirst(commandEvents.count - maximumCommandEvents)
        }
    }
}
