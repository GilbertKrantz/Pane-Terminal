import XCTest
@testable import Pane

final class SessionRecoveryTests: XCTestCase {
    @MainActor
    func testThreeHistoricalSessionsRestoreInOrderWithIndependentLifecycle() throws {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        let sessions = [
            RuntimeSession(
                id: thirdID, workspaceID: nil, repositoryID: nil, shell: "/bin/zsh",
                initialWorkingDirectory: "/tmp", startedAt: base.addingTimeInterval(20),
                lastActiveAt: base.addingTimeInterval(21), lifecycle: .closedCleanly
            ),
            RuntimeSession(
                id: firstID, workspaceID: nil, repositoryID: nil, shell: "/bin/zsh",
                initialWorkingDirectory: "/tmp", startedAt: base,
                lastActiveAt: base.addingTimeInterval(1), lifecycle: .closedCleanly
            ),
            RuntimeSession(
                id: secondID, workspaceID: nil, repositoryID: nil, shell: "/bin/zsh",
                initialWorkingDirectory: "/tmp", startedAt: base.addingTimeInterval(10),
                lastActiveAt: base.addingTimeInterval(11), lifecycle: .interrupted
            )
        ]
        let events = [
            event(sessionID: thirdID, command: "third", timestamp: base.addingTimeInterval(20), completion: .interrupted, exitCode: nil),
            event(sessionID: firstID, command: "first", timestamp: base, completion: .completed, exitCode: 0),
            event(sessionID: secondID, command: "second", timestamp: base.addingTimeInterval(10), completion: .completed, exitCode: nil)
        ]
        let session = TerminalSession()

        session.restoreRuntimeContext(
            PersistedRuntimeContext(sessions: sessions, commandEvents: events, features: []),
            restoreCommandHistory: false,
            restoreVisibleBlocks: true
        )

        XCTAssertEqual(session.restoredSessionOrder, [firstID, secondID, thirdID])
        XCTAssertEqual(session.blocks.map(\.command), ["first", "second", "third"])
        XCTAssertEqual(session.blocks[0].state, .completed(exitCode: 0))
        XCTAssertEqual(session.blocks[1].state, .unknown)
        XCTAssertEqual(session.blocks[2].state, .interrupted(exitCode: nil))
        XCTAssertEqual(session.sessionBoundaries[secondID]?.lifecycle, .interrupted)
        XCTAssertEqual(session.sessionBoundaries[thirdID]?.lifecycle, .closedCleanly)
        XCTAssertEqual(session.newShellBoundary?.workingDirectory, "/tmp")
    }

    @MainActor
    func testDirectoryFallbackUsesLatestUsableCommandDirectory() throws {
        let sessionID = UUID()
        let session = TerminalSession()
        let runtimeSession = RuntimeSession(
            id: sessionID, workspaceID: nil, repositoryID: nil, shell: "/bin/zsh",
            initialWorkingDirectory: "/also-missing-pane-directory",
            lastWorkingDirectory: "/missing-pane-directory",
            startedAt: Date(timeIntervalSince1970: 1),
            lastActiveAt: Date(timeIntervalSince1970: 2), lifecycle: .closedCleanly
        )
        let command = PersistedCommandEvent(
            sessionID: sessionID, timestamp: Date(timeIntervalSince1970: 2),
            workingDirectory: "/tmp", command: "pwd", exitCode: 0,
            durationMilliseconds: nil, sanitizedOutputSummary: nil,
            sanitizedErrorSummary: nil, predictionSource: nil, predictionAction: nil
        )

        session.restoreRuntimeContext(
            PersistedRuntimeContext(sessions: [runtimeSession], commandEvents: [command], features: []),
            restoreCommandHistory: false,
            restoreVisibleBlocks: true
        )

        XCTAssertEqual(session.newShellBoundary?.workingDirectory, "/tmp")
        XCTAssertTrue(session.newShellBoundary?.previousDirectoryUnavailable == true)
    }

    @MainActor
    func testDuplicateBlockIDsRestoreOnlyTheMostCompleteNewestRecord() throws {
        let sessionID = UUID()
        let blockID = UUID()
        let session = TerminalSession()
        let runtimeSession = RuntimeSession(
            id: sessionID, workspaceID: nil, repositoryID: nil, shell: "/bin/zsh",
            initialWorkingDirectory: "/tmp", startedAt: Date(timeIntervalSince1970: 1),
            lastActiveAt: Date(timeIntervalSince1970: 3), lifecycle: .closedCleanly
        )
        let pending = PersistedCommandEvent(
            blockID: blockID, sessionID: sessionID, timestamp: Date(timeIntervalSince1970: 2),
            workingDirectory: "/tmp", command: "swift test", exitCode: nil,
            durationMilliseconds: nil, sanitizedOutputSummary: nil,
            sanitizedErrorSummary: nil, predictionSource: nil, predictionAction: nil,
            completion: .unknown
        )
        let completed = PersistedCommandEvent(
            blockID: blockID, sessionID: sessionID, timestamp: Date(timeIntervalSince1970: 3),
            workingDirectory: "/tmp", command: "swift test", exitCode: 0,
            durationMilliseconds: 1_000, sanitizedOutputSummary: "passed",
            sanitizedErrorSummary: nil, predictionSource: nil, predictionAction: nil,
            completion: .completed, outputKind: .excerpt
        )

        session.restoreRuntimeContext(
            PersistedRuntimeContext(sessions: [runtimeSession], commandEvents: [pending, completed], features: []),
            restoreCommandHistory: false,
            restoreVisibleBlocks: true
        )

        XCTAssertEqual(session.blocks.count, 1)
        XCTAssertEqual(session.blocks.first?.state, .completed(exitCode: 0))
        XCTAssertEqual(session.blocks.first?.output, "passed")
    }

    private func event(
        sessionID: UUID,
        command: String,
        timestamp: Date,
        completion: PersistedCommandEvent.Completion,
        exitCode: Int?
    ) -> PersistedCommandEvent {
        PersistedCommandEvent(
            sessionID: sessionID, timestamp: timestamp, workingDirectory: "/tmp",
            command: command, exitCode: exitCode, durationMilliseconds: 10,
            sanitizedOutputSummary: nil, sanitizedErrorSummary: nil,
            predictionSource: nil, predictionAction: nil, completion: completion
        )
    }
}
