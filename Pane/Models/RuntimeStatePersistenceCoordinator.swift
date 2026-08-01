import Foundation

enum PersistenceDiagnosticStatus: String, Codable, Sendable, Equatable {
    case ready
    case memoryOnly
    case recovered
    case closed
}

/// Sanitized workspace-wide persistence health. It intentionally contains no
/// paths beyond a local recovery filename and no command/session content.
struct PersistenceDiagnostic: Codable, Sendable, Equatable {
    let status: PersistenceDiagnosticStatus
    let failureCategory: RuntimeStatePersistenceFailureCategory?
    let schemaVersion: Int
    let recoveryFileName: String?
    let message: String?
}

/// Owns the single durable handle and memory fallback used by every terminal
/// session in one app launch. Session-local RuntimeStateController instances
/// remain responsible for privacy configuration and current-session identity.
actor RuntimeStatePersistenceCoordinator {
    nonisolated let databaseURL: URL
    nonisolated let ephemeralStore: InMemoryRuntimeStateStore

    private let retentionPolicy: RuntimeStateRetentionPolicy
    private var durableStore: SQLiteRuntimeStateStore?
    private var preparationTask: Task<[RuntimeSession], Error>?
    private var maintenanceTask: Task<Void, Never>?
    private var didPrepareCurrentLaunch = false
    private var isClosed = false
    private var openFailure: Error?
    private var recoveryFileURL: URL?
    private var persistenceDiagnostic = PersistenceDiagnostic(
        status: .ready,
        failureCategory: nil,
        schemaVersion: 5,
        recoveryFileName: nil,
        message: nil
    )

    init(
        databaseURL: URL,
        ephemeralStore: InMemoryRuntimeStateStore = InMemoryRuntimeStateStore(),
        retentionPolicy: RuntimeStateRetentionPolicy = .default
    ) {
        self.databaseURL = databaseURL
        self.ephemeralStore = ephemeralStore
        self.retentionPolicy = retentionPolicy
    }

    func store() throws -> SQLiteRuntimeStateStore {
        if isClosed { throw RuntimeStateStoreError.closed }
        if let durableStore { return durableStore }
        if let openFailure { throw openFailure }

        do {
            let store = try SQLiteRuntimeStateStore(
                databaseURL: databaseURL,
                retentionPolicy: retentionPolicy
            )
            durableStore = store
            persistenceDiagnostic = PersistenceDiagnostic(
                status: recoveryFileURL == nil ? .ready : .recovered,
                failureCategory: nil,
                schemaVersion: 5,
                recoveryFileName: recoveryFileURL?.lastPathComponent,
                message: recoveryFileURL == nil
                    ? nil
                    : "Pane recovered an unreadable local database and kept a sanitized recovery reference."
            )
            return store
        } catch {
            guard Self.failureCategory(for: error) == .corruption,
                  FileManager.default.fileExists(atPath: databaseURL.path) else {
                if Self.shouldCacheOpenFailure(error) {
                    openFailure = error
                }
                persistenceDiagnostic = Self.memoryOnlyDiagnostic(for: error)
                throw error
            }

            do {
                recoveryFileURL = try quarantineCorruptDatabase()
                let store = try SQLiteRuntimeStateStore(
                    databaseURL: databaseURL,
                    retentionPolicy: retentionPolicy
                )
                durableStore = store
                persistenceDiagnostic = PersistenceDiagnostic(
                    status: .recovered,
                    failureCategory: .corruption,
                    schemaVersion: 5,
                    recoveryFileName: recoveryFileURL?.lastPathComponent,
                    message: "Pane recovered from an unreadable local database. The recovery file remains local."
                )
                return store
            } catch {
                openFailure = error
                persistenceDiagnostic = Self.memoryOnlyDiagnostic(for: error)
                throw error
            }
        }
    }

    /// Marks sessions from the prior process lifetime interrupted exactly once.
    /// All tabs created later in this launch share the completed preparation
    /// and therefore cannot mark one another interrupted.
    func prepareCurrentLaunch() async throws -> [RuntimeSession] {
        if didPrepareCurrentLaunch { return [] }
        if let preparationTask { return try await preparationTask.value }
        let store = try store()
        let task = Task {
            try await store.markActiveSessionsInterrupted(excluding: nil)
        }
        preparationTask = task
        do {
            let interrupted = try await task.value
            didPrepareCurrentLaunch = true
            preparationTask = nil
            return interrupted
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func diagnostic() -> PersistenceDiagnostic {
        persistenceDiagnostic
    }

    func scheduleMaintenance() {
        guard maintenanceTask == nil, let durableStore, !isClosed else { return }
        maintenanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? await durableStore.applyRetentionPolicy()
            await self?.maintenanceDidFinish()
        }
    }

    func recoveryFile() -> URL? {
        recoveryFileURL
    }

    func clearRecoveryFile() throws {
        guard let recoveryFileURL else { return }
        for url in Self.databaseFamily(for: recoveryFileURL) where
            FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        self.recoveryFileURL = nil
        persistenceDiagnostic = PersistenceDiagnostic(
            status: durableStore == nil ? .memoryOnly : .ready,
            failureCategory: nil,
            schemaVersion: 5,
            recoveryFileName: nil,
            message: nil
        )
    }

    func shutdown() async {
        guard !isClosed else { return }
        isClosed = true
        preparationTask?.cancel()
        preparationTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        if let durableStore {
            await durableStore.close()
            self.durableStore = nil
        }
        persistenceDiagnostic = PersistenceDiagnostic(
            status: .closed,
            failureCategory: nil,
            schemaVersion: 5,
            recoveryFileName: recoveryFileURL?.lastPathComponent,
            message: nil
        )
    }

    private func quarantineCorruptDatabase() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recoveryURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(
                "runtime-state-recovery-\(formatter.string(from: Date()))-\(UUID().uuidString).sqlite"
            )
        let sourceFamily = Self.databaseFamily(for: databaseURL)
        let destinationFamily = Self.databaseFamily(for: recoveryURL)
        for (source, destination) in zip(sourceFamily, destinationFamily) where
            FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return recoveryURL
    }

    private func maintenanceDidFinish() {
        maintenanceTask = nil
    }

    private static func databaseFamily(for url: URL) -> [URL] {
        [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ]
    }

    private static func failureCategory(for error: Error) -> RuntimeStatePersistenceFailureCategory {
        if let storeError = error as? RuntimeStateStoreError {
            return storeError.category
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain {
            switch cocoaError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permission
            default:
                return .io
            }
        }
        return .io
    }

    private static func shouldCacheOpenFailure(_ error: Error) -> Bool {
        switch failureCategory(for: error) {
        case .unsupportedSchemaVersion, .permission, .corruption, .closed:
            true
        case .busyLocked, .io:
            false
        }
    }

    private static func memoryOnlyDiagnostic(for error: Error) -> PersistenceDiagnostic {
        let category = failureCategory(for: error)
        let schemaVersion: Int
        if let storeError = error as? RuntimeStateStoreError,
           case .unsupportedSchemaVersion(let found, _) = storeError {
            schemaVersion = found
        } else {
            schemaVersion = 5
        }
        let message: String
        switch category {
        case .unsupportedSchemaVersion:
            message = "The local database uses a newer schema and was preserved unchanged."
        case .busyLocked:
            message = "The local database remained busy; Pane is using memory-only history."
        case .permission:
            message = "The local database is not writable; Pane is using memory-only history."
        case .corruption:
            message = "The local database could not be recovered; Pane is using memory-only history."
        case .io, .closed:
            message = "Session history is unavailable; Pane is using memory-only history."
        }
        return PersistenceDiagnostic(
            status: .memoryOnly,
            failureCategory: category,
            schemaVersion: schemaVersion,
            recoveryFileName: nil,
            message: message
        )
    }
}
