import XCTest
@testable import Pane

@MainActor
final class TerminalWorkspaceControllerTests: XCTestCase {
    private func makeWorkspace(snapshotURL: URL? = nil) -> TerminalWorkspaceController {
        let factory = DefaultTerminalSessionFactory(
            runtimeStateControllerProvider: { nil },
            commandHistoryEnabled: false
        )
        return TerminalWorkspaceController(
            factory: factory,
            snapshotURL: snapshotURL ?? temporarySnapshotURL()
        )
    }

    private func temporarySnapshotURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("workspace.json")
    }

    func testWorkspaceCreatesInitialTab() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs.first?.id)
    }

    func testCreatingTabSelectsIt() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let id = await workspace.createTab()
        XCTAssertEqual(workspace.selectedTabID, id)
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testBackgroundTabCreationPreservesSelection() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let original = workspace.selectedTabID
        _ = await workspace.createTab(inBackground: true)
        XCTAssertEqual(workspace.selectedTabID, original)
    }

    func testClosingSelectedTabSelectsNeighbor() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let first = workspace.selectedTabID!
        let second = await workspace.createTab()!
        _ = await workspace.closeTab(id: second, policy: .force)
        XCTAssertEqual(workspace.selectedTabID, first)
    }

    func testClosingBackgroundTabPreservesSelection() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let selected = workspace.selectedTabID!
        let background = await workspace.createTab(inBackground: true)!
        _ = await workspace.closeTab(id: background, policy: .force)
        XCTAssertEqual(workspace.selectedTabID, selected)
    }

    func testClosingFinalTabCreatesReplacement() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let original = workspace.selectedTabID!
        _ = await workspace.closeTab(id: original, policy: .force)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.selectedTabID, original)
    }

    func testReorderingPreservesSelectedIdentity() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let selected = await workspace.createTab()!
        workspace.moveTab(id: selected, to: 0)
        XCTAssertEqual(workspace.selectedTabID, selected)
    }

    func testDuplicateTabUsesSameDirectoryWithNewSession() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let original = workspace.tabs[0]
        let duplicateID = await workspace.duplicateTab(id: original.id)!
        let duplicate = workspace.tabs.first { $0.id == duplicateID }!
        XCTAssertEqual(duplicate.currentDirectory, original.currentDirectory)
        XCTAssertFalse(duplicate.session === original.session)
    }

    func testTabReorderDoesNotRecreateSession() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let tab = workspace.tabs[0]
        _ = await workspace.createTab()
        workspace.moveTab(id: tab.id, to: 1)
        XCTAssertTrue(workspace.tabs[1].session === tab.session)
    }

    func testRapidSelectionLeavesExactlyOneSelectedSession() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        for _ in 0..<3 { _ = await workspace.createTab() }

        for index in 0..<100 {
            workspace.selectTab(id: workspace.tabs[index % workspace.tabs.count].id)
        }

        XCTAssertEqual(
            workspace.tabs.filter { $0.session.visibilityState == .selected }.map(\.id),
            [workspace.selectedTabID].compactMap { $0 }
        )
        XCTAssertTrue(
            workspace.tabs
                .filter { $0.id != workspace.selectedTabID }
                .allSatisfy { $0.session.focusTarget == .none }
        )
    }

    func testBackgroundSessionRejectsDelayedFocusRequest() async {
        let workspace = makeWorkspace()
        await workspace.restoreWorkspace()
        let backgroundID = await workspace.createTab(inBackground: true)!
        let background = workspace.tabs.first { $0.id == backgroundID }!.session

        background.requestFocus(.composer)

        XCTAssertEqual(background.visibilityState, .background)
        XCTAssertEqual(background.focusTarget, .none)
    }

    func testAutomaticTabPresentationPrefersDirectoryAndPreservesFullMetadata() {
        var shell = ShellConfiguration.loginZsh()
        shell.workingDirectory = "/tmp/airflow-dags"
        let session = TerminalSession(shellConfiguration: shell, commandHistoryEnabled: false)
        let tab = TerminalTab(id: UUID(), session: session, title: nil)
        defer { session.shutdown() }

        let presentation = tab.presentation(isSelected: true, index: 0, count: 3)

        XCTAssertEqual(presentation.title, "airflow-dags")
        XCTAssertTrue(presentation.tooltip.contains("/tmp/airflow-dags"))
        XCTAssertTrue(presentation.accessibilityLabel.hasPrefix("Selected tab, airflow-dags"))
        XCTAssertEqual(presentation.truncation, .tail)
    }

    func testHostHeavyAutomaticTitleUsesMiddleTruncation() {
        let session = TerminalSession(commandHistoryEnabled: false)
        let tab = TerminalTab(
            id: UUID(),
            session: session,
            title: "chandraw@DNID359",
            titleSource: .custom
        )
        defer { session.shutdown() }

        let presentation = tab.presentation(isSelected: false, index: 1, count: 3)

        XCTAssertEqual(presentation.truncation, .middle)
        XCTAssertTrue(presentation.accessibilityLabel.contains("chandraw@DNID359"))
    }

    func testTabActivityPresentationUsesQuietIdleAndAccentRunningDots() {
        let idle = TabActivityState.idle.presentation(hasUnreadActivity: false)
        let running = TabActivityState.running.presentation(hasUnreadActivity: false)
        let unread = TabActivityState.idle.presentation(hasUnreadActivity: true)

        XCTAssertEqual(idle.indicator, .dot)
        XCTAssertEqual(idle.colorRole, .muted)
        XCTAssertEqual(idle.indicatorSize, 5)
        XCTAssertFalse(idle.animates)
        XCTAssertEqual(idle.accessibilityLabel, "Idle")

        XCTAssertEqual(running.indicator, .dot)
        XCTAssertEqual(running.colorRole, .accent)
        XCTAssertEqual(running.indicatorSize, 6)
        XCTAssertFalse(running.animates)
        XCTAssertEqual(running.accessibilityLabel, "Running")

        XCTAssertEqual(unread.indicator, .dot)
        XCTAssertEqual(unread.colorRole, .accent)
        XCTAssertEqual(unread.accessibilityLabel, "Unread activity")
    }

    func testTabActivityPresentationKeepsSemanticInputAndFailureSymbols() {
        let waiting = TabActivityState.waitingForInput.presentation(hasUnreadActivity: false)
        let secure = TabActivityState.secureInput.presentation(hasUnreadActivity: false)
        let failed = TabActivityState.failed.presentation(hasUnreadActivity: false)
        let exited = TabActivityState.exited.presentation(hasUnreadActivity: false)

        XCTAssertEqual(waiting.indicator, .symbol("keyboard"))
        XCTAssertEqual(waiting.accessibilityLabel, "Waiting for input")
        XCTAssertEqual(secure.indicator, .symbol("lock.fill"))
        XCTAssertEqual(secure.accessibilityLabel, "Secure input")
        XCTAssertEqual(failed.indicator, .symbol("exclamationmark.circle.fill"))
        XCTAssertEqual(failed.colorRole, .failure)
        XCTAssertEqual(exited.indicator, .symbol("xmark.circle"))
        XCTAssertEqual(exited.colorRole, .failure)
    }

    func testRestorationPreservesOrderSelectionMetadataAndUsesFreshSessions() async throws {
        let snapshotURL = temporarySnapshotURL()
        let original = makeWorkspace(snapshotURL: snapshotURL)
        await original.restoreWorkspace()
        let first = original.tabs[0]
        first.rename("API")
        first.session.commandDraft = "swift test"
        let secondID = await original.createTab(directoryPolicy: .homeDirectory)!
        let second = original.tabs.first { $0.id == secondID }!
        second.rename("Server")
        original.moveTab(id: secondID, to: 0)
        original.selectTab(id: first.id)
        original.persistWorkspace()

        let originalSessions = Dictionary(
            uniqueKeysWithValues: original.tabs.map { ($0.id, $0.session.sessionID) }
        )
        let restored = makeWorkspace(snapshotURL: snapshotURL)
        await restored.restoreWorkspace()

        XCTAssertEqual(restored.tabs.map(\.id), [secondID, first.id])
        XCTAssertEqual(restored.selectedTabID, first.id)
        XCTAssertEqual(restored.tabs.map(\.title), ["Server", "API"])
        XCTAssertEqual(restored.tabs.first { $0.id == first.id }?.session.commandDraft, "swift test")
        XCTAssertTrue(restored.tabs.allSatisfy { originalSessions[$0.id] != $0.session.sessionID })
    }

    func testUnsupportedSnapshotRecoversOneUsableDefaultTab() async throws {
        let snapshotURL = temporarySnapshotURL()
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unsupported = TerminalWorkspaceSnapshot(
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion + 1,
            selectedTabID: UUID(),
            orderedTabs: [],
            savedAt: Date()
        )
        try JSONEncoder().encode(unsupported).write(to: snapshotURL, options: .atomic)

        let workspace = makeWorkspace(snapshotURL: snapshotURL)
        await workspace.restoreWorkspace()

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id)
    }

    func testRestoredTerminalModeWaitsForFreshShellReadiness() async throws {
        let snapshotURL = temporarySnapshotURL()
        let tabID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let selectedAt = createdAt.addingTimeInterval(120)
        let metadata = TerminalTabRestorationMetadata(
            id: tabID,
            order: 0,
            title: "TUI",
            titleSource: .custom,
            workingDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            shellConfigurationID: nil,
            mode: .terminal,
            safeComposerDraft: nil,
            createdAt: createdAt,
            lastSelectedAt: selectedAt,
            hadActiveWork: true
        )
        let snapshot = TerminalWorkspaceSnapshot(
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            selectedTabID: tabID,
            orderedTabs: [metadata],
            savedAt: Date()
        )
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)

        let workspace = makeWorkspace(snapshotURL: snapshotURL)
        await workspace.restoreWorkspace()
        for _ in 0..<200 where workspace.tabs[0].session.mode != .terminal {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(workspace.tabs[0].session.mode, .terminal)
        XCTAssertEqual(workspace.tabs[0].createdAt, createdAt)
        XCTAssertTrue(workspace.tabs[0].showsInterruptedSessionNotice)
    }

    func testNearestExistingDirectoryFallsBackToExistingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resolved = TerminalWorkspaceController.nearestExistingDirectory(
            root.appendingPathComponent("missing/child").path
        )

        XCTAssertEqual(resolved, root.standardizedFileURL)
    }
}
