import Foundation

@MainActor
final class RuntimeStateSettings: ObservableObject {
    @Published var persistenceEnabled: Bool { didSet { save() } }
    @Published var predictionHistoryEnabled: Bool { didSet { save() } }
    @Published var outputSummariesEnabled: Bool { didSet { save() } }
    @Published var filePathCollectionEnabled: Bool { didSet { save() } }

    private let defaults: UserDefaults
    private let keyPrefix = "runtimeState."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            keyPrefix + "persistenceEnabled": true,
            keyPrefix + "predictionHistoryEnabled": true,
            keyPrefix + "outputSummariesEnabled": true,
            keyPrefix + "filePathCollectionEnabled": true
        ])
        persistenceEnabled = defaults.bool(forKey: keyPrefix + "persistenceEnabled")
        predictionHistoryEnabled = defaults.bool(forKey: keyPrefix + "predictionHistoryEnabled")
        outputSummariesEnabled = defaults.bool(forKey: keyPrefix + "outputSummariesEnabled")
        filePathCollectionEnabled = defaults.bool(forKey: keyPrefix + "filePathCollectionEnabled")
    }

    var configuration: RuntimeStateConfiguration {
        RuntimeStateConfiguration(
            persistenceEnabled: persistenceEnabled,
            predictionHistoryEnabled: predictionHistoryEnabled,
            outputSummariesEnabled: outputSummariesEnabled,
            filePathCollectionEnabled: filePathCollectionEnabled
        )
    }

    private func save() {
        defaults.set(persistenceEnabled, forKey: keyPrefix + "persistenceEnabled")
        defaults.set(predictionHistoryEnabled, forKey: keyPrefix + "predictionHistoryEnabled")
        defaults.set(outputSummariesEnabled, forKey: keyPrefix + "outputSummariesEnabled")
        defaults.set(filePathCollectionEnabled, forKey: keyPrefix + "filePathCollectionEnabled")
    }
}
