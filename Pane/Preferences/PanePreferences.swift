import Combine
import Foundation

enum PreferenceApplicationImpact: Equatable, Sendable { case immediate, newSessions, shellRestart, applicationRelaunch }
enum PanePreferenceSection: Sendable { case general, appearance, terminal, completions, history }
enum PanePreferenceKey: Hashable, Sendable {
    case defaultInputMode, restoreWorkspaceAtLaunch, newTabDirectoryPolicy, confirmClosingActiveProcesses, focusComposerWhenSelectingBlocksTab
    case appearanceMode, terminalFont, terminalFontSize, interfaceDensity, blockOutputHeight
    case shellExecutable, launchAsLoginShell, optionKeyBehaviour, scrollbackLimit
    case completionsEnabled, completionResultLimit, completionSources, nextCommandSuggestionsEnabled, localCompletionLearningEnabled
    case historyConfiguration
}

@MainActor
final class PanePreferences: ObservableObject {
    @Published private(set) var snapshot: PanePreferencesSnapshot
    @Published private(set) var persistenceDiagnostic: String?
    private let store: PanePreferencesPersisting
    var onChange: ((PanePreferencesSnapshot, Set<PanePreferenceKey>) -> Void)?

    init(store: PanePreferencesPersisting = PanePreferencesStore.standard) {
        self.store = store
        do { snapshot = try store.load() } catch {
            snapshot = .defaults
            persistenceDiagnostic = "Preferences could not be loaded: \(error.localizedDescription)"
        }
        if let concrete = store as? PanePreferencesStore { persistenceDiagnostic = concrete.fallbackDiagnostic }
    }

    func update<Value>(_ keyPath: WritableKeyPath<PanePreferencesSnapshot, Value>, to value: Value,
                       key: PanePreferenceKey? = nil) {
        snapshot[keyPath: keyPath] = value
        snapshot = snapshot.validated()
        do { try store.save(snapshot); persistenceDiagnostic = nil }
        catch { persistenceDiagnostic = "This change is active but could not be saved: \(error.localizedDescription)" }
        if let key { onChange?(snapshot, [key]) }
    }

    func resetSection(_ section: PanePreferenceSection) {
        switch section {
        case .general: snapshot.general = .defaults
        case .appearance: snapshot.appearance = .defaults
        case .terminal: snapshot.terminal = .defaults
        case .completions: snapshot.completions = .defaults
        case .history: snapshot.history = .defaults
        }
        persistAndPublish(Set(PanePreferenceKey.allFor(section)))
    }

    func resetAll() { snapshot = .defaults; persistAndPublish(Set(PanePreferenceKey.allCases)) }
    private func persistAndPublish(_ keys: Set<PanePreferenceKey>) {
        do { try store.save(snapshot); persistenceDiagnostic = nil } catch { persistenceDiagnostic = error.localizedDescription }
        onChange?(snapshot, keys)
    }
}

private extension PanePreferenceKey {
    static let allCases: [Self] = [.defaultInputMode,.restoreWorkspaceAtLaunch,.newTabDirectoryPolicy,.confirmClosingActiveProcesses,.focusComposerWhenSelectingBlocksTab,.appearanceMode,.terminalFont,.terminalFontSize,.interfaceDensity,.blockOutputHeight,.shellExecutable,.launchAsLoginShell,.optionKeyBehaviour,.scrollbackLimit,.completionsEnabled,.completionResultLimit,.completionSources,.nextCommandSuggestionsEnabled,.localCompletionLearningEnabled,.historyConfiguration]
    static func allFor(_ section: PanePreferenceSection) -> [Self] {
        switch section {
        case .general: return Array(allCases[0...4]); case .appearance: return Array(allCases[5...9])
        case .terminal: return Array(allCases[10...13]); case .completions: return Array(allCases[14...18]); case .history: return [.historyConfiguration]
        }
    }
}
