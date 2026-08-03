import AppKit
import SwiftUI

struct PaneSettingsView: View {
    enum Destination: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance", terminal = "Terminal"
        case completions = "Completions", history = "History & Privacy", advanced = "Advanced"
        var id: Self { self }
        var icon: String { switch self {
        case .general: "gear"; case .appearance: "paintbrush"; case .terminal: "apple.terminal"
        case .completions: "text.badge.checkmark"; case .history: "hand.raised"; case .advanced: "wrench.and.screwdriver"
        } }
    }
    @ObservedObject var preferences: PanePreferences
    @ObservedObject var dataManager: PaneLocalDataManager
    @State private var destination: Destination? = .general

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $destination) { item in Label(item.rawValue, systemImage: item.icon) }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView { page.padding(24).frame(maxWidth: 620, alignment: .leading) }
                .navigationTitle(destination?.rawValue ?? "Settings")
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    @ViewBuilder private var page: some View {
        switch destination ?? .general {
        case .general: GeneralPreferencesPage(preferences: preferences)
        case .appearance: AppearancePreferencesPage(preferences: preferences)
        case .terminal: TerminalPreferencesPage(preferences: preferences)
        case .completions: CompletionPreferencesPage(preferences: preferences)
        case .history: HistoryPreferencesPage(preferences: preferences, dataManager: dataManager)
        case .advanced: AdvancedPreferencesPage(preferences: preferences, dataManager: dataManager)
        }
    }
}

private struct GeneralPreferencesPage: View {
    @ObservedObject var preferences: PanePreferences
    var body: some View { Form {
        Section("Startup") { Toggle("Restore workspace at launch", isOn: bind(\.general.restoreWorkspaceAtLaunch, .restoreWorkspaceAtLaunch)) }
        Section("New tabs") {
            Picker("Default input mode", selection: bind(\.general.defaultInputMode, .defaultInputMode)) { Text("Blocks").tag(InputMode.blocks); Text("Terminal").tag(InputMode.terminal) }
            Text("Applies to new tabs").font(.caption).foregroundStyle(.secondary)
            Picker("Open in", selection: bind(\.general.newTabDirectoryPolicy, .newTabDirectoryPolicy)) {
                Text("Current tab directory").tag(PersistedNewTabDirectoryPolicy.selectedTabDirectory)
                Text("Home directory").tag(PersistedNewTabDirectoryPolicy.homeDirectory)
                Text("Custom directory").tag(PersistedNewTabDirectoryPolicy.customDirectory)
            }
            if preferences.snapshot.general.newTabDirectoryPolicy == .customDirectory {
                HStack {
                    Text(preferences.snapshot.general.customDefaultDirectoryPath ?? "Home directory")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseDirectory() }
                }
                if preferences.snapshot.general.customDefaultDirectoryPath == nil {
                    Text("The selected directory is unavailable; new tabs will open in Home.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Interaction") {
            Toggle("Confirm before closing active processes", isOn: bind(\.general.confirmClosingActiveProcesses, .confirmClosingActiveProcesses))
            Toggle("Focus composer when selecting a Blocks tab", isOn: bind(\.general.focusComposerWhenSelectingBlocksTab, .focusComposerWhenSelectingBlocksTab))
        }
    }.formStyle(.grouped) }
    private func bind<T>(_ path: WritableKeyPath<PanePreferencesSnapshot,T>, _ key: PanePreferenceKey) -> Binding<T> {
        Binding(get: { preferences.snapshot[keyPath:path] }, set: { preferences.update(path, to:$0, key:key) })
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.update(\.general.customDefaultDirectoryPath, to: url.standardizedFileURL.path, key: .newTabDirectoryPolicy)
    }
}

private struct AppearancePreferencesPage: View {
    @ObservedObject var preferences: PanePreferences
    var body: some View { Form {
        Picker("App appearance", selection: bind(\.appearance.mode, .appearanceMode)) { Text("System").tag(AppAppearanceMode.system); Text("Light").tag(AppAppearanceMode.light); Text("Dark").tag(AppAppearanceMode.dark) }
        Slider(value: bind(\.appearance.terminalFont.size, .terminalFontSize), in: 11...24, step: 1) { Text("Terminal font size") } minimumValueLabel: { Text("11") } maximumValueLabel: { Text("24") }
        Text("\(Int(preferences.snapshot.appearance.terminalFont.size)) pt").foregroundStyle(.secondary)
        Picker("Interface density", selection: bind(\.appearance.interfaceDensity, .interfaceDensity)) { Text("Compact").tag(InterfaceDensity.compact); Text("Comfortable").tag(InterfaceDensity.comfortable) }
        Picker("Inline block-output height", selection: bind(\.appearance.blockOutputHeight, .blockOutputHeight)) { ForEach(BlockOutputHeight.allCases, id:\.self) { Text($0.rawValue.capitalized).tag($0) } }
    }.formStyle(.grouped) }
    private func bind<T>(_ path: WritableKeyPath<PanePreferencesSnapshot,T>, _ key: PanePreferenceKey) -> Binding<T> { Binding(get:{preferences.snapshot[keyPath:path]},set:{preferences.update(path,to:$0,key:key)}) }
}

private struct TerminalPreferencesPage: View {
    @ObservedObject var preferences: PanePreferences
    var body: some View { Form {
        Section("Shell") {
            Picker("Shell", selection: bind(\.terminal.shellSelection, .shellExecutable)) { Text("System login shell").tag(ShellSelection.systemLoginShell); Text("Custom executable").tag(ShellSelection.customExecutable) }
            if preferences.snapshot.terminal.shellSelection == .customExecutable {
                HStack {
                    Text(preferences.snapshot.terminal.customShellPath ?? "No executable selected")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseShell() }
                }
            }
            Toggle("Launch as login shell", isOn: bind(\.terminal.launchAsLoginShell, .launchAsLoginShell))
            Text("Shell settings changed. Existing tabs continue using their current shells. Restart shells to apply.").font(.caption).foregroundStyle(.secondary)
        }
        Picker("Option key", selection: bind(\.terminal.optionKeyBehaviour, .optionKeyBehaviour)) { Text("Normal").tag(OptionKeyBehaviour.normal); Text("Esc+ / Meta").tag(OptionKeyBehaviour.meta) }
        Picker("Scrollback limit", selection: bind(\.terminal.scrollbackLimit, .scrollbackLimit)) { Text("5,000 lines").tag(5000); Text("10,000 lines").tag(10000); Text("50,000 lines").tag(50000) }
        Text("Applies to new shells").font(.caption).foregroundStyle(.secondary)
    }.formStyle(.grouped) }
    private func bind<T>(_ path: WritableKeyPath<PanePreferencesSnapshot,T>, _ key: PanePreferenceKey) -> Binding<T> { Binding(get:{preferences.snapshot[keyPath:path]},set:{preferences.update(path,to:$0,key:key)}) }
    private func chooseShell() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        preferences.update(\.terminal.customShellPath, to: url.path, key: .shellExecutable)
    }
}

