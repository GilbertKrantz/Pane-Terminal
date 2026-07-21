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
        commandEvents.append(event)
        if commandEvents.count > maximumCommandEvents {
            commandEvents.removeFirst(commandEvents.count - maximumCommandEvents)
        }
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

    func applyRetentionPolicy() async throws {
        if commandEvents.count > maximumCommandEvents {
            commandEvents.removeFirst(commandEvents.count - maximumCommandEvents)
        }
    }
}
