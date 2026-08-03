import Foundation

protocol PanePreferencesPersisting: Sendable {
    func load() throws -> PanePreferencesSnapshot
    func save(_ snapshot: PanePreferencesSnapshot) throws
    func reset() throws
}

enum PanePreferencesStoreError: Error { case encodingFailed }

final class PanePreferencesStore: PanePreferencesPersisting, @unchecked Sendable {
    static let standard = PanePreferencesStore(defaults: .standard)
    static let snapshotKey = "pane.preferences.snapshot"
    static let migrationKey = "pane.preferences.migration.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private(set) var fallbackDiagnostic: String?

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() throws -> PanePreferencesSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let data = defaults.data(forKey: Self.snapshotKey) {
            do {
                let value = try JSONDecoder().decode(PanePreferencesSnapshot.self, from: data).validated()
                fallbackDiagnostic = nil
                return value
            } catch {
                fallbackDiagnostic = "Preferences were unreadable and were safely restored."
            }
        }
        let value = migrateLegacy().validated()
        try saveUnlocked(value)
        defaults.set(true, forKey: Self.migrationKey)
        return value
    }

    func save(_ snapshot: PanePreferencesSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        try saveUnlocked(snapshot.validated())
    }

    func reset() throws {
        lock.lock(); defer { lock.unlock() }
        try saveUnlocked(.defaults)
    }

    private func saveUnlocked(_ snapshot: PanePreferencesSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: Self.snapshotKey)
    }

    private func migrateLegacy() -> PanePreferencesSnapshot {
        var snapshot = PanePreferencesSnapshot.defaults
        let prefix = "runtimeState."
        func bool(_ key: String) -> Bool? { defaults.object(forKey: prefix + key) as? Bool }
        func int(_ key: String) -> Int? { defaults.object(forKey: prefix + key) as? Int }
        let legacyPrediction = bool("predictionHistoryEnabled")
        snapshot.history.persistenceEnabled = bool("persistenceEnabled") ?? snapshot.history.persistenceEnabled
        snapshot.history.commandHistoryEnabled = bool("commandHistoryEnabled") ?? legacyPrediction ?? snapshot.history.commandHistoryEnabled
        snapshot.history.visibleSessionRecoveryEnabled = bool("visibleSessionRecoveryEnabled") ?? legacyPrediction ?? snapshot.history.visibleSessionRecoveryEnabled
        snapshot.history.predictionContextEnabled = bool("predictionContextEnabled") ?? legacyPrediction ?? snapshot.history.predictionContextEnabled
        snapshot.history.outputSummariesEnabled = bool("outputSummariesEnabled") ?? snapshot.history.outputSummariesEnabled
        snapshot.history.filePathCollectionEnabled = bool("filePathCollectionEnabled") ?? snapshot.history.filePathCollectionEnabled
        snapshot.history.restoreAcrossWorkspacesEnabled = bool("restoreAcrossWorkspacesEnabled") ?? snapshot.history.restoreAcrossWorkspacesEnabled
        snapshot.history.maximumRestoredSessions = int("maximumRestoredSessions") ?? snapshot.history.maximumRestoredSessions
        snapshot.history.maximumRestoredCommands = int("maximumRestoredCommands") ?? snapshot.history.maximumRestoredCommands
        snapshot.history.maximumRestoredOutputBytes = int("maximumRestoredOutputBytes") ?? snapshot.history.maximumRestoredOutputBytes
        return snapshot
    }
}