private struct CompletionPreferencesPage: View {
    @ObservedObject var preferences: PanePreferences
    var body: some View { Form {
        Toggle("Enable completions", isOn: bind(\.completions.enabled, .completionsEnabled))
        Picker("Maximum visible suggestions", selection: bind(\.completions.resultLimit, .completionResultLimit)) { Text("4").tag(4); Text("8").tag(8); Text("12").tag(12) }
        Toggle("Next-command suggestions", isOn: bind(\.completions.nextCommandSuggestionsEnabled, .nextCommandSuggestionsEnabled))
        Toggle("Local completion learning", isOn: bind(\.completions.localLearningEnabled, .localCompletionLearningEnabled))
        Section("Sources") {
            Toggle("Shell completions", isOn: source(\.shell))
            Toggle("Files and directories", isOn: source(\.filesAndDirectories))
            Toggle("Executables", isOn: source(\.executables))
            Toggle("Command history", isOn: source(\.commandHistory))
            Toggle("Project context", isOn: source(\.projectContext))
            Toggle("Previous-command transitions", isOn: source(\.previousCommandTransitions))
        }
    }.formStyle(.grouped) }
    private func bind<T>(_ path: WritableKeyPath<PanePreferencesSnapshot,T>, _ key: PanePreferenceKey) -> Binding<T> { Binding(get:{preferences.snapshot[keyPath:path]},set:{preferences.update(path,to:$0,key:key)}) }
    private func source(_ path: WritableKeyPath<CompletionSources, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.snapshot.completions.sources[keyPath: path] }, set: {
            var sources = preferences.snapshot.completions.sources
            sources[keyPath: path] = $0
            preferences.update(\.completions.sources, to: sources, key: .completionSources)
        })
    }
}

