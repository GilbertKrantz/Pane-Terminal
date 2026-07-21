import XCTest
@testable import Pane

final class RuntimeStateStoreTests: XCTestCase {
    @MainActor
    func testRuntimeSettingsPersistOnlyPreferenceFlags() throws {
        let suiteName = "Pane.RuntimeStateSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = RuntimeStateSettings(defaults: defaults)
        XCTAssertFalse(settings.outputSummariesEnabled)

        settings.persistenceEnabled = false
        settings.predictionHistoryEnabled = false
        settings.outputSummariesEnabled = false
        settings.filePathCollectionEnabled = false

        let restored = RuntimeStateSettings(defaults: defaults)
        XCTAssertEqual(
            restored.configuration,
            RuntimeStateConfiguration(
                persistenceEnabled: false,
                predictionHistoryEnabled: false,
                outputSummariesEnabled: false,
                filePathCollectionEnabled: false
            )
        )
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("secret")
        })
    }

    @MainActor
    func testDisablingPredictionHistoryClearsLiveAutocompleteHistory() {
        let session = TerminalSession()
        session.submit(command: "swift test")
        XCTAssertEqual(session.history.commands, ["swift test"])

        session.applyRuntimeStateConfiguration(RuntimeStateConfiguration(
            persistenceEnabled: true,
            predictionHistoryEnabled: false,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        ))

        XCTAssertTrue(session.history.commands.isEmpty)
    }

    func testControllerRestoresDurableWorkspaceHistoryAcrossRecreation() async throws {
        let directory = temporaryDirectory(named: "ControllerRestore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let configuration = RuntimeStateConfiguration(
            persistenceEnabled: true,
            predictionHistoryEnabled: true,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        )
        let firstSession = RuntimeSession(
            id: UUID(), workspaceID: "/tmp/project", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/project",
            startedAt: Date(), lastActiveAt: Date()
        )
        let firstController = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: configuration
        )
        _ = await firstController.startSession(firstSession)
        let diagnostic = await firstController.persistCommandEvent(PersistedCommandEvent(
            sessionID: firstSession.id,
            timestamp: Date(),
            workingDirectory: "/tmp/project",
            command: "swift test",
            exitCode: 0,
            durationMilliseconds: 42,
            sanitizedOutputSummary: "all tests passed",
            sanitizedErrorSummary: nil,
            predictionSource: nil,
            predictionAction: nil
        ))
        XCTAssertNil(diagnostic)

        let secondController = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: configuration
        )
        let secondSession = RuntimeSession(
            id: UUID(), workspaceID: "/tmp/project", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/project",
            startedAt: Date(), lastActiveAt: Date()
        )
        let restored = await secondController.startSession(secondSession)

        XCTAssertNil(restored.diagnostic)
        XCTAssertEqual(restored.restoredContext?.commandEvents.map(\.command), ["swift test"])
    }

    func testControllerDisabledPersistenceUsesMemoryWithoutCreatingDatabase() async throws {
        let directory = temporaryDirectory(named: "ControllerEphemeral")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let controller = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: RuntimeStateConfiguration(
                persistenceEnabled: false,
                predictionHistoryEnabled: true,
                outputSummariesEnabled: true,
                filePathCollectionEnabled: true
            )
        )
        let session = RuntimeSession(
            id: UUID(), workspaceID: "/tmp", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: Date(), lastActiveAt: Date()
        )
        _ = await controller.startSession(session)
        _ = await controller.persistCommandEvent(PersistedCommandEvent(
            sessionID: session.id,
            timestamp: Date(),
            workingDirectory: "/tmp",
            command: "pwd",
            exitCode: 0,
            durationMilliseconds: 1,
            sanitizedOutputSummary: "/tmp",
            sanitizedErrorSummary: nil,
            predictionSource: nil,
            predictionAction: nil
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testControllerHonorsSummaryAndFilePathCollectionControls() async throws {
        let directory = temporaryDirectory(named: "ControllerCategories")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let controller = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: RuntimeStateConfiguration(
                persistenceEnabled: true,
                predictionHistoryEnabled: true,
                outputSummariesEnabled: false,
                filePathCollectionEnabled: false
            )
        )
        let session = RuntimeSession(
            id: UUID(), workspaceID: "/secret/project", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/secret/project",
            startedAt: Date(), lastActiveAt: Date()
        )
        _ = await controller.startSession(session)
        _ = await controller.persistCommandEvent(PersistedCommandEvent(
            sessionID: session.id,
            timestamp: Date(),
            workingDirectory: "/secret/project",
            command: "swift test",
            exitCode: 1,
            durationMilliseconds: 10,
            sanitizedOutputSummary: "private output",
            sanitizedErrorSummary: "private error",
            predictionSource: nil,
            predictionAction: nil
        ))

        let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        let context = try await store.loadRecentContext(
            workspaceID: nil,
            repositoryID: nil,
            limit: 10
        )
        XCTAssertEqual(context.sessions.first?.initialWorkingDirectory, "")
        XCTAssertEqual(context.commandEvents.first?.workingDirectory, "")
        XCTAssertNil(context.commandEvents.first?.sanitizedOutputSummary)
        XCTAssertNil(context.commandEvents.first?.sanitizedErrorSummary)
    }

    func testSQLiteStoreSurvivesRecreationAndSanitizesAtStorageBoundary() async throws {
        let directory = temporaryDirectory(named: "SQLiteRestore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let session = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: "repo-a",
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/project",
            startedAt: Date(), lastActiveAt: Date()
        )
        let seededSecret = "sk-pane-test-secret-123456789"

        let writer = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        try await writer.startSession(session)
        try await writer.persistCommandEvent(PersistedCommandEvent(
            sessionID: session.id,
            timestamp: Date(),
            workingDirectory: "/tmp/project",
            command: "export OPENAI_API_KEY=\(seededSecret)",
            exitCode: 0,
            durationMilliseconds: 12,
            sanitizedOutputSummary: "token=\(seededSecret)",
            sanitizedErrorSummary: "Authorization: Bearer \(seededSecret)",
            predictionSource: nil,
            predictionAction: nil
        ))
        try await writer.persistFeatures([
            RuntimeFeature(
                sessionID: session.id,
                timestamp: Date(),
                key: "diagnostic",
                value: "Authorization: Bearer \(seededSecret)"
            )
        ])

        let reader = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        let restored = try await reader.loadRecentContext(
            workspaceID: "workspace-a",
            repositoryID: "repo-a",
            limit: 10
        )

        XCTAssertEqual(restored.sessions.map(\.id), [session.id])
        XCTAssertEqual(restored.commandEvents.count, 1)
        XCTAssertTrue(restored.commandEvents[0].command.contains("[REDACTED]"))
        XCTAssertFalse(restored.commandEvents[0].command.contains(seededSecret))
        XCTAssertFalse(restored.commandEvents[0].sanitizedErrorSummary?.contains(seededSecret) ?? true)
        XCTAssertFalse(restored.features[0].value.contains(seededSecret))

        let storedBytes = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).reduce(into: Data()) { bytes, url in
            bytes.append(try Data(contentsOf: url))
        }
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains(seededSecret))
    }

    func testSQLiteRetentionKeepsNewestBoundedCommandEvents() async throws {
        let directory = temporaryDirectory(named: "SQLiteRetention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteRuntimeStateStore(
            databaseURL: directory.appendingPathComponent("runtime.sqlite"),
            retentionPolicy: RuntimeStateRetentionPolicy(
                maximumAge: 30 * 24 * 60 * 60,
                maximumCommandEvents: 2,
                maximumDatabaseBytes: 64 * 1_024 * 1_024
            )
        )
        let session = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: Date(), lastActiveAt: Date()
        )
        try await store.startSession(session)
        let baseDate = Date().addingTimeInterval(-10)
        for offset in 0..<4 {
            try await store.persistCommandEvent(PersistedCommandEvent(
                sessionID: session.id,
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                workingDirectory: "/tmp",
                command: "command-\(offset)",
                exitCode: 0,
                durationMilliseconds: nil,
                sanitizedOutputSummary: nil,
                sanitizedErrorSummary: nil,
                predictionSource: nil,
                predictionAction: nil
            ))
        }

        try await store.applyRetentionPolicy()
        let context = try await store.loadRecentContext(
            workspaceID: "workspace-a",
            repositoryID: nil,
            limit: 10
        )
        XCTAssertEqual(context.commandEvents.map(\.command), ["command-3", "command-2"])
    }

    func testEphemeralStoreCreatesNoPersistenceFiles() async throws {
        let directory = temporaryDirectory(named: "Ephemeral")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryRuntimeStateStore()
        let session = RuntimeSession(
            id: UUID(), workspaceID: nil, repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: Date(), lastActiveAt: Date()
        )
        try await store.startSession(session)
        try await store.deleteAllState()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testInMemoryStoreRestoresRecentWorkspaceContextWithoutTypedInput() async throws {
        let store = InMemoryRuntimeStateStore()
        let sessionID = UUID()
        let session = RuntimeSession(
            id: sessionID,
            workspaceID: "workspace-a",
            repositoryID: "repo-a",
            shell: "/bin/zsh",
            initialWorkingDirectory: "/tmp/project",
            startedAt: Date(),
            lastActiveAt: Date()
        )
        try await store.startSession(session)
        try await store.persistCommandEvent(PersistedCommandEvent(
            sessionID: sessionID,
            timestamp: Date(),
            workingDirectory: "/tmp/project",
            command: "swift test",
            exitCode: 1,
            durationMilliseconds: 120,
            sanitizedOutputSummary: nil,
            sanitizedErrorSummary: "Cannot find RuntimeSnapshot in scope",
            predictionSource: nil,
            predictionAction: nil
        ))

        let context = try await store.loadRecentContext(
            workspaceID: "workspace-a",
            repositoryID: "repo-a",
            limit: 10
        )

        XCTAssertEqual(context.sessions, [session])
        XCTAssertEqual(context.commandEvents.map(\.command), ["swift test"])
        XCTAssertEqual(context.features, [])
    }

    func testDeletingWorkspaceOnlyRemovesMatchingSessions() async throws {
        let store = InMemoryRuntimeStateStore()
        let first = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/a",
            startedAt: Date(), lastActiveAt: Date()
        )
        let second = RuntimeSession(
            id: UUID(), workspaceID: "workspace-b", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/b",
            startedAt: Date(), lastActiveAt: Date()
        )
        try await store.startSession(first)
        try await store.startSession(second)

        try await store.deleteWorkspace("workspace-a")

        let remaining = try await store.loadRecentContext(
            workspaceID: nil,
            repositoryID: nil,
            limit: 10
        )
        XCTAssertEqual(remaining.sessions, [second])
    }

    private func temporaryDirectory(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
