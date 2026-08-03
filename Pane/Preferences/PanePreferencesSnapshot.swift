import Foundation

enum PersistedNewTabDirectoryPolicy: String, Codable, CaseIterable, Sendable {
    case selectedTabDirectory, homeDirectory, customDirectory
}

enum AppAppearanceMode: String, Codable, CaseIterable, Sendable { case system, light, dark }
enum InterfaceDensity: String, Codable, CaseIterable, Sendable { case compact, comfortable }
enum BlockOutputHeight: String, Codable, CaseIterable, Sendable { case compact, standard, large }
enum OptionKeyBehaviour: String, Codable, CaseIterable, Sendable { case normal, meta }
enum ShellSelection: String, Codable, CaseIterable, Sendable { case systemLoginShell, customExecutable }

struct GeneralPreferences: Codable, Equatable, Sendable {
    var defaultInputMode: InputMode
    var restoreWorkspaceAtLaunch: Bool
    var newTabDirectoryPolicy: PersistedNewTabDirectoryPolicy
    var customDefaultDirectoryPath: String?
    var confirmClosingActiveProcesses: Bool
    var focusComposerWhenSelectingBlocksTab: Bool
    static let defaults = Self(defaultInputMode: .blocks, restoreWorkspaceAtLaunch: true,
        newTabDirectoryPolicy: .selectedTabDirectory, customDefaultDirectoryPath: nil,
        confirmClosingActiveProcesses: true, focusComposerWhenSelectingBlocksTab: true)
}

struct TerminalFontPreference: Codable, Equatable, Sendable {
    var postScriptName: String?
    var size: Double
}

struct AppearancePreferences: Codable, Equatable, Sendable {
    var mode: AppAppearanceMode
    var terminalFont: TerminalFontPreference
    var interfaceDensity: InterfaceDensity
    var blockOutputHeight: BlockOutputHeight
    static let defaults = Self(mode: .system, terminalFont: .init(postScriptName: nil, size: 13),
        interfaceDensity: .comfortable, blockOutputHeight: .standard)
}

struct TerminalPreferences: Codable, Equatable, Sendable {
    var shellSelection: ShellSelection
    var customShellPath: String?
    var launchAsLoginShell: Bool
    var optionKeyBehaviour: OptionKeyBehaviour
    var scrollbackLimit: Int
    static let defaults = Self(shellSelection: .systemLoginShell, customShellPath: nil,
        launchAsLoginShell: true, optionKeyBehaviour: .normal, scrollbackLimit: 10_000)
}

struct CompletionSources: Codable, Equatable, Sendable {
    var shell = true; var filesAndDirectories = true; var executables = true
    var commandHistory = true; var projectContext = true; var previousCommandTransitions = true
    static let defaults = Self()
}

struct CompletionPreferences: Codable, Equatable, Sendable {
    var enabled: Bool
    var resultLimit: Int
    var sources: CompletionSources
    var nextCommandSuggestionsEnabled: Bool
    var localLearningEnabled: Bool
    static let defaults = Self(enabled: true, resultLimit: 8, sources: .defaults,
        nextCommandSuggestionsEnabled: true, localLearningEnabled: true)
}

struct HistoryPreferences: Codable, Equatable, Sendable {
    var persistenceEnabled: Bool; var commandHistoryEnabled: Bool
    var visibleSessionRecoveryEnabled: Bool; var predictionContextEnabled: Bool
    var outputSummariesEnabled: Bool; var filePathCollectionEnabled: Bool
    var restoreAcrossWorkspacesEnabled: Bool
    var maximumRestoredSessions: Int; var maximumRestoredCommands: Int; var maximumRestoredOutputBytes: Int
    static let defaults = Self(persistenceEnabled: true, commandHistoryEnabled: true,
        visibleSessionRecoveryEnabled: true, predictionContextEnabled: true,
        outputSummariesEnabled: false, filePathCollectionEnabled: true,
        restoreAcrossWorkspacesEnabled: false, maximumRestoredSessions: 3,
        maximumRestoredCommands: 200, maximumRestoredOutputBytes: 2 * 1_024 * 1_024)

    var runtimeConfiguration: RuntimeStateConfiguration {
        .init(persistenceEnabled: persistenceEnabled, commandHistoryEnabled: commandHistoryEnabled,
            visibleSessionRecoveryEnabled: visibleSessionRecoveryEnabled,
            predictionContextEnabled: predictionContextEnabled, outputSummariesEnabled: outputSummariesEnabled,
            filePathCollectionEnabled: filePathCollectionEnabled,
            restoreAcrossWorkspacesEnabled: restoreAcrossWorkspacesEnabled,
            maximumRestoredSessions: maximumRestoredSessions,
            maximumRestoredCommands: maximumRestoredCommands,
            maximumRestoredOutputBytes: maximumRestoredOutputBytes)
    }
}

struct PanePreferencesSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var general: GeneralPreferences; var appearance: AppearancePreferences
    var terminal: TerminalPreferences; var completions: CompletionPreferences; var history: HistoryPreferences
    static let defaults = Self(schemaVersion: currentSchemaVersion, general: .defaults,
        appearance: .defaults, terminal: .defaults, completions: .defaults, history: .defaults)

    func validated(fileManager: FileManager = .default) -> Self {
        var value = self
        value.schemaVersion = Self.currentSchemaVersion
        value.appearance.terminalFont.size = min(24, max(11, value.appearance.terminalFont.size))
        if ![4, 8, 12].contains(value.completions.resultLimit) { value.completions.resultLimit = 8 }
        if ![5_000, 10_000, 50_000].contains(value.terminal.scrollbackLimit) { value.terminal.scrollbackLimit = 10_000 }
        value.history.maximumRestoredSessions = min(10, max(1, value.history.maximumRestoredSessions))
        value.history.maximumRestoredCommands = min(1_000, max(25, value.history.maximumRestoredCommands))
        if ![0, 512 * 1_024, 2 * 1_024 * 1_024, 8 * 1_024 * 1_024].contains(value.history.maximumRestoredOutputBytes) {
            value.history.maximumRestoredOutputBytes = HistoryPreferences.defaults.maximumRestoredOutputBytes
        }
        if let path = value.general.customDefaultDirectoryPath {
            var directory: ObjCBool = false
            if !fileManager.fileExists(atPath: path, isDirectory: &directory) || !directory.boolValue {
                value.general.customDefaultDirectoryPath = nil
            } else {
                value.general.customDefaultDirectoryPath = URL(fileURLWithPath: path).standardizedFileURL.path
            }
        }
        return value
    }
}
