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

    func clearCurrentSessionData(tabID: UUID?) async throws {
        guard let tabID, let session = workspace?.tabs.first(where: { $0.id == tabID })?.session else { return }
        session.clearCurrentSessionPredictionHistory()
    }
    func clearPreviousSessions() async throws { workspace?.tabs.first?.session.clearPreviousSessions() }
    func clearExactCommandHistory() async throws { workspace?.tabs.first?.session.clearExactCommandHistory() }
    func clearPersistedBlockOutput() async throws { workspace?.tabs.first?.session.clearPersistedBlockOutput() }
    func clearAllPaneData() async throws { workspace?.tabs.first?.session.clearAllPredictionHistory() }
    func revealDataLocation() { NSWorkspace.shared.activateFileViewerSelecting([applicationSupportURL]) }
}
