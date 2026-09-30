import AppKit
import Foundation

/// Workspace-independent façade for destructive local-data operations. It is
/// intentionally separate from preference persistence so resetting either
/// category cannot accidentally reset the other.
@MainActor
final class PaneLocalDataManager: ObservableObject {
    weak var workspace: TerminalWorkspaceController?
    let applicationSupportURL: URL

    init(workspace: TerminalWorkspaceController? = nil, applicationSupportURL: URL) {
        self.workspace = workspace
        self.applicationSupportURL = applicationSupportURL
    }

    @Published private(set) var isWorking = false
    @Published private(set) var resultMessage: String?
    @Published private(set) var didFail = false

    enum Operation: String, CaseIterable, Identifiable {
        case currentSession = "Clear Current Session History"
        case previousSessions = "Clear Previous Sessions"
        case exactCommands = "Clear Saved Commands"
        case output = "Clear Saved Output"
        var id: Self { self }
        var detail: String {
            switch self {
            case .currentSession: return "Permanently removes saved history for the selected tab. Visible blocks and running commands stay in place."
            case .previousSessions: return "Permanently removes saved sessions from earlier tabs and launches. Open tabs are preserved."
            case .exactCommands: return "Permanently removes saved commands and completed blocks across all tabs. Running commands stay in place."
            case .output: return "Permanently removes saved output excerpts across all tabs. Command text stays available."
            }
        }
    }

    func perform(_ operation: Operation, tabID: UUID?) async {
        guard !isWorking else { return }
        isWorking = true
        resultMessage = nil
        didFail = false
        defer { isWorking = false }
        do {
            switch operation {
            case .currentSession: try await clearCurrentSessionData(tabID: tabID)
            case .previousSessions: try await clearPreviousSessions()
            case .exactCommands: try await clearExactCommandHistory()
            case .output: try await clearPersistedBlockOutput()
            }
            resultMessage = "\(operation.rawValue): complete."
        } catch {
            didFail = true
            resultMessage = "\(error.localizedDescription) Check that Pane’s data folder is writable, then try again."
        }
    }

    private var sessions: [TerminalSession] { workspace?.tabs.map(\.session) ?? [] }
    private func requireSessions() throws -> [TerminalSession] {
        guard !sessions.isEmpty else { throw PaneLocalDataError.unavailable }
        return sessions
    }

    func clearCurrentSessionData(tabID: UUID?) async throws {
        guard let tabID, let session = workspace?.tabs.first(where: { $0.id == tabID })?.session else {
            throw PaneLocalDataError.unavailable
        }
        try await session.clearCurrentSessionPredictionHistory()
    }
    func clearPreviousSessions() async throws {
        let sessions = try requireSessions()
        let protectedIDs = Set(sessions.map(\.runtimeSessionID))
        for session in sessions { try await session.clearPreviousSessions(preserving: protectedIDs) }
    }
    func clearExactCommandHistory() async throws {
        for session in try requireSessions() { try await session.clearExactCommandHistory() }
    }
    func clearPersistedBlockOutput() async throws {
        for session in try requireSessions() { try await session.clearPersistedBlockOutput() }
    }
    func clearAllPaneData() async throws {
        for session in try requireSessions() { try await session.clearAllPredictionHistory() }
    }
    func revealDataLocation() { NSWorkspace.shared.activateFileViewerSelecting([applicationSupportURL]) }
}

enum PaneLocalDataError: LocalizedError {
    case unavailable
    case storage(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "History storage is unavailable. Open a terminal tab and retry."
        case .storage(let message): return message
        }
    }
}
