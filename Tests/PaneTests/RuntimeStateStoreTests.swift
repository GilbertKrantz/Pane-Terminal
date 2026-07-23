import XCTest
import SQLite3
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
        settings.commandHistoryEnabled = false
        settings.visibleSessionRecoveryEnabled = false
        settings.predictionContextEnabled = false
        settings.outputSummariesEnabled = false
        settings.filePathCollectionEnabled = false

        let restored = RuntimeStateSettings(defaults: defaults)
        XCTAssertEqual(
            restored.configuration,
            RuntimeStateConfiguration(
                persistenceEnabled: false,
                commandHistoryEnabled: false,
                visibleSessionRecoveryEnabled: false,
                predictionContextEnabled: false,
                outputSummariesEnabled: false,
                filePathCollectionEnabled: false
            )
        )
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("secret")
        })
    }

    @MainActor
    func testRuntimeSettingsMigratesLegacyPredictionHistoryOnce() throws {
        let suiteName = "Pane.RuntimeStateSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "runtimeState.predictionHistoryEnabled")

        let migrated = RuntimeStateSettings(defaults: defaults)
        XCTAssertFalse(migrated.commandHistoryEnabled)
        XCTAssertFalse(migrated.visibleSessionRecoveryEnabled)
        XCTAssertFalse(migrated.predictionContextEnabled)

        defaults.set(true, forKey: "runtimeState.predictionHistoryEnabled")
        let restored = RuntimeStateSettings(defaults: defaults)
        XCTAssertFalse(restored.commandHistoryEnabled)
        XCTAssertFalse(restored.visibleSessionRecoveryEnabled)
        XCTAssertFalse(restored.predictionContextEnabled)
    }

    @MainActor
    func testDisablingPredictionHistoryClearsLiveAutocompleteHistory() {
        let session = TerminalSession()
        session.submit(command: "swift test")
        XCTAssertEqual(session.history.commands, ["swift test"])

        session.applyRuntimeStateConfiguration(RuntimeStateConfiguration(
            persistenceEnabled: true,
            commandHistoryEnabled: false,
            visibleSessionRecoveryEnabled: false,
            predictionContextEnabled: false,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        ))

        XCTAssertTrue(session.history.commands.isEmpty)
        session.submit(command: "git status")
        XCTAssertTrue(session.history.commands.isEmpty)
    }

    func testControllerRestoresDurableWorkspaceHistoryAcrossRecreation() async throws {
        let directory = temporaryDirectory(named: "ControllerRestore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let configuration = RuntimeStateConfiguration(
            persistenceEnabled: true,
            commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
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
                commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
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
                commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
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


    func testSessionLifecycleDefaultsToActiveAndCanCloseCleanly() async throws {
        let store = InMemoryRuntimeStateStore()
        let session = RuntimeSession(
            id: UUID(), workspaceID: nil, repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: Date(timeIntervalSince1970: 10),
            lastActiveAt: Date(timeIntervalSince1970: 20)
        )
        try await store.startSession(session)

        try await store.updateSessionLifecycle(
            session.id,
            lifecycle: .closedCleanly,
            lastActiveAt: Date(timeIntervalSince1970: 30)
        )

        let context = try await store.loadRecentContext(workspaceID: nil, repositoryID: nil, limit: 10)
        XCTAssertEqual(context.sessions.first?.lifecycle, .closedCleanly)
        XCTAssertEqual(context.sessions.first?.lastActiveAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(context.sessions.first?.schemaVersion, 4)
    }

    func testActiveSessionsAreMarkedInterruptedOnRecovery() async throws {
        let store = InMemoryRuntimeStateStore()
        let active = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 1),
            lastActiveAt: Date(timeIntervalSince1970: 2)
        )
        let closed = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 3),
            lastActiveAt: Date(timeIntervalSince1970: 4),
            lifecycle: .closedCleanly
        )
        try await store.startSession(active)
        try await store.startSession(closed)

        let interrupted = try await store.markActiveSessionsInterrupted(excluding: nil)

        XCTAssertEqual(interrupted.map(\.id), [active.id])
        let context = try await store.loadRecentContext(workspaceID: "workspace-a", repositoryID: nil, limit: 10)
        XCTAssertEqual(context.sessions.first { $0.id == active.id }?.lifecycle, .interrupted)
        XCTAssertEqual(context.sessions.first { $0.id == closed.id }?.lifecycle, .closedCleanly)
    }

    func testCollapsedStateUpdatePersistsForRestoration() async throws {
        let store = InMemoryRuntimeStateStore()
        let session = RuntimeSession(
            id: UUID(), workspaceID: nil, repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: Date(), lastActiveAt: Date()
        )
        let blockID = UUID()
        try await store.startSession(session)
        try await store.persistCommandEvent(PersistedCommandEvent(
            blockID: blockID, sessionID: session.id, timestamp: Date(),
            workingDirectory: "/tmp", command: "false", exitCode: 1,
            durationMilliseconds: 10, sanitizedOutputSummary: nil,
            sanitizedErrorSummary: "failed", predictionSource: nil,
            predictionAction: nil, completion: .completed
        ))

        try await store.updateCommandEventCollapsed(blockID, isCollapsed: true)

        let context = try await store.loadRecentContext(workspaceID: nil, repositoryID: nil, limit: 10)
        XCTAssertEqual(context.commandEvents.first?.blockID, blockID)
        XCTAssertTrue(context.commandEvents.first?.isCollapsed == true)
        XCTAssertEqual(context.commandEvents.first?.outputKind, PersistedOutputKind.none)
    }

    func testRestoreLimitsPreferNewestSessionsCommandsAndOutput() async throws {
        let store = InMemoryRuntimeStateStore()
        let base = Date(timeIntervalSince1970: 1_000)
        var sessions: [RuntimeSession] = []
        for index in 0..<4 {
            let session = RuntimeSession(
                id: UUID(), workspaceID: nil, repositoryID: nil,
                shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
                startedAt: base.addingTimeInterval(TimeInterval(index)),
                lastActiveAt: base.addingTimeInterval(TimeInterval(index))
            )
            sessions.append(session)
            try await store.startSession(session)
            try await store.persistCommandEvent(PersistedCommandEvent(
                sessionID: session.id,
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                workingDirectory: "/tmp", command: "command-\(index)",
                exitCode: 0, durationMilliseconds: nil,
                sanitizedOutputSummary: "aa", sanitizedErrorSummary: nil,
                predictionSource: nil, predictionAction: nil,
                outputKind: .excerpt
            ))
        }

        let context = try await store.loadRecentContext(
            workspaceID: nil,
            repositoryID: nil,
            limits: RuntimeStateRestoreLimits(
                maximumSessions: 3,
                maximumCommands: 2,
                maximumOutputBytes: 2
            )
        )

        XCTAssertEqual(context.sessions.map(\.id), sessions.suffix(3).reversed().map(\.id))
        XCTAssertEqual(context.commandEvents.map(\.command), ["command-3", "command-2"])
        XCTAssertEqual(context.commandEvents[0].sanitizedOutputSummary, "aa")
        XCTAssertNil(context.commandEvents[1].sanitizedOutputSummary)
        XCTAssertEqual(context.commandEvents[1].outputKind, .none)
    }

    func testControllerReportsCommandHistoryAndVisibleRecoveryIndependently() async throws {
        let directory = temporaryDirectory(named: "IndependentRecoverySettings")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let base = Date().addingTimeInterval(-100)
        let seededSession = RuntimeSession(
            id: UUID(), workspaceID: nil, repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: base, lastActiveAt: base.addingTimeInterval(1),
            lifecycle: .closedCleanly
        )
        let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        try await store.startSession(seededSession)
        try await store.persistCommandEvent(PersistedCommandEvent(
            sessionID: seededSession.id, timestamp: base.addingTimeInterval(1),
            workingDirectory: "/tmp", command: "pwd", exitCode: 0,
            durationMilliseconds: nil, sanitizedOutputSummary: nil,
            sanitizedErrorSummary: nil, predictionSource: nil, predictionAction: nil
        ))

        func result(commandHistory: Bool, visibleRecovery: Bool) async -> RuntimeStateOperationResult {
            let controller = RuntimeStateController(
                databaseURL: databaseURL,
                configuration: RuntimeStateConfiguration(
                    persistenceEnabled: true,
                    commandHistoryEnabled: commandHistory,
                    visibleSessionRecoveryEnabled: visibleRecovery,
                    predictionContextEnabled: false,
                    outputSummariesEnabled: false,
                    filePathCollectionEnabled: true
                )
            )
            return await controller.startSession(RuntimeSession(
                id: UUID(), workspaceID: nil, repositoryID: nil,
                shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
                startedAt: Date(), lastActiveAt: Date()
            ))
        }

        let historyOnly = await result(commandHistory: true, visibleRecovery: false)
        XCTAssertTrue(historyOnly.restoresCommandHistory)
        XCTAssertFalse(historyOnly.restoresVisibleBlocks)
        XCTAssertEqual(historyOnly.restoredContext?.commandEvents.map(\.command), ["pwd"])

        let recoveryOnly = await result(commandHistory: false, visibleRecovery: true)
        XCTAssertFalse(recoveryOnly.restoresCommandHistory)
        XCTAssertTrue(recoveryOnly.restoresVisibleBlocks)
        XCTAssertEqual(recoveryOnly.restoredContext?.commandEvents.map(\.command), ["pwd"])
    }

    func testPartiallyMigratedVersionThreeDatabaseFinishesSchemaFourMigration() async throws {
        let directory = temporaryDirectory(named: "PartialMigration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let sql = """
        CREATE TABLE runtime_sessions (
            id TEXT PRIMARY KEY, workspace_id TEXT, repository_id TEXT, shell TEXT NOT NULL,
            initial_working_directory TEXT NOT NULL, last_working_directory TEXT,
            started_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL,
            lifecycle TEXT NOT NULL DEFAULT 'active', pane_version TEXT NOT NULL DEFAULT '0.1',
            schema_version INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE command_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, block_id TEXT, session_id TEXT NOT NULL,
            timestamp INTEGER NOT NULL, working_directory TEXT NOT NULL, command TEXT NOT NULL,
            exit_code INTEGER, duration_ms INTEGER, sanitized_output_summary TEXT,
            sanitized_error_summary TEXT, prediction_source TEXT, prediction_action TEXT,
            completion_state TEXT NOT NULL DEFAULT 'completed', is_collapsed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE runtime_features (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, timestamp INTEGER NOT NULL,
            feature_key TEXT NOT NULL, feature_value TEXT NOT NULL
        );
        PRAGMA user_version = 3;
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        let session = RuntimeSession(
            id: UUID(), workspaceID: nil, repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/initial",
            lastWorkingDirectory: "/latest", startedAt: Date(), lastActiveAt: Date()
        )
        try await store.startSession(session)
        let context = try await store.loadRecentContext(workspaceID: nil, repositoryID: nil, limit: 10)
        XCTAssertEqual(context.sessions.first?.initialWorkingDirectory, "/initial")
        XCTAssertEqual(context.sessions.first?.lastWorkingDirectory, "/latest")

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".backup.sqlite") }
        XCTAssertEqual(backups.count, 1)
    }

    func testCorruptDatabaseIsMovedAsideWithoutStartupLoop() async throws {
        let directory = temporaryDirectory(named: "CorruptionRecovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let controller = RuntimeStateController(
            databaseURL: databaseURL,
            configuration: RuntimeStateConfiguration(
                persistenceEnabled: true,
                commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
                outputSummariesEnabled: false,
                filePathCollectionEnabled: true
            )
        )
        let result = await controller.startSession(RuntimeSession(
            id: UUID(), workspaceID: "/tmp", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp",
            startedAt: Date(), lastActiveAt: Date()
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(result.diagnostic?.contains("recovery file") == true)
        let recoveryFile = await controller.recoveryFile()
        XCTAssertNotNil(recoveryFile)
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

extension RuntimeStateStoreTests {
    @MainActor
    func testRestoreAcrossWorkspacesDefaultsOffInSettings() throws {
        let suiteName = "Pane.RuntimeStateRestoreScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = RuntimeStateSettings(defaults: defaults)
        XCTAssertFalse(settings.restoreAcrossWorkspacesEnabled)
        XCTAssertFalse(settings.configuration.restoreAcrossWorkspacesEnabled)
    }

    func testInMemoryRestoreScopesWorkspacesUnlessGlobalRequested() async throws {
        let store = InMemoryRuntimeStateStore()
        let sessionA = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/a", startedAt: Date(), lastActiveAt: Date()
        )
        let sessionB = RuntimeSession(
            id: UUID(), workspaceID: "workspace-b", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/b", startedAt: Date(), lastActiveAt: Date()
        )
        try await store.startSession(sessionA)
        try await store.startSession(sessionB)
        try await store.persistCommandEvent(PersistedCommandEvent(
            sessionID: sessionA.id, timestamp: Date(), workingDirectory: "/tmp/a", command: "echo a",
            exitCode: 0, durationMilliseconds: nil, sanitizedOutputSummary: nil, sanitizedErrorSummary: nil,
            predictionSource: nil, predictionAction: nil
        ))
        try await store.persistCommandEvent(PersistedCommandEvent(
            sessionID: sessionB.id, timestamp: Date(), workingDirectory: "/tmp/b", command: "echo b",
            exitCode: 0, durationMilliseconds: nil, sanitizedOutputSummary: nil, sanitizedErrorSummary: nil,
            predictionSource: nil, predictionAction: nil
        ))

        let scoped = try await store.loadRecentContext(workspaceID: "workspace-a", repositoryID: nil, limit: 10)
        XCTAssertEqual(scoped.sessions.map(\.workspaceID), ["workspace-a"])
        XCTAssertEqual(scoped.commandEvents.map(\.command), ["echo a"])

        let global = try await store.loadRecentContext(workspaceID: nil, repositoryID: nil, limit: 10)
        XCTAssertEqual(Set(global.commandEvents.map(\.command)), ["echo a", "echo b"])
    }

    func testControllerRestoreIsWorkspaceScopedGlobalOnlyByOptInAndDisabledWithoutPaths() async throws {
        let directory = temporaryDirectory(named: "ControllerWorkspaceScope")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let store = try SQLiteRuntimeStateStore(databaseURL: databaseURL)
        let base = Date().addingTimeInterval(-100)
        let sessionA = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: "repo-a",
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/a",
            startedAt: base,
            lastActiveAt: base.addingTimeInterval(1), lifecycle: .closedCleanly
        )
        let sessionB = RuntimeSession(
            id: UUID(), workspaceID: "workspace-b", repositoryID: "repo-b",
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/b",
            startedAt: base.addingTimeInterval(10),
            lastActiveAt: base.addingTimeInterval(11), lifecycle: .closedCleanly
        )
        try await store.startSession(sessionA)
        try await store.startSession(sessionB)
        try await store.persistCommandEvent(PersistedCommandEvent(
            sessionID: sessionA.id, timestamp: base.addingTimeInterval(2),
            workingDirectory: "/tmp/a", command: "echo a", exitCode: 0,
            durationMilliseconds: nil, sanitizedOutputSummary: nil,
            sanitizedErrorSummary: nil, predictionSource: nil, predictionAction: nil
        ))
        try await store.persistCommandEvent(PersistedCommandEvent(
            sessionID: sessionB.id, timestamp: base.addingTimeInterval(12),
            workingDirectory: "/tmp/b", command: "echo b", exitCode: 0,
            durationMilliseconds: nil, sanitizedOutputSummary: nil,
            sanitizedErrorSummary: nil, predictionSource: nil, predictionAction: nil
        ))

        let baseConfiguration = RuntimeStateConfiguration(
            persistenceEnabled: true,
            commandHistoryEnabled: true,
            visibleSessionRecoveryEnabled: true,
            predictionContextEnabled: true,
            outputSummariesEnabled: true,
            filePathCollectionEnabled: true
        )
        let currentA = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: "repo-a",
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/a",
            startedAt: Date(), lastActiveAt: Date()
        )
        let scoped = await RuntimeStateController(
            databaseURL: databaseURL,
            configuration: baseConfiguration
        ).startSession(currentA)
        XCTAssertEqual(scoped.restoredContext?.commandEvents.map(\.command), ["echo a"])

        var globalConfiguration = baseConfiguration
        globalConfiguration.restoreAcrossWorkspacesEnabled = true
        let global = await RuntimeStateController(
            databaseURL: databaseURL,
            configuration: globalConfiguration
        ).startSession(RuntimeSession(
            id: UUID(), workspaceID: "workspace-c", repositoryID: "repo-c",
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/c",
            startedAt: Date(), lastActiveAt: Date()
        ))
        XCTAssertEqual(Set(global.restoredContext?.commandEvents.map(\.command) ?? []), ["echo a", "echo b"])

        var noPathConfiguration = baseConfiguration
        noPathConfiguration.filePathCollectionEnabled = false
        let noPathRestore = await RuntimeStateController(
            databaseURL: databaseURL,
            configuration: noPathConfiguration
        ).startSession(RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: "repo-a",
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/a",
            startedAt: Date(), lastActiveAt: Date()
        ))
        XCTAssertTrue(noPathRestore.restoredContext?.commandEvents.isEmpty == true)
        XCTAssertTrue(noPathRestore.restoredContext?.sessions.isEmpty == true)
    }

    func testSQLiteSessionAndWorkspaceDeletionCascadeCommandEvents() async throws {
        let directory = temporaryDirectory(named: "SQLiteForeignKeyCascade")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteRuntimeStateStore(
            databaseURL: directory.appendingPathComponent("runtime.sqlite")
        )
        let sessionA = RuntimeSession(
            id: UUID(), workspaceID: "workspace-a", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/a",
            startedAt: Date(), lastActiveAt: Date()
        )
        let sessionB = RuntimeSession(
            id: UUID(), workspaceID: "workspace-b", repositoryID: nil,
            shell: "/bin/zsh", initialWorkingDirectory: "/tmp/b",
            startedAt: Date(), lastActiveAt: Date()
        )
        try await store.startSession(sessionA)
        try await store.startSession(sessionB)
        for (session, command) in [(sessionA, "echo a"), (sessionB, "echo b")] {
            try await store.persistCommandEvent(PersistedCommandEvent(
                sessionID: session.id, timestamp: Date(),
                workingDirectory: session.initialWorkingDirectory,
                command: command, exitCode: 0, durationMilliseconds: nil,
                sanitizedOutputSummary: nil, sanitizedErrorSummary: nil,
                predictionSource: nil, predictionAction: nil
            ))
        }

        try await store.deleteSession(sessionA.id)
        var context = try await store.loadRecentContext(
            workspaceID: nil, repositoryID: nil, limit: 10
        )
        XCTAssertEqual(context.sessions.map(\.id), [sessionB.id])
        XCTAssertEqual(context.commandEvents.map(\.command), ["echo b"])

        try await store.deleteWorkspace("workspace-b")
        context = try await store.loadRecentContext(
            workspaceID: nil, repositoryID: nil, limit: 10
        )
        XCTAssertTrue(context.sessions.isEmpty)
        XCTAssertTrue(context.commandEvents.isEmpty)
        XCTAssertTrue(context.features.isEmpty)
    }
}
