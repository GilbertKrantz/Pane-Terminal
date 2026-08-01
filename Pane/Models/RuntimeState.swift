import Foundation

struct RuntimeSnapshot: Codable, Sendable, Equatable {
    let sessionID: UUID
    let workspaceID: String?
    let timestamp: Date
    let workingDirectory: String
    let shell: String
    let recentCommands: [CommandRecord]
    let lastExitCode: Int?
    let lastCommandDurationMilliseconds: Int?
    let gitState: GitState?
    let projectState: ProjectState?
    let sanitizedOutputSummary: String?
    let sanitizedErrorSummary: String?
    let typedPrefix: String?
}

struct CommandRecord: Codable, Sendable, Equatable {
    let timestamp: Date
    let command: String
    let workingDirectory: String
    let exitCode: Int?
    let durationMilliseconds: Int?
}

struct GitState: Codable, Sendable, Equatable {
    let repositoryID: String
    let branch: String?
    let modifiedFilePaths: [String]
    let stagedFilePaths: [String]
}

struct ProjectState: Codable, Sendable, Equatable {
    let detectedLanguages: [String]
    let detectedTools: [String]
    let packageManagers: [String]
    let projectType: String?
}

struct PaneSessionID: Hashable, Codable, Sendable, Equatable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum PersistedSessionLifecycle: String, Codable, Sendable, Equatable {
    case active
    case closedCleanly
    case interrupted
}

struct RuntimeSession: Codable, Sendable, Equatable {
    let id: UUID
    let workspaceID: String?
    let repositoryID: String?
    let shell: String
    let initialWorkingDirectory: String
    let lastWorkingDirectory: String
    let startedAt: Date
    let lastActiveAt: Date
    let lifecycle: PersistedSessionLifecycle
    let paneVersion: String
    let schemaVersion: Int

    init(
        id: UUID,
        workspaceID: String?,
        repositoryID: String?,
        shell: String,
        initialWorkingDirectory: String,
        lastWorkingDirectory: String? = nil,
        startedAt: Date,
        lastActiveAt: Date,
        lifecycle: PersistedSessionLifecycle = .active,
        paneVersion: String = "0.2",
        schemaVersion: Int = 5
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.repositoryID = repositoryID
        self.shell = shell
        self.initialWorkingDirectory = initialWorkingDirectory
        self.lastWorkingDirectory = lastWorkingDirectory ?? initialWorkingDirectory
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.lifecycle = lifecycle
        self.paneVersion = paneVersion
        self.schemaVersion = schemaVersion
    }
}

struct PersistedCommandEvent: Codable, Sendable, Equatable {
    enum Completion: String, Codable, Sendable, Equatable {
        case completed
        case interrupted
        case unknown
    }

    let blockID: UUID
    let sessionID: UUID
    let timestamp: Date
    let workingDirectory: String
    let command: String
    let exitCode: Int?
    let durationMilliseconds: Int?
    let sanitizedOutputSummary: String?
    let sanitizedErrorSummary: String?
    let predictionSource: String?
    let predictionAction: String?
    let completion: Completion
    let isCollapsed: Bool
    let outputKind: PersistedOutputKind

    init(
        blockID: UUID = UUID(),
        sessionID: UUID,
        timestamp: Date,
        workingDirectory: String,
        command: String,
        exitCode: Int?,
        durationMilliseconds: Int?,
        sanitizedOutputSummary: String?,
        sanitizedErrorSummary: String?,
        predictionSource: String?,
        predictionAction: String?,
        completion: Completion = .completed,
        isCollapsed: Bool = false,
        outputKind: PersistedOutputKind = .none
    ) {
        self.blockID = blockID
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.command = command
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds
        self.sanitizedOutputSummary = sanitizedOutputSummary
        self.sanitizedErrorSummary = sanitizedErrorSummary
        self.predictionSource = predictionSource
        self.predictionAction = predictionAction
        self.completion = completion
        self.isCollapsed = isCollapsed
        self.outputKind = outputKind
    }

