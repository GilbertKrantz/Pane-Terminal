import Foundation

@MainActor
final class RuntimeStateSettings: ObservableObject {
    @Published var persistenceEnabled: Bool { didSet { save() } }
    @Published var commandHistoryEnabled: Bool { didSet { save() } }
    @Published var visibleSessionRecoveryEnabled: Bool { didSet { save() } }
    @Published var predictionContextEnabled: Bool { didSet { save() } }
    @Published var outputSummariesEnabled: Bool { didSet { save() } }
    @Published var filePathCollectionEnabled: Bool { didSet { save() } }
    @Published var restoreAcrossWorkspacesEnabled: Bool { didSet { save() } }
    @Published var maximumRestoredSessions: Int { didSet { save() } }
    @Published var maximumRestoredCommands: Int { didSet { save() } }
    @Published var maximumRestoredOutputBytes: Int { didSet { save() } }

    private let defaults: UserDefaults
    private let keyPrefix = "runtimeState."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let commandHistoryKey = keyPrefix + "commandHistoryEnabled"
        let visibleRecoveryKey = keyPrefix + "visibleSessionRecoveryEnabled"
        let predictionContextKey = keyPrefix + "predictionContextEnabled"
        let legacyValue = defaults.object(forKey: keyPrefix + "predictionHistoryEnabled") as? Bool
        let storedCommandHistory = defaults.object(forKey: commandHistoryKey) as? Bool
        let storedVisibleRecovery = defaults.object(forKey: visibleRecoveryKey) as? Bool
        let storedPredictionContext = defaults.object(forKey: predictionContextKey) as? Bool
        persistenceEnabled = defaults.object(forKey: keyPrefix + "persistenceEnabled") as? Bool ?? true
        let migratedValue = legacyValue ?? true
        commandHistoryEnabled = storedCommandHistory ?? migratedValue
        visibleSessionRecoveryEnabled = storedVisibleRecovery ?? migratedValue
        predictionContextEnabled = storedPredictionContext ?? migratedValue
        outputSummariesEnabled = defaults.object(forKey: keyPrefix + "outputSummariesEnabled") as? Bool ?? false
        filePathCollectionEnabled = defaults.object(forKey: keyPrefix + "filePathCollectionEnabled") as? Bool ?? true
        restoreAcrossWorkspacesEnabled = defaults.object(forKey: keyPrefix + "restoreAcrossWorkspacesEnabled") as? Bool ?? false
        maximumRestoredSessions = max(
            1,
            defaults.object(forKey: keyPrefix + "maximumRestoredSessions") as? Int ?? 3
        )
        maximumRestoredCommands = max(
            1,
            defaults.object(forKey: keyPrefix + "maximumRestoredCommands") as? Int ?? 200
        )
        maximumRestoredOutputBytes = max(
            0,
            defaults.object(forKey: keyPrefix + "maximumRestoredOutputBytes") as? Int
                ?? 2 * 1_024 * 1_024
        )

        // Materialize the split keys once so later changes remain independent
        // from the legacy aggregate preference.
        if storedCommandHistory == nil { defaults.set(commandHistoryEnabled, forKey: commandHistoryKey) }
        if storedVisibleRecovery == nil { defaults.set(visibleSessionRecoveryEnabled, forKey: visibleRecoveryKey) }
        if storedPredictionContext == nil { defaults.set(predictionContextEnabled, forKey: predictionContextKey) }
    }

    var configuration: RuntimeStateConfiguration {
        RuntimeStateConfiguration(
            persistenceEnabled: persistenceEnabled,
            commandHistoryEnabled: commandHistoryEnabled,
            visibleSessionRecoveryEnabled: visibleSessionRecoveryEnabled,
            predictionContextEnabled: predictionContextEnabled,
            outputSummariesEnabled: outputSummariesEnabled,
            filePathCollectionEnabled: filePathCollectionEnabled,
            restoreAcrossWorkspacesEnabled: restoreAcrossWorkspacesEnabled,
            maximumRestoredSessions: maximumRestoredSessions,
            maximumRestoredCommands: maximumRestoredCommands,
            maximumRestoredOutputBytes: maximumRestoredOutputBytes
        )
    }

    private func save() {
        defaults.set(persistenceEnabled, forKey: keyPrefix + "persistenceEnabled")
        defaults.set(commandHistoryEnabled, forKey: keyPrefix + "commandHistoryEnabled")
        defaults.set(visibleSessionRecoveryEnabled, forKey: keyPrefix + "visibleSessionRecoveryEnabled")
        defaults.set(predictionContextEnabled, forKey: keyPrefix + "predictionContextEnabled")
        defaults.set(outputSummariesEnabled, forKey: keyPrefix + "outputSummariesEnabled")
        defaults.set(filePathCollectionEnabled, forKey: keyPrefix + "filePathCollectionEnabled")
        defaults.set(restoreAcrossWorkspacesEnabled, forKey: keyPrefix + "restoreAcrossWorkspacesEnabled")
        defaults.set(maximumRestoredSessions, forKey: keyPrefix + "maximumRestoredSessions")
        defaults.set(maximumRestoredCommands, forKey: keyPrefix + "maximumRestoredCommands")
        defaults.set(maximumRestoredOutputBytes, forKey: keyPrefix + "maximumRestoredOutputBytes")
    }
}
