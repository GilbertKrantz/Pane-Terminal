import Foundation
import SQLite3

struct RuntimeStateRetentionPolicy: Sendable, Equatable {
    var maximumAge: TimeInterval
    var maximumCommandEvents: Int
    var maximumDatabaseBytes: Int64

    static let `default` = RuntimeStateRetentionPolicy(
        maximumAge: 30 * 24 * 60 * 60,
        maximumCommandEvents: 50_000,
        maximumDatabaseBytes: 64 * 1_024 * 1_024
    )
}

enum RuntimeStateStoreError: Error, LocalizedError {
    case openFailed
    case databaseFailure(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            return "Unable to open the runtime-state database."
        case .databaseFailure(let operation, let code):
            return "Runtime-state database operation failed: \(operation) (SQLite \(code))."
        }
    }
}

/// Durable storage for sanitized prediction context. Every content-bearing
/// value is sanitized again at this boundary so a caller cannot accidentally
/// write raw command, output, error, or feature text to SQLite.
actor SQLiteRuntimeStateStore: RuntimeStateStore {
    private let databaseURL: URL
    private let retentionPolicy: RuntimeStateRetentionPolicy
    private let sanitizer: any SensitiveDataSanitizing
    private var database: OpaquePointer?
    private var requiresBehavioralBackfill = false

    init(
        databaseURL: URL,
        retentionPolicy: RuntimeStateRetentionPolicy = .default,
        sanitizer: any SensitiveDataSanitizing = SensitiveDataSanitizer()
    ) throws {
        self.databaseURL = databaseURL
        self.retentionPolicy = retentionPolicy
        self.sanitizer = sanitizer

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw RuntimeStateStoreError.openFailed
        }
        do {
            let version = try Self.userVersion(handle)
            requiresBehavioralBackfill = version > 0 && version < 5
            try Self.backUpBeforeMigrationIfNeeded(handle, databaseURL: databaseURL)
            try Self.configureAndMigrate(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        database = handle
    }

    func startSession(_ session: RuntimeSession) async throws {
        let sql = """
        INSERT INTO runtime_sessions (
            id, workspace_id, repository_id, shell,
            initial_working_directory, last_working_directory, started_at, last_active_at,
            lifecycle, pane_version, schema_version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            workspace_id = excluded.workspace_id,
            repository_id = excluded.repository_id,
            shell = excluded.shell,
            last_working_directory = excluded.last_working_directory,
            last_active_at = excluded.last_active_at,
            lifecycle = excluded.lifecycle,
            pane_version = excluded.pane_version,
            schema_version = excluded.schema_version
        """
        try withStatement(sql, operation: "start session") { statement in
            try bind(session.id.uuidString, at: 1, to: statement)
            try bind(session.workspaceID, at: 2, to: statement)
            try bind(session.repositoryID, at: 3, to: statement)
            try bind(sanitizer.sanitizeCommand(session.shell).value, at: 4, to: statement)
            try bind(sanitizer.sanitizeCommand(session.initialWorkingDirectory).value, at: 5, to: statement)
            try bind(sanitizer.sanitizeCommand(session.lastWorkingDirectory).value, at: 6, to: statement)
            try bind(milliseconds(session.startedAt), at: 7, to: statement)
            try bind(milliseconds(session.lastActiveAt), at: 8, to: statement)
            try bind(session.lifecycle.rawValue, at: 9, to: statement)
            try bind(session.paneVersion, at: 10, to: statement)
            try bind(Int64(session.schemaVersion), at: 11, to: statement)
            try stepDone(statement, operation: "start session")
        }
    }

    func persistCommandEvent(_ event: PersistedCommandEvent) async throws {
        let command = sanitizer.sanitizeCommand(event.command)
        let output = event.sanitizedOutputSummary.map(sanitizer.sanitizeOutput)
        let error = event.sanitizedErrorSummary.map(sanitizer.sanitizeError)
        let sql = """
        INSERT INTO command_events (
            block_id, session_id, timestamp, working_directory, command, exit_code,
            duration_ms, sanitized_output_summary, sanitized_error_summary,
            prediction_source, prediction_action, completion_state, is_collapsed, output_kind
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(block_id) DO UPDATE SET
            timestamp = excluded.timestamp,
            working_directory = excluded.working_directory,
            command = excluded.command,
            exit_code = excluded.exit_code,
            duration_ms = excluded.duration_ms,
            sanitized_output_summary = excluded.sanitized_output_summary,
            sanitized_error_summary = excluded.sanitized_error_summary,
            completion_state = excluded.completion_state,
            is_collapsed = excluded.is_collapsed,
            output_kind = excluded.output_kind
        """
        try withStatement(sql, operation: "persist command") { statement in
            try bind(event.blockID.uuidString, at: 1, to: statement)
            try bind(event.sessionID.uuidString, at: 2, to: statement)
            try bind(milliseconds(event.timestamp), at: 3, to: statement)
            try bind(sanitizer.sanitizeCommand(event.workingDirectory).value, at: 4, to: statement)
            try bind(command.value, at: 5, to: statement)
            try bind(event.exitCode.map(Int64.init), at: 6, to: statement)
            try bind(event.durationMilliseconds.map(Int64.init), at: 7, to: statement)
            try bind(output.map { String($0.value.prefix(1_000)) }, at: 8, to: statement)
            try bind(error.map { String($0.value.prefix(1_000)) }, at: 9, to: statement)
            try bind(event.predictionSource, at: 10, to: statement)
            try bind(event.predictionAction, at: 11, to: statement)
            try bind(event.completion.rawValue, at: 12, to: statement)
            try bind(event.isCollapsed ? Int64(1) : Int64(0), at: 13, to: statement)
            try bind(event.outputKind.rawValue, at: 14, to: statement)
            try stepDone(statement, operation: "persist command")
        }
    }

    func updateCommandEventCollapsed(_ blockID: UUID, isCollapsed: Bool) async throws {
        let sql = "UPDATE command_events SET is_collapsed = ? WHERE block_id = ?"
        try withStatement(sql, operation: "update collapsed state") { statement in
            try bind(isCollapsed ? Int64(1) : Int64(0), at: 1, to: statement)
            try bind(blockID.uuidString, at: 2, to: statement)
            try stepDone(statement, operation: "update collapsed state")
        }
    }

    func persistFeatures(_ features: [RuntimeFeature]) async throws {
        guard !features.isEmpty else { return }
        try transaction {
            let sql = """
            INSERT INTO runtime_features (
                session_id, timestamp, feature_key, feature_value
            ) VALUES (?, ?, ?, ?)
            """
            try withStatement(sql, operation: "persist features") { statement in
                for feature in features {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(feature.sessionID.uuidString, at: 1, to: statement)
                    try bind(milliseconds(feature.timestamp), at: 2, to: statement)
                    try bind(feature.key, at: 3, to: statement)
                    try bind(sanitizer.sanitizeOutput(feature.value).value, at: 4, to: statement)
                    try stepDone(statement, operation: "persist features")
                }
            }
        }
    }

    func loadRecentContext(
        workspaceID: String?,
        repositoryID: String?,
        limits: RuntimeStateRestoreLimits
    ) async throws -> PersistedRuntimeContext {
        let boundedLimit = max(0, limits.maximumCommands)
        let boundedSessionLimit = max(0, limits.maximumSessions)
        var sessions: [RuntimeSession] = []
        var sessionIDs: [String] = []
        let sessionSQL = """
        SELECT id, workspace_id, repository_id, shell,
               initial_working_directory, last_working_directory, started_at, last_active_at,
               lifecycle, pane_version, schema_version
        FROM runtime_sessions
        WHERE (? IS NULL OR workspace_id = ?)
          AND (? IS NULL OR repository_id = ?)
        ORDER BY last_active_at DESC
        LIMIT ?
        """
        try withStatement(sessionSQL, operation: "load sessions") { statement in
            try bind(workspaceID, at: 1, to: statement)
            try bind(workspaceID, at: 2, to: statement)
            try bind(repositoryID, at: 3, to: statement)
            try bind(repositoryID, at: 4, to: statement)
            try bind(Int64(boundedSessionLimit), at: 5, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = columnText(statement, 0),
                      let id = UUID(uuidString: idText),
                      let shell = columnText(statement, 3),
                      let directory = columnText(statement, 4) else { continue }
                let lastDirectory = columnText(statement, 5) ?? directory
                sessionIDs.append(idText)
                sessions.append(RuntimeSession(
                    id: id,
                    workspaceID: columnText(statement, 1),
                    repositoryID: columnText(statement, 2),
                    shell: shell,
                    initialWorkingDirectory: directory,
                    lastWorkingDirectory: lastDirectory,
                    startedAt: date(sqlite3_column_int64(statement, 6)),
                    lastActiveAt: date(sqlite3_column_int64(statement, 7)),
                    lifecycle: PersistedSessionLifecycle(rawValue: columnText(statement, 8) ?? "") ?? .active,
                    paneVersion: columnText(statement, 9) ?? "0.1",
                    schemaVersion: columnInt(statement, 10) ?? 1
                ))
            }
        }

        guard !sessionIDs.isEmpty, boundedLimit > 0 else {
            return PersistedRuntimeContext(sessions: sessions, commandEvents: [], features: [])
        }

        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        var events: [PersistedCommandEvent] = []
        let eventSQL = """
        SELECT block_id, session_id, timestamp, working_directory, command, exit_code,
               duration_ms, sanitized_output_summary, sanitized_error_summary,
               prediction_source, prediction_action, completion_state, is_collapsed, output_kind
        FROM command_events
        WHERE session_id IN (\(placeholders))
        ORDER BY timestamp DESC LIMIT ?
        """
        try withStatement(eventSQL, operation: "load commands") { statement in
            try bindIdentifiers(sessionIDs, to: statement)
            try bind(Int64(boundedLimit), at: Int32(sessionIDs.count + 1), to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blockText = columnText(statement, 0),
                      let blockID = UUID(uuidString: blockText),
                      let sessionText = columnText(statement, 1),
                      let sessionID = UUID(uuidString: sessionText),
                      let directory = columnText(statement, 3),
                      let command = columnText(statement, 4) else { continue }
                events.append(PersistedCommandEvent(
                    blockID: blockID,
                    sessionID: sessionID,
                    timestamp: date(sqlite3_column_int64(statement, 2)),
                    workingDirectory: directory,
                    command: command,
                    exitCode: columnInt(statement, 5),
                    durationMilliseconds: columnInt(statement, 6),
                    sanitizedOutputSummary: columnText(statement, 7),
                    sanitizedErrorSummary: columnText(statement, 8),
                    predictionSource: columnText(statement, 9),
                    predictionAction: columnText(statement, 10),
                    completion: PersistedCommandEvent.Completion(rawValue: columnText(statement, 11) ?? "") ?? .completed,
                    isCollapsed: sqlite3_column_int64(statement, 12) != 0,
                    outputKind: PersistedOutputKind(rawValue: columnText(statement, 13) ?? "") ?? .none
                ))
            }
        }

        var features: [RuntimeFeature] = []
        let featureSQL = """
        SELECT session_id, timestamp, feature_key, feature_value
        FROM runtime_features
        WHERE session_id IN (\(placeholders))
        ORDER BY timestamp DESC LIMIT ?
        """
        try withStatement(featureSQL, operation: "load features") { statement in
            try bindIdentifiers(sessionIDs, to: statement)
            try bind(Int64(boundedLimit), at: Int32(sessionIDs.count + 1), to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionText = columnText(statement, 0),
                      let sessionID = UUID(uuidString: sessionText),
                      let key = columnText(statement, 2),
                      let value = columnText(statement, 3) else { continue }
                features.append(RuntimeFeature(
                    sessionID: sessionID,
                    timestamp: date(sqlite3_column_int64(statement, 1)),
                    key: key,
                    value: value
                ))
            }
        }

        return PersistedRuntimeContext(
            sessions: sessions,
            commandEvents: Self.enforcingOutputLimit(events, maximumBytes: limits.maximumOutputBytes),
            features: features
        )
    }

    private static func enforcingOutputLimit(
        _ events: [PersistedCommandEvent],
        maximumBytes: Int
    ) -> [PersistedCommandEvent] {
        var remaining = max(0, maximumBytes)
        return events.map { event in
            let byteCount = (event.sanitizedOutputSummary?.utf8.count ?? 0)
                + (event.sanitizedErrorSummary?.utf8.count ?? 0)
            guard byteCount <= remaining else {
                return PersistedCommandEvent(
                    blockID: event.blockID, sessionID: event.sessionID, timestamp: event.timestamp,
                    workingDirectory: event.workingDirectory, command: event.command,
                    exitCode: event.exitCode, durationMilliseconds: event.durationMilliseconds,
                    sanitizedOutputSummary: nil, sanitizedErrorSummary: nil,
                    predictionSource: event.predictionSource, predictionAction: event.predictionAction,
                    completion: event.completion, isCollapsed: event.isCollapsed, outputKind: .none
                )
            }
            remaining -= byteCount
            return event
        }
    }

    func deleteSession(_ sessionID: UUID) async throws {
        try executeBound(
            "DELETE FROM runtime_sessions WHERE id = ?",
            operation: "delete session",
            values: [sessionID.uuidString]
        )
    }

    func deleteWorkspace(_ workspaceID: String) async throws {
        try executeBound(
            "DELETE FROM runtime_sessions WHERE workspace_id = ?",
            operation: "delete workspace",
            values: [workspaceID]
        )
    }

    func deleteAllState() async throws {
        try transaction {
            try execute("DELETE FROM completion_feedback_aggregates")
            try execute("DELETE FROM command_transitions")
            try execute("DELETE FROM command_aggregates")
            try execute("DELETE FROM behavioral_processed_transitions")
            try execute("DELETE FROM behavioral_processed_commands")
            try execute("DELETE FROM runtime_features")
            try execute("DELETE FROM command_events")
            try execute("DELETE FROM runtime_sessions")
        }
    }

    func deleteSessions(excluding sessionID: UUID) async throws {
        try executeBound(
            "DELETE FROM runtime_sessions WHERE id != ?",
            operation: "delete previous sessions",
            values: [sessionID.uuidString]
        )
    }

    func deleteAllCommandEvents() async throws {
        try execute("DELETE FROM command_events")
    }

    func clearPersistedOutput() async throws {
        try execute("UPDATE command_events SET sanitized_output_summary = NULL, sanitized_error_summary = NULL, output_kind = 'none'")
    }

    func updateSessionLifecycle(_ sessionID: UUID, lifecycle: PersistedSessionLifecycle, lastActiveAt: Date) async throws {
        let sql = """
        UPDATE runtime_sessions
        SET lifecycle = ?, last_active_at = ?
        WHERE id = ?
        """
        try withStatement(sql, operation: "update session lifecycle") { statement in
            try bind(lifecycle.rawValue, at: 1, to: statement)
            try bind(milliseconds(lastActiveAt), at: 2, to: statement)
            try bind(sessionID.uuidString, at: 3, to: statement)
            try stepDone(statement, operation: "update session lifecycle")
        }
    }

    func markActiveSessionsInterrupted(excluding sessionID: UUID?) async throws -> [RuntimeSession] {
        let context = try await loadRecentContext(workspaceID: nil, repositoryID: nil, limits: .commands(0))
        let active = context.sessions.filter { $0.lifecycle == .active && $0.id != sessionID }
        for session in active {
            try await updateSessionLifecycle(session.id, lifecycle: .interrupted, lastActiveAt: session.lastActiveAt)
        }
        return active.map { session in
            RuntimeSession(
                id: session.id, workspaceID: session.workspaceID, repositoryID: session.repositoryID,
                shell: session.shell, initialWorkingDirectory: session.initialWorkingDirectory,
                lastWorkingDirectory: session.lastWorkingDirectory,
                startedAt: session.startedAt, lastActiveAt: session.lastActiveAt, lifecycle: .interrupted,
                paneVersion: session.paneVersion, schemaVersion: session.schemaVersion
            )
        }
    }

    func applyRetentionPolicy() async throws {
        let cutoff = milliseconds(Date().addingTimeInterval(-retentionPolicy.maximumAge))
        let behavioralCutoff = Date()
            .addingTimeInterval(-retentionPolicy.maximumAge)
            .timeIntervalSince1970
        try execute("DELETE FROM command_events WHERE timestamp < \(cutoff)")
        try execute("DELETE FROM runtime_features WHERE timestamp < \(cutoff)")
        try execute("DELETE FROM command_aggregates WHERE last_used_at < \(behavioralCutoff)")
        try execute("DELETE FROM command_transitions WHERE last_observed_at < \(behavioralCutoff)")
        try execute("DELETE FROM completion_feedback_aggregates WHERE last_feedback_at < \(behavioralCutoff)")

        let maximumEvents = max(0, retentionPolicy.maximumCommandEvents)
        try execute("""
        DELETE FROM command_events
        WHERE id NOT IN (
            SELECT id FROM command_events ORDER BY timestamp DESC LIMIT \(maximumEvents)
        )
        """)

        guard retentionPolicy.maximumDatabaseBytes > 0 else { return }
        var size = try databaseSize()
        while size > retentionPolicy.maximumDatabaseBytes {
            let previousChanges = sqlite3_total_changes(database)
            try execute("""
            DELETE FROM command_events WHERE id IN (
                SELECT id FROM command_events ORDER BY timestamp ASC LIMIT 500
            )
            """)
            try execute("""
            DELETE FROM runtime_features WHERE id IN (
                SELECT id FROM runtime_features ORDER BY timestamp ASC LIMIT 500
            )
            """)
            guard sqlite3_total_changes(database) > previousChanges else { break }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            size = try databaseSize()
        }
    }

    private static func configureAndMigrate(_ database: OpaquePointer) throws {
        func run(_ sql: String, operation: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw RuntimeStateStoreError.databaseFailure(
                    operation: operation,
                    code: sqlite3_errcode(database)
                )
            }
        }

        func hasColumn(_ column: String, in table: String) throws -> Bool {
            var columnStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &columnStatement, nil) == SQLITE_OK,
                  let columnStatement else {
                throw RuntimeStateStoreError.databaseFailure(
                    operation: "inspect \(table) schema",
                    code: sqlite3_errcode(database)
                )
            }
            defer { sqlite3_finalize(columnStatement) }
            while sqlite3_step(columnStatement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_text(columnStatement, 1) else { continue }
                if String(cString: bytes) == column { return true }
            }
            return false
        }

        try run("PRAGMA foreign_keys = ON", operation: "enable foreign keys")
        try run("PRAGMA journal_mode = WAL", operation: "enable WAL")
        try run("PRAGMA synchronous = NORMAL", operation: "configure synchronization")

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RuntimeStateStoreError.databaseFailure(
                operation: "read schema version",
                code: sqlite3_errcode(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RuntimeStateStoreError.databaseFailure(
                operation: "read schema version",
                code: sqlite3_errcode(database)
            )
        }
        let currentVersion = sqlite3_column_int64(statement, 0)
        guard currentVersion <= 5 else { return }
        guard currentVersion < 5 else { return }
        guard currentVersion == 0 else {
            try run("BEGIN IMMEDIATE", operation: "begin migration")
            do {
                if try !hasColumn("lifecycle", in: "runtime_sessions") {
                    try run("ALTER TABLE runtime_sessions ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'", operation: "add session lifecycle")
                }
                if try !hasColumn("pane_version", in: "runtime_sessions") {
                    try run("ALTER TABLE runtime_sessions ADD COLUMN pane_version TEXT NOT NULL DEFAULT '0.1'", operation: "add pane version")
                }
                if try !hasColumn("schema_version", in: "runtime_sessions") {
                    try run("ALTER TABLE runtime_sessions ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1", operation: "add local schema version")
                }
                if try !hasColumn("block_id", in: "command_events") {
                    try run("ALTER TABLE command_events ADD COLUMN block_id TEXT", operation: "add block identifier")
                }
                try run("UPDATE command_events SET block_id = lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))),2) || '-' || substr('89ab',abs(random()) % 4 + 1,1) || substr(lower(hex(randomblob(2))),2) || '-' || lower(hex(randomblob(6))) WHERE block_id IS NULL", operation: "backfill block identifiers")
                if try !hasColumn("completion_state", in: "command_events") {
                    try run("ALTER TABLE command_events ADD COLUMN completion_state TEXT NOT NULL DEFAULT 'completed'", operation: "add completion state")
                }
                if try !hasColumn("is_collapsed", in: "command_events") {
                    try run("ALTER TABLE command_events ADD COLUMN is_collapsed INTEGER NOT NULL DEFAULT 0", operation: "add collapsed state")
                }
                // A partially migrated store can contain duplicate non-null IDs
                // before its unique index was created. Retain the newest row.
                try run("DELETE FROM command_events WHERE block_id IS NOT NULL AND id NOT IN (SELECT MAX(id) FROM command_events WHERE block_id IS NOT NULL GROUP BY block_id)", operation: "deduplicate block identifiers")
                try run("CREATE UNIQUE INDEX IF NOT EXISTS idx_command_events_block ON command_events(block_id)", operation: "index block identifiers")
                if try !hasColumn("last_working_directory", in: "runtime_sessions") {
                    try run("ALTER TABLE runtime_sessions ADD COLUMN last_working_directory TEXT", operation: "add last working directory")
                }
                try run("UPDATE runtime_sessions SET last_working_directory = initial_working_directory WHERE last_working_directory IS NULL", operation: "backfill last working directory")
                if try !hasColumn("output_kind", in: "command_events") {
                    try run("ALTER TABLE command_events ADD COLUMN output_kind TEXT NOT NULL DEFAULT 'none'", operation: "add output kind")
                }
                try run("UPDATE command_events SET output_kind = 'excerpt' WHERE output_kind = 'none' AND (sanitized_output_summary IS NOT NULL OR sanitized_error_summary IS NOT NULL)", operation: "classify stored output excerpts")
                try createBehavioralTables(run)
                try run("PRAGMA user_version = 5", operation: "set schema version")
                try run("COMMIT", operation: "commit migration")
            } catch {
                try? run("ROLLBACK", operation: "rollback migration")
                throw error
            }
            return
        }

        try run("BEGIN IMMEDIATE", operation: "begin migration")
        do {
            try run("""
            CREATE TABLE runtime_sessions (
                id TEXT PRIMARY KEY,
                workspace_id TEXT,
                repository_id TEXT,
                shell TEXT NOT NULL,
                initial_working_directory TEXT NOT NULL,
                last_working_directory TEXT,
                started_at INTEGER NOT NULL,
                last_active_at INTEGER NOT NULL,
                lifecycle TEXT NOT NULL DEFAULT 'active',
                pane_version TEXT NOT NULL DEFAULT '0.1',
                schema_version INTEGER NOT NULL DEFAULT 1
            )
            """, operation: "create sessions table")
            try run("""
            CREATE TABLE command_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                block_id TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                working_directory TEXT NOT NULL,
                command TEXT NOT NULL,
                exit_code INTEGER,
                duration_ms INTEGER,
                sanitized_output_summary TEXT,
                sanitized_error_summary TEXT,
                prediction_source TEXT,
                prediction_action TEXT,
                completion_state TEXT NOT NULL DEFAULT 'completed',
                is_collapsed INTEGER NOT NULL DEFAULT 0,
                output_kind TEXT NOT NULL DEFAULT 'none',
                FOREIGN KEY(session_id) REFERENCES runtime_sessions(id) ON DELETE CASCADE
            )
            """, operation: "create command-events table")
            try run("CREATE INDEX idx_command_events_session_time ON command_events(session_id, timestamp DESC)", operation: "index command sessions")
            try run("CREATE INDEX idx_command_events_directory_time ON command_events(working_directory, timestamp DESC)", operation: "index command directories")
            try run("""
            CREATE TABLE runtime_features (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                feature_key TEXT NOT NULL,
                feature_value TEXT NOT NULL,
                FOREIGN KEY(session_id) REFERENCES runtime_sessions(id) ON DELETE CASCADE
            )
            """, operation: "create runtime-features table")
            try run("CREATE INDEX idx_runtime_features_session_time ON runtime_features(session_id, timestamp DESC)", operation: "index runtime features")
            try createBehavioralTables(run)
            try run("PRAGMA user_version = 5", operation: "set schema version")
            try run("COMMIT", operation: "commit migration")
        } catch {
            try? run("ROLLBACK", operation: "rollback migration")
            throw error
        }
    }

    private static func createBehavioralTables(
        _ run: (String, String) throws -> Void
    ) throws {
        try run("""
        CREATE TABLE IF NOT EXISTS command_aggregates (
            normalized_command TEXT NOT NULL, command_key TEXT NOT NULL,
            project_id TEXT NOT NULL DEFAULT '', directory_id TEXT NOT NULL DEFAULT '',
            total_count INTEGER NOT NULL, successful_count INTEGER NOT NULL,
            failed_count INTEGER NOT NULL, interrupted_count INTEGER NOT NULL,
            first_used_at REAL NOT NULL, last_used_at REAL NOT NULL,
            PRIMARY KEY(normalized_command, project_id, directory_id)
        )
        """, "create command aggregates")
        try run("CREATE INDEX IF NOT EXISTS idx_command_aggregates_prefix ON command_aggregates(normalized_command)", "index aggregate prefix")
        try run("CREATE INDEX IF NOT EXISTS idx_command_aggregates_scope_time ON command_aggregates(project_id, directory_id, last_used_at DESC)", "index aggregate scope")
        try run("CREATE INDEX IF NOT EXISTS idx_command_aggregates_key ON command_aggregates(command_key)", "index command key")
        try run("""
        CREATE TABLE IF NOT EXISTS command_transitions (
            previous_command_key TEXT NOT NULL, next_normalized_command TEXT NOT NULL,
            project_id TEXT NOT NULL DEFAULT '', directory_id TEXT NOT NULL DEFAULT '',
            total_count INTEGER NOT NULL, successful_next_count INTEGER NOT NULL,
            last_observed_at REAL NOT NULL,
            PRIMARY KEY(previous_command_key, next_normalized_command, project_id, directory_id)
        )
        """, "create command transitions")
        try run("CREATE INDEX IF NOT EXISTS idx_command_transitions_lookup ON command_transitions(previous_command_key, project_id, directory_id, total_count DESC)", "index transitions")
        try run("""
        CREATE TABLE IF NOT EXISTS completion_feedback_aggregates (
            candidate_identity TEXT NOT NULL, project_id TEXT NOT NULL DEFAULT '',
            directory_id TEXT NOT NULL DEFAULT '', acceptance_count INTEGER NOT NULL,
            dismissal_count INTEGER NOT NULL, replacement_count INTEGER NOT NULL,
            last_feedback_at REAL NOT NULL,
            PRIMARY KEY(candidate_identity, project_id, directory_id)
        )
        """, "create completion feedback")
        try run("CREATE INDEX IF NOT EXISTS idx_completion_feedback_lookup ON completion_feedback_aggregates(candidate_identity, project_id, directory_id)", "index completion feedback")
        try run("""
        CREATE TABLE IF NOT EXISTS behavioral_processed_commands (
            event_id TEXT PRIMARY KEY
        )
        """, "create processed behavioral commands")
        try run("""
        CREATE TABLE IF NOT EXISTS behavioral_processed_transitions (
            event_id TEXT PRIMARY KEY
        )
        """, "create processed behavioral transitions")
    }

    private static func backUpBeforeMigrationIfNeeded(
        _ database: OpaquePointer,
        databaseURL: URL
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw RuntimeStateStoreError.databaseFailure(operation: "read schema version", code: sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return }
        let version = sqlite3_column_int64(statement, 0)
        guard version > 0, version < 5 else { return }

        let backupURL = databaseURL.deletingPathExtension()
            .appendingPathExtension("v\(version)-\(UUID().uuidString).backup.sqlite")
        var backupDatabase: OpaquePointer?
        guard sqlite3_open_v2(
            backupURL.path,
            &backupDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let backupDatabase else {
            if let backupDatabase { sqlite3_close(backupDatabase) }
            throw RuntimeStateStoreError.openFailed
        }
        defer { sqlite3_close(backupDatabase) }
        guard let backup = sqlite3_backup_init(backupDatabase, "main", database, "main") else {
            throw RuntimeStateStoreError.databaseFailure(operation: "create migration backup", code: sqlite3_errcode(backupDatabase))
        }
        let result = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else {
            throw RuntimeStateStoreError.databaseFailure(operation: "write migration backup", code: result)
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RuntimeStateStoreError.databaseFailure(
                operation: "read schema version",
                code: sqlite3_errcode(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RuntimeStateStoreError.databaseFailure(
                operation: "read schema version",
                code: sqlite3_errcode(database)
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure("execute statement")
        }
    }

    private func executeBound(_ sql: String, operation: String, values: [String]) throws {
        try withStatement(sql, operation: operation) { statement in
            for (offset, value) in values.enumerated() {
                try bind(value, at: Int32(offset + 1), to: statement)
            }
            try stepDone(statement, operation: operation)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        var result: Int64 = 0
        try withStatement(sql, operation: "read scalar") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("read scalar") }
            result = sqlite3_column_int64(statement, 0)
        }
        return result
    }

    private func databaseSize() throws -> Int64 {
        try scalarInt("PRAGMA page_count") * scalarInt("PRAGMA page_size")
    }

    private func withStatement(
        _ sql: String,
        operation: String,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure(operation) }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func bindIdentifiers(_ identifiers: [String], to statement: OpaquePointer) throws {
        for (offset, identifier) in identifiers.enumerated() {
            try bind(identifier, at: Int32(offset + 1), to: statement)
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw failure("bind null") }
            return
        }
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw failure("bind text") }
    }

    private func bind(_ value: Int64?, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.map { sqlite3_bind_int64(statement, index, $0) }
            ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw failure("bind integer") }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw failure("bind real")
        }
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(operation) }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func failure(_ operation: String) -> RuntimeStateStoreError {
        RuntimeStateStoreError.databaseFailure(
            operation: operation,
            code: sqlite3_errcode(database)
        )
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

extension SQLiteRuntimeStateStore: BehavioralCompletionStore {
    func needsBehavioralBackfill() -> Bool {
        requiresBehavioralBackfill
    }

    func backfillBehavioralHistory(
        maximumCommands: Int = 10_000,
        batchSize: Int = 500
    ) async throws {
        let maximum = min(10_000, max(0, maximumCommands))
        let batch = min(500, max(1, batchSize))
        guard maximum > 0 else { return }
        var offset = 0
        while offset < maximum, !Task.isCancelled {
            var records: [BehavioralCommandRecord] = []
            var fetchedCount = 0
            try withStatement("""
                SELECT e.block_id, e.command, e.working_directory, e.exit_code,
                       e.completion_state, e.timestamp, s.repository_id
                FROM command_events e
                LEFT JOIN runtime_sessions s ON s.id = e.session_id
                WHERE e.completion_state IN ('completed', 'interrupted')
                ORDER BY e.timestamp DESC, e.id DESC
                LIMIT ? OFFSET ?
                """, operation: "read behavioral backfill batch") { statement in
                try bind(Int64(min(batch, maximum - offset)), at: 1, to: statement)
                try bind(Int64(offset), at: 2, to: statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    fetchedCount += 1
                    guard let rawID = columnText(statement, 0),
                          let eventID = UUID(uuidString: rawID),
                          let command = columnText(statement, 1) else { continue }
                    let normalized = NormalizedCommand(command)
                    guard let commandKey = normalized.commandKey else { continue }
                    let completion = columnText(statement, 4)
                    let exitCode = columnInt(statement, 3)
                    let outcome: BehavioralCommandOutcome = completion == "interrupted"
                        ? .interrupted
                        : (exitCode == 0 ? .succeeded : .failed)
                    records.append(BehavioralCommandRecord(
                        eventID: eventID,
                        normalizedCommand: normalized.full,
                        commandKey: commandKey,
                        projectID: columnText(statement, 6),
                        directoryIdentity: columnText(statement, 2),
                        outcome: outcome,
                        observedAt: date(sqlite3_column_int64(statement, 5))
                    ))
                }
            }
            guard fetchedCount > 0 else { break }
            for record in records {
                try Task.checkCancellation()
                try await recordCommand(record)
            }
            offset += fetchedCount
            await Task.yield()
        }
        if !Task.isCancelled {
            requiresBehavioralBackfill = false
        }
    }

    func recordCommand(_ record: BehavioralCommandRecord) async throws {
        let sanitized = sanitizer.sanitizeCommand(record.normalizedCommand)
        let normalized = NormalizedCommand(sanitized.value)
        guard sanitized.redactionCount == 0,
              !normalized.full.isEmpty,
              !normalized.full.contains(SensitiveDataSanitizer.redaction),
              normalized.full.count <= 4_096,
              normalized.commandKey == record.commandKey else { return }

        try transaction {
            try withStatement(
                "INSERT OR IGNORE INTO behavioral_processed_commands(event_id) VALUES (?)",
                operation: "claim behavioral command"
            ) { statement in
                try bind(record.eventID.uuidString, at: 1, to: statement)
                try stepDone(statement, operation: "claim behavioral command")
            }
            guard sqlite3_changes(database) == 1 else { return }

            let counts: (Int64, Int64, Int64)
            switch record.outcome {
            case .succeeded: counts = (1, 0, 0)
            case .failed: counts = (0, 1, 0)
            case .interrupted: counts = (0, 0, 1)
            }
            for scope in behavioralScopes(
                projectID: record.projectID,
                directoryIdentity: record.directoryIdentity
            ) {
                try withStatement("""
                    INSERT INTO command_aggregates (
                        normalized_command, command_key, project_id, directory_id,
                        total_count, successful_count, failed_count, interrupted_count,
                        first_used_at, last_used_at
                    ) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
                    ON CONFLICT(normalized_command, project_id, directory_id) DO UPDATE SET
                        command_key = excluded.command_key,
                        total_count = total_count + 1,
                        successful_count = successful_count + excluded.successful_count,
                        failed_count = failed_count + excluded.failed_count,
                        interrupted_count = interrupted_count + excluded.interrupted_count,
                        first_used_at = MIN(first_used_at, excluded.first_used_at),
                        last_used_at = MAX(last_used_at, excluded.last_used_at)
                    """, operation: "record command aggregate") { statement in
                    try bind(normalized.full, at: 1, to: statement)
                    try bind(record.commandKey, at: 2, to: statement)
                    try bind(scope.project, at: 3, to: statement)
                    try bind(scope.directory, at: 4, to: statement)
                    try bind(counts.0, at: 5, to: statement)
                    try bind(counts.1, at: 6, to: statement)
                    try bind(counts.2, at: 7, to: statement)
                    try bind(record.observedAt.timeIntervalSince1970, at: 8, to: statement)
                    try bind(record.observedAt.timeIntervalSince1970, at: 9, to: statement)
                    try stepDone(statement, operation: "record command aggregate")
                }
            }
        }
    }

    func recordTransition(
        previousCommandKey: String,
        next: BehavioralCommandRecord
    ) async throws {
        let previous = NormalizedCommand(previousCommandKey)
        let sanitized = sanitizer.sanitizeCommand(next.normalizedCommand)
        let normalizedNext = NormalizedCommand(sanitized.value)
        guard sanitized.redactionCount == 0,
              let previousKey = previous.commandKey,
              previous.full == previousCommandKey,
              !normalizedNext.full.isEmpty,
              normalizedNext.commandKey == next.commandKey else { return }

        try transaction {
            try withStatement(
                "INSERT OR IGNORE INTO behavioral_processed_transitions(event_id) VALUES (?)",
                operation: "claim behavioral transition"
            ) { statement in
                try bind(next.eventID.uuidString, at: 1, to: statement)
                try stepDone(statement, operation: "claim behavioral transition")
            }
            guard sqlite3_changes(database) == 1 else { return }
            for scope in behavioralScopes(
                projectID: next.projectID,
                directoryIdentity: next.directoryIdentity
            ) {
                try withStatement("""
                    INSERT INTO command_transitions (
                        previous_command_key, next_normalized_command, project_id,
                        directory_id, total_count, successful_next_count, last_observed_at
                    ) VALUES (?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(previous_command_key, next_normalized_command, project_id, directory_id)
                    DO UPDATE SET
                        total_count = total_count + 1,
                        successful_next_count = successful_next_count + excluded.successful_next_count,
                        last_observed_at = MAX(last_observed_at, excluded.last_observed_at)
                    """, operation: "record command transition") { statement in
                    try bind(previousKey, at: 1, to: statement)
                    try bind(normalizedNext.full, at: 2, to: statement)
                    try bind(scope.project, at: 3, to: statement)
                    try bind(scope.directory, at: 4, to: statement)
                    try bind(next.outcome == .succeeded ? Int64(1) : Int64(0), at: 5, to: statement)
                    try bind(next.observedAt.timeIntervalSince1970, at: 6, to: statement)
                    try stepDone(statement, operation: "record command transition")
                }
            }
        }
    }

    func commandAggregates(
        matchingPrefix prefix: String,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandAggregate] {
        let normalizedPrefix = NormalizedCommand(prefix).full
        guard !normalizedPrefix.isEmpty else { return [] }
        return try readCommandAggregates(
            whereClause: "normalized_command LIKE ? ESCAPE '\\'",
            firstValue: escapeLike(normalizedPrefix) + "%",
            projectID: projectID,
            directoryIdentity: directoryIdentity,
            limit: limit
        )
    }

    func mostRecentCommands(
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandAggregate] {
        try readCommandAggregates(
            whereClause: "1 = 1",
            firstValue: nil,
            projectID: projectID,
            directoryIdentity: directoryIdentity,
            limit: limit
        )
    }

    func commandTransitions(
        after previousCommandKey: String,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandTransitionAggregate] {
        let boundedLimit = min(100, max(0, limit))
        guard boundedLimit > 0 else { return [] }
        let project = sanitizedScope(projectID)
        let directory = sanitizedScope(directoryIdentity)
        var values: [CommandTransitionAggregate] = []
        try withStatement("""
            SELECT previous_command_key, next_normalized_command, project_id, directory_id,
                   total_count, successful_next_count, last_observed_at
            FROM command_transitions
            WHERE previous_command_key = ?
              AND ((project_id = '' AND directory_id = '')
                OR (project_id = ? AND directory_id = '')
                OR (project_id = ? AND directory_id = ?))
            ORDER BY total_count DESC, last_observed_at DESC, next_normalized_command ASC
            LIMIT ?
            """, operation: "query command transitions") { statement in
            try bind(previousCommandKey, at: 1, to: statement)
            try bind(project, at: 2, to: statement)
            try bind(project, at: 3, to: statement)
            try bind(directory, at: 4, to: statement)
            try bind(Int64(boundedLimit), at: 5, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(CommandTransitionAggregate(
                    previousCommandKey: columnText(statement, 0) ?? "",
                    nextNormalizedCommand: columnText(statement, 1) ?? "",
                    projectID: emptyToNil(columnText(statement, 2)),
                    directoryIdentity: emptyToNil(columnText(statement, 3)),
                    totalCount: columnInt(statement, 4) ?? 0,
                    successfulNextCount: columnInt(statement, 5) ?? 0,
                    lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            }
        }
        return values
    }

    func recordFeedback(_ record: CompletionFeedbackRecord) async throws {
        let identity = sanitizer.sanitizeCommand(record.candidateIdentity)
        guard identity.redactionCount == 0, !identity.value.isEmpty, identity.value.count <= 4_096 else {
            return
        }
        let accepted: Int64 = record.action == .accepted || record.action == .partiallyAccepted ? 1 : 0
        let dismissed: Int64 = record.action == .dismissed ? 1 : 0
        let replaced: Int64 = record.action == .replaced ? 1 : 0
        for scope in behavioralScopes(
            projectID: record.projectID,
            directoryIdentity: record.directoryIdentity
        ) {
            try withStatement("""
                INSERT INTO completion_feedback_aggregates (
                    candidate_identity, project_id, directory_id, acceptance_count,
                    dismissal_count, replacement_count, last_feedback_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(candidate_identity, project_id, directory_id) DO UPDATE SET
                    acceptance_count = acceptance_count + excluded.acceptance_count,
                    dismissal_count = dismissal_count + excluded.dismissal_count,
                    replacement_count = replacement_count + excluded.replacement_count,
                    last_feedback_at = MAX(last_feedback_at, excluded.last_feedback_at)
                """, operation: "record completion feedback") { statement in
                try bind(identity.value, at: 1, to: statement)
                try bind(scope.project, at: 2, to: statement)
                try bind(scope.directory, at: 3, to: statement)
                try bind(accepted, at: 4, to: statement)
                try bind(dismissed, at: 5, to: statement)
                try bind(replaced, at: 6, to: statement)
                try bind(record.timestamp.timeIntervalSince1970, at: 7, to: statement)
                try stepDone(statement, operation: "record completion feedback")
            }
        }
    }

    func feedbackAggregates(
        candidateIdentities: [String],
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CompletionFeedbackAggregate] {
        let identities = Array(Set(candidateIdentities.prefix(500))).sorted()
        let boundedLimit = min(500, max(0, limit))
        guard !identities.isEmpty, boundedLimit > 0 else { return [] }
        let placeholders = Array(repeating: "?", count: identities.count).joined(separator: ",")
        let project = sanitizedScope(projectID)
        let directory = sanitizedScope(directoryIdentity)
        var values: [CompletionFeedbackAggregate] = []
        try withStatement("""
            SELECT candidate_identity, project_id, directory_id, acceptance_count,
                   dismissal_count, replacement_count, last_feedback_at
            FROM completion_feedback_aggregates
            WHERE candidate_identity IN (\(placeholders))
              AND ((project_id = '' AND directory_id = '')
                OR (project_id = ? AND directory_id = '')
                OR (project_id = ? AND directory_id = ?))
            ORDER BY candidate_identity, project_id, directory_id
            LIMIT ?
            """, operation: "batch feedback lookup") { statement in
            for (offset, identity) in identities.enumerated() {
                try bind(identity, at: Int32(offset + 1), to: statement)
            }
            var index = Int32(identities.count + 1)
            try bind(project, at: index, to: statement); index += 1
            try bind(project, at: index, to: statement); index += 1
            try bind(directory, at: index, to: statement); index += 1
            try bind(Int64(boundedLimit), at: index, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(CompletionFeedbackAggregate(
                    candidateIdentity: columnText(statement, 0) ?? "",
                    projectID: emptyToNil(columnText(statement, 1)),
                    directoryIdentity: emptyToNil(columnText(statement, 2)),
                    acceptanceCount: columnInt(statement, 3) ?? 0,
                    dismissalCount: columnInt(statement, 4) ?? 0,
                    replacementCount: columnInt(statement, 5) ?? 0,
                    lastFeedbackAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            }
        }
        return values
    }

    private func readCommandAggregates(
        whereClause: String,
        firstValue: String?,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) throws -> [CommandAggregate] {
        let boundedLimit = min(300, max(0, limit))
        guard boundedLimit > 0 else { return [] }
        let project = sanitizedScope(projectID)
        let directory = sanitizedScope(directoryIdentity)
        var values: [CommandAggregate] = []
        try withStatement("""
            SELECT normalized_command, command_key, project_id, directory_id, total_count,
                   successful_count, failed_count, interrupted_count, first_used_at, last_used_at
            FROM command_aggregates
            WHERE \(whereClause)
              AND ((project_id = '' AND directory_id = '')
                OR (project_id = ? AND directory_id = '')
                OR (project_id = ? AND directory_id = ?))
            ORDER BY last_used_at DESC, total_count DESC, normalized_command ASC
            LIMIT ?
            """, operation: "query command aggregates") { statement in
            var index: Int32 = 1
            if let firstValue {
                try bind(firstValue, at: index, to: statement); index += 1
            }
            try bind(project, at: index, to: statement); index += 1
            try bind(project, at: index, to: statement); index += 1
            try bind(directory, at: index, to: statement); index += 1
            try bind(Int64(boundedLimit), at: index, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(CommandAggregate(
                    normalizedCommand: columnText(statement, 0) ?? "",
                    commandKey: columnText(statement, 1) ?? "",
                    projectID: emptyToNil(columnText(statement, 2)),
                    directoryIdentity: emptyToNil(columnText(statement, 3)),
                    totalCount: columnInt(statement, 4) ?? 0,
                    successfulCount: columnInt(statement, 5) ?? 0,
                    failedCount: columnInt(statement, 6) ?? 0,
                    interruptedCount: columnInt(statement, 7) ?? 0,
                    firstUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                    lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                ))
            }
        }
        return values
    }

    private func behavioralScopes(
        projectID: String?,
        directoryIdentity: String?
    ) -> [(project: String, directory: String)] {
        let project = sanitizedScope(projectID)
        let directory = sanitizedScope(directoryIdentity)
        var scopes = [(project: "", directory: "")]
        if !project.isEmpty { scopes.append((project: project, directory: "")) }
        if !directory.isEmpty { scopes.append((project: project, directory: directory)) }
        return scopes
    }

    private func sanitizedScope(_ value: String?) -> String {
        guard let value else { return "" }
        let sanitized = sanitizer.sanitizeCommand(value)
        return sanitized.redactionCount == 0 ? String(sanitized.value.prefix(4_096)) : ""
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
