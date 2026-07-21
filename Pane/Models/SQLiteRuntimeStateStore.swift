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
            initial_working_directory, started_at, last_active_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            workspace_id = excluded.workspace_id,
            repository_id = excluded.repository_id,
            shell = excluded.shell,
            initial_working_directory = excluded.initial_working_directory,
            last_active_at = excluded.last_active_at
        """
        try withStatement(sql, operation: "start session") { statement in
            try bind(session.id.uuidString, at: 1, to: statement)
            try bind(session.workspaceID, at: 2, to: statement)
            try bind(session.repositoryID, at: 3, to: statement)
            try bind(sanitizer.sanitizeCommand(session.shell).value, at: 4, to: statement)
            try bind(sanitizer.sanitizeCommand(session.initialWorkingDirectory).value, at: 5, to: statement)
            try bind(milliseconds(session.startedAt), at: 6, to: statement)
            try bind(milliseconds(session.lastActiveAt), at: 7, to: statement)
            try stepDone(statement, operation: "start session")
        }
    }

    func persistCommandEvent(_ event: PersistedCommandEvent) async throws {
        let command = sanitizer.sanitizeCommand(event.command)
        let output = event.sanitizedOutputSummary.map(sanitizer.sanitizeOutput)
        let error = event.sanitizedErrorSummary.map(sanitizer.sanitizeError)
        let sql = """
        INSERT INTO command_events (
            session_id, timestamp, working_directory, command, exit_code,
            duration_ms, sanitized_output_summary, sanitized_error_summary,
            prediction_source, prediction_action
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql, operation: "persist command") { statement in
            try bind(event.sessionID.uuidString, at: 1, to: statement)
            try bind(milliseconds(event.timestamp), at: 2, to: statement)
            try bind(sanitizer.sanitizeCommand(event.workingDirectory).value, at: 3, to: statement)
            try bind(command.value, at: 4, to: statement)
            try bind(event.exitCode.map(Int64.init), at: 5, to: statement)
            try bind(event.durationMilliseconds.map(Int64.init), at: 6, to: statement)
            try bind(output.map { String($0.value.prefix(1_000)) }, at: 7, to: statement)
            try bind(error.map { String($0.value.prefix(1_000)) }, at: 8, to: statement)
            try bind(event.predictionSource, at: 9, to: statement)
            try bind(event.predictionAction, at: 10, to: statement)
            try stepDone(statement, operation: "persist command")
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
        limit: Int
    ) async throws -> PersistedRuntimeContext {
        let boundedLimit = max(0, limit)
        var sessions: [RuntimeSession] = []
        var sessionIDs: [String] = []
        let sessionSQL = """
        SELECT id, workspace_id, repository_id, shell,
               initial_working_directory, started_at, last_active_at
        FROM runtime_sessions
        WHERE (? IS NULL OR workspace_id = ?)
          AND (? IS NULL OR repository_id = ?)
        ORDER BY last_active_at DESC
        """
        try withStatement(sessionSQL, operation: "load sessions") { statement in
            try bind(workspaceID, at: 1, to: statement)
            try bind(workspaceID, at: 2, to: statement)
            try bind(repositoryID, at: 3, to: statement)
            try bind(repositoryID, at: 4, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = columnText(statement, 0),
                      let id = UUID(uuidString: idText),
                      let shell = columnText(statement, 3),
                      let directory = columnText(statement, 4) else { continue }
                sessionIDs.append(idText)
                sessions.append(RuntimeSession(
                    id: id,
                    workspaceID: columnText(statement, 1),
                    repositoryID: columnText(statement, 2),
                    shell: shell,
                    initialWorkingDirectory: directory,
                    startedAt: date(sqlite3_column_int64(statement, 5)),
                    lastActiveAt: date(sqlite3_column_int64(statement, 6))
                ))
            }
        }

        guard !sessionIDs.isEmpty, boundedLimit > 0 else {
            return PersistedRuntimeContext(sessions: sessions, commandEvents: [], features: [])
        }

        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        var events: [PersistedCommandEvent] = []
        let eventSQL = """
        SELECT session_id, timestamp, working_directory, command, exit_code,
               duration_ms, sanitized_output_summary, sanitized_error_summary,
               prediction_source, prediction_action
        FROM command_events
        WHERE session_id IN (\(placeholders))
        ORDER BY timestamp DESC LIMIT ?
        """
        try withStatement(eventSQL, operation: "load commands") { statement in
            try bindIdentifiers(sessionIDs, to: statement)
            try bind(Int64(boundedLimit), at: Int32(sessionIDs.count + 1), to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionText = columnText(statement, 0),
                      let sessionID = UUID(uuidString: sessionText),
                      let directory = columnText(statement, 2),
                      let command = columnText(statement, 3) else { continue }
                events.append(PersistedCommandEvent(
                    sessionID: sessionID,
                    timestamp: date(sqlite3_column_int64(statement, 1)),
                    workingDirectory: directory,
                    command: command,
                    exitCode: columnInt(statement, 4),
                    durationMilliseconds: columnInt(statement, 5),
                    sanitizedOutputSummary: columnText(statement, 6),
                    sanitizedErrorSummary: columnText(statement, 7),
                    predictionSource: columnText(statement, 8),
                    predictionAction: columnText(statement, 9)
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
            commandEvents: events,
            features: features
        )
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
            try execute("DELETE FROM runtime_features")
            try execute("DELETE FROM command_events")
            try execute("DELETE FROM runtime_sessions")
        }
    }

    func applyRetentionPolicy() async throws {
        let cutoff = milliseconds(Date().addingTimeInterval(-retentionPolicy.maximumAge))
        try execute("DELETE FROM command_events WHERE timestamp < \(cutoff)")
        try execute("DELETE FROM runtime_features WHERE timestamp < \(cutoff)")

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
        guard sqlite3_column_int64(statement, 0) == 0 else { return }

        try run("BEGIN IMMEDIATE", operation: "begin migration")
        do {
            try run("""
            CREATE TABLE runtime_sessions (
                id TEXT PRIMARY KEY,
                workspace_id TEXT,
                repository_id TEXT,
                shell TEXT NOT NULL,
                initial_working_directory TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                last_active_at INTEGER NOT NULL
            )
            """, operation: "create sessions table")
            try run("""
            CREATE TABLE command_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
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
            try run("PRAGMA user_version = 1", operation: "set schema version")
            try run("COMMIT", operation: "commit migration")
        } catch {
            try? run("ROLLBACK", operation: "rollback migration")
            throw error
        }
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
