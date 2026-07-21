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

struct RuntimeSession: Codable, Sendable, Equatable {
    let id: UUID
    let workspaceID: String?
    let repositoryID: String?
    let shell: String
    let initialWorkingDirectory: String
    let startedAt: Date
    let lastActiveAt: Date
}

struct PersistedCommandEvent: Codable, Sendable, Equatable {
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
}

struct RuntimeFeature: Codable, Sendable, Equatable {
    let sessionID: UUID
    let timestamp: Date
    let key: String
    let value: String
}

struct PersistedRuntimeContext: Codable, Sendable, Equatable {
    let sessions: [RuntimeSession]
    let commandEvents: [PersistedCommandEvent]
    let features: [RuntimeFeature]
}

protocol RuntimeStateStore: Sendable {
    func startSession(_ session: RuntimeSession) async throws
    func persistCommandEvent(_ event: PersistedCommandEvent) async throws
    func persistFeatures(_ features: [RuntimeFeature]) async throws
    func loadRecentContext(workspaceID: String?, repositoryID: String?, limit: Int) async throws -> PersistedRuntimeContext
    func deleteSession(_ sessionID: UUID) async throws
    func deleteWorkspace(_ workspaceID: String) async throws
    func deleteAllState() async throws
    func applyRetentionPolicy() async throws
}