    /// Returns the durable representation that is safest to keep when two
    /// writers report the same block. Lifecycle finality wins before
    /// timestamp or payload completeness so a delayed "pending" write cannot
    /// turn an interrupted or completed command back into an active one.
    func monotonicallyMerged(with incoming: PersistedCommandEvent) -> PersistedCommandEvent {
        precondition(blockID == incoming.blockID)
        let existingRank = completion.persistenceRank
        let incomingRank = incoming.completion.persistenceRank
        if existingRank != incomingRank {
            return existingRank > incomingRank ? self : incoming
        }
        if timestamp != incoming.timestamp {
            return timestamp > incoming.timestamp ? self : incoming
        }
        let existingCompleteness = persistenceCompleteness
        let incomingCompleteness = incoming.persistenceCompleteness
        return existingCompleteness > incomingCompleteness ? self : incoming
    }

    private var persistenceCompleteness: Int {
        var score = 0
        if exitCode != nil { score += 1 }
        if durationMilliseconds != nil { score += 1 }
        if !(sanitizedOutputSummary?.isEmpty ?? true) { score += 1 }
        if !(sanitizedErrorSummary?.isEmpty ?? true) { score += 1 }
        if predictionSource != nil { score += 1 }
        if predictionAction != nil { score += 1 }
        if outputKind != .none { score += 1 }
        return score
    }
}

private extension PersistedCommandEvent.Completion {
    var persistenceRank: Int {
        switch self {
        case .interrupted: 3
        case .completed: 2
        case .unknown: 1
        }
    }
}

struct RuntimeFeature: Codable, Sendable, Equatable {
    let sessionID: UUID
    let timestamp: Date
    let key: String
    let value: String
}

struct PersistedSessionContext: Codable, Sendable, Equatable {
    let session: RuntimeSession
    let commandEvents: [PersistedCommandEvent]
}

struct PersistedRuntimeContext: Codable, Sendable, Equatable {
    let sessions: [RuntimeSession]
    let commandEvents: [PersistedCommandEvent]
    let features: [RuntimeFeature]

    var sessionContexts: [PersistedSessionContext] {
        sessions
            .sorted { $0.startedAt < $1.startedAt }
            .map { session in
                let events = commandEvents
                    .filter { $0.sessionID == session.id }
                    .sorted { $0.timestamp < $1.timestamp }
                return PersistedSessionContext(session: session, commandEvents: events)
            }
    }
}

struct RuntimeStateRestoreLimits: Sendable, Equatable {
    var maximumSessions: Int
    var maximumCommands: Int
    var maximumOutputBytes: Int

    static func commands(_ limit: Int) -> RuntimeStateRestoreLimits {
        RuntimeStateRestoreLimits(
            maximumSessions: .max,
            maximumCommands: max(0, limit),
            maximumOutputBytes: .max
        )
    }
}

protocol RuntimeStateStore: Sendable {
    func startSession(_ session: RuntimeSession) async throws
    func persistCommandEvent(_ event: PersistedCommandEvent) async throws
    func updateCommandEventCollapsed(_ blockID: UUID, isCollapsed: Bool) async throws
    func persistFeatures(_ features: [RuntimeFeature]) async throws
    func loadRecentContext(workspaceID: String?, repositoryID: String?, limits: RuntimeStateRestoreLimits) async throws -> PersistedRuntimeContext
    func deleteSession(_ sessionID: UUID) async throws
    func deleteWorkspace(_ workspaceID: String) async throws
    func deleteAllState() async throws
    func deleteSessions(excluding sessionID: UUID) async throws
    func deleteAllCommandEvents() async throws
    func clearPersistedOutput() async throws
    func updateSessionLifecycle(_ sessionID: UUID, lifecycle: PersistedSessionLifecycle, lastActiveAt: Date) async throws
    func markActiveSessionsInterrupted(excluding sessionID: UUID?) async throws -> [RuntimeSession]
    func applyRetentionPolicy() async throws
}


extension RuntimeStateStore {
    func loadRecentContext(
        workspaceID: String?,
        repositoryID: String?,
        limit: Int
    ) async throws -> PersistedRuntimeContext {
        try await loadRecentContext(
            workspaceID: workspaceID,
            repositoryID: repositoryID,
            limits: .commands(limit)
        )
    }
}