private struct HistoryPreferencesPage: View {
    @ObservedObject var preferences: PanePreferences; @ObservedObject var dataManager: PaneLocalDataManager
    var body: some View { Form {
        Section("Collection") { Toggle("Save command history", isOn: bind(\.history.commandHistoryEnabled)); Toggle("Prepare local prediction context", isOn: bind(\.history.predictionContextEnabled)); Toggle("Save sanitized output excerpts", isOn: bind(\.history.outputSummariesEnabled)); Toggle("Restore last working directory", isOn: bind(\.history.filePathCollectionEnabled)); Toggle("Local completion learning", isOn: Binding(get:{preferences.snapshot.completions.localLearningEnabled},set:{preferences.update(\.completions.localLearningEnabled,to:$0,key:.localCompletionLearningEnabled)})) }
        Section("Restoration") { Toggle("Restore previous blocks", isOn: bind(\.history.visibleSessionRecoveryEnabled)); Toggle("Persist history across Pane launches", isOn: bind(\.history.persistenceEnabled)); Toggle("Restore across workspaces", isOn: bind(\.history.restoreAcrossWorkspacesEnabled)); Text("Cross-workspace restoration may show commands from unrelated local directories.").font(.caption).foregroundStyle(.secondary) }
        Section("Storage limits") {
            Stepper("Previous sessions: \(preferences.snapshot.history.maximumRestoredSessions)", value: bind(\.history.maximumRestoredSessions), in: 1...10)
            Stepper("Commands: \(preferences.snapshot.history.maximumRestoredCommands)", value: bind(\.history.maximumRestoredCommands), in: 25...1_000, step: 25)
            Picker("Stored output", selection: bind(\.history.maximumRestoredOutputBytes)) { Text("None").tag(0); Text("512 KB").tag(512 * 1_024); Text("2 MB").tag(2 * 1_024 * 1_024); Text("8 MB").tag(8 * 1_024 * 1_024) }
        }
        Section("Privacy") { Text("Commands and approved excerpts stay local. Raw terminal bytes, secure input, and environment-variable values are never persisted or uploaded.") }
        Section("Manage data") { Button("Clear Current Session") { Task { try? await dataManager.clearCurrentSessionData(tabID:dataManager.workspace?.selectedTabID) } }.disabled(dataManager.workspace?.selectedTabID == nil); Button("Clear Previous Sessions", role:.destructive) { Task { try? await dataManager.clearPreviousSessions() } }; Button("Clear Exact Command History", role:.destructive) { Task { try? await dataManager.clearExactCommandHistory() } }; Button("Clear Persisted Block Output", role:.destructive) { Task { try? await dataManager.clearPersistedBlockOutput() } }; Button("Reveal Data Location") { dataManager.revealDataLocation() } }
    }.formStyle(.grouped) }
    private func bind<T>(_ path: WritableKeyPath<PanePreferencesSnapshot,T>) -> Binding<T> { Binding(get:{preferences.snapshot[keyPath:path]},set:{preferences.update(path,to:$0,key:.historyConfiguration)}) }
}

private struct AdvancedPreferencesPage: View {
    @ObservedObject var preferences: PanePreferences; @ObservedObject var dataManager: PaneLocalDataManager
    @State private var confirmReset = false
    var body: some View { Form {
        if let diagnostic = preferences.persistenceDiagnostic { Section("Diagnostics") { Label(diagnostic, systemImage:"exclamationmark.triangle") } }
        Section("Data location") { Button("Reveal Pane Application Support Folder") { dataManager.revealDataLocation() } }
        Section("Onboarding") { Button("Replay Pane Onboarding") { NotificationCenter.default.post(name:.showPaneOnboarding, object:nil) } }
        Section("Reset") { Button("Reset All Preferences…", role:.destructive) { confirmReset = true } }
    }.formStyle(.grouped).alert("Reset all preferences?",isPresented:$confirmReset){Button("Cancel",role:.cancel){};Button("Reset",role:.destructive){preferences.resetAll()}} message:{Text("History, workspace data, saved output, and onboarding completion are preserved.")} }
}
