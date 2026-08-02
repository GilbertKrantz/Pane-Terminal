import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace: TerminalWorkspaceController
    @StateObject private var runtimeStateSettings: RuntimeStateSettings

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let settings = RuntimeStateSettings()
        let persistenceCoordinator = RuntimeStatePersistenceCoordinator(
            databaseURL: Self.runtimeStateDatabaseURL
        )
        let factory = DefaultTerminalSessionFactory(
            runtimeStateControllerProvider: {
                RuntimeStateController(
                    persistenceCoordinator: persistenceCoordinator,
                    configuration: settings.configuration
                )
            },
            commandHistoryEnabledProvider: { settings.commandHistoryEnabled }
        )
        let workspace = TerminalWorkspaceController(
            factory: factory,
            snapshotURL: Self.workspaceSnapshotURL
        )
        _runtimeStateSettings = StateObject(wrappedValue: settings)
        _workspace = StateObject(wrappedValue: workspace)
        AppDelegate.sharedWorkspace = workspace
        AppDelegate.sharedRuntimeStatePersistenceCoordinator = persistenceCoordinator
    }

    var body: some Scene {
        Window("Pane", id: "main") {
            TerminalWorkspaceView(workspace: workspace)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            TerminalCommands(workspace: workspace)
            CommandGroup(after: .help) {
                Button("Pane Onboarding") {
                    NotificationCenter.default.post(name: .showPaneOnboarding, object: nil)
                }
            }
        }

        Settings {
            if let session = workspace.selectedTab?.session {
                RuntimeStateSettingsView(
                    settings: runtimeStateSettings,
                    session: session,
                    applyConfigurationToAllSessions: workspace.applyRuntimeStateConfiguration
                )
            } else {
                Text("Terminal workspace is starting…").padding()
            }
        }
    }

    private static var runtimeStateDatabaseURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("Pane", isDirectory: true)
            .appendingPathComponent("runtime-state.sqlite")
    }

    private static var workspaceSnapshotURL: URL {
        runtimeStateDatabaseURL.deletingLastPathComponent().appendingPathComponent("workspace.json")
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedWorkspace: TerminalWorkspaceController?
    static var sharedRuntimeStatePersistenceCoordinator: RuntimeStatePersistenceCoordinator?
    private var terminalControlKeyMonitor: Any?
    private var windowIconObserver: NSObjectProtocol?
    private var applicationIcon: NSImage?
    private var isFinalizingTermination = false
    private var hasRepliedToTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminalControlKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard let session = Self.sharedWorkspace?.selectedTab?.session,
                  session.mode == .blocks,
                  session.isCommandActive,
                  let action = TerminalControlKeyRouter.action(for: event) else {
                return event
            }

            switch action {
            case .interrupt:
                session.sendInterrupt()
            case .endOfFile:
                session.sendEndOfFile()
            }
            // Consume the event before NSTextView, SwiftUI Commands, or a
            // Cocoa key binding can reinterpret the terminal control byte.
            return nil
        }

        // Xcode and direct debug launches do not always refresh the icon that
        // Launch Services associates with the running process. Use the same
        // compiled icon that ships in the bundle so Dock, App Expose, and
        // window previews never fall back to the generic application tile.
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcons", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }

        icon.isTemplate = false
        applicationIcon = icon
        NSApplication.shared.applicationIconImage = icon
        applyIcon(to: NSApplication.shared.windows)

        // SwiftUI can create the scene window after application launch. Apply
        // the same compiled icon whenever a Pane window becomes main so Dock
        // miniatures, App Expose, and window previews never use AppKit's
        // generic application placeholder.
        windowIconObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            assert(Thread.isMainThread)
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                self?.applyIcon(to: [window])
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyIcon(to: NSApplication.shared.windows)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinalizingTermination, let workspace = Self.sharedWorkspace else { return .terminateNow }
        isFinalizingTermination = true
        Task { @MainActor in
            await workspace.shutdown()
            await Self.sharedRuntimeStatePersistenceCoordinator?.shutdown()
            replyToTerminationIfNeeded(sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak sender] in
            guard let self, let sender else { return }
            workspace.terminateAllForApplicationExit()
            self.replyToTerminationIfNeeded(sender)
        }
        return .terminateLater
    }

    private func replyToTerminationIfNeeded(_ sender: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let terminalControlKeyMonitor {
            NSEvent.removeMonitor(terminalControlKeyMonitor)
            self.terminalControlKeyMonitor = nil
        }
        if let windowIconObserver {
            NotificationCenter.default.removeObserver(windowIconObserver)
            self.windowIconObserver = nil
        }
        if !isFinalizingTermination {
            Self.sharedWorkspace?.terminateAllForApplicationExit()
        }
    }

    private func applyIcon(to windows: [NSWindow]) {
        guard let applicationIcon else { return }
        for window in windows where window.miniwindowImage !== applicationIcon {
            window.miniwindowImage = applicationIcon
        }
    }
}

private struct TerminalCommands: Commands {
    @ObservedObject var workspace: TerminalWorkspaceController

    private var session: TerminalSession? { workspace.selectedTab?.session }

    var body: some Commands {
        CommandMenu("Tab") {
            Button("New Tab") { Task { await workspace.createTab() } }
                .keyboardShortcut("t", modifiers: [.command])
            Button("Close Tab") {
                guard let id = workspace.selectedTabID else { return }
                Task { await workspace.closeTab(id: id, policy: .requestUserConfirmation) }
            }
            .keyboardShortcut("w", modifiers: [.command])
            Button("Next Tab") { workspace.selectRelative(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { workspace.selectRelative(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab (Control-Tab)") { workspace.selectRelative(offset: 1) }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("Previous Tab (Control-Shift-Tab)") { workspace.selectRelative(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(0..<9, id: \.self) { index in
                Button("Select Tab \(index + 1)") {
                    guard workspace.tabs.indices.contains(index) else { return }
                    workspace.selectTab(id: workspace.tabs[index].id)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                .disabled(!workspace.tabs.indices.contains(index))
            }
        }
        CommandMenu("Terminal") {
            if let session {
            Button("Find in Command History") {
                session.presentBlockSearch()
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Focus Composer") {
                session.focusComposer()
            }
            .keyboardShortcut("l", modifiers: [.command])

            Button("Focus Direct Terminal") {
                session.focusDirectTerminal()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!session.isShellReadyForInput)

            Button("Open Full Terminal") {
                session.setMode(.terminal)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!session.isShellReadyForInput)

            Button("Return to Blocks") {
                session.focusComposer()
            }
            .disabled(session.isSecureInputActive)

            Divider()

            Button(session.isSecureInputActive ? "Exit Manual Secure Input" : "Enter Secure Input") {
                if session.isSecureInputActive {
                    session.exitSecureInput()
                } else {
                    session.enterSecureInput()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!session.isShellReadyForInput && !session.isSecureInputActive)

            Divider()

            Button("Select Previous Block") {
                session.selectPreviousBlock()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(session.mode != .blocks || session.blocks.isEmpty)

            Button("Select Next Block") {
                session.selectNextBlock()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(session.mode != .blocks || session.blocks.isEmpty)

            Button("Rerun Selected Block") {
                session.rerunSelectedBlock()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(
                session.mode != .blocks
                    || session.selectedBlockID == nil
                    || !session.isShellReadyForInput
            )

            Button("Edit Selected Command") {
                session.editSelectedBlock()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(session.mode != .blocks || session.selectedBlockID == nil)

            Divider()

            Button("Send Interrupt") {
                session.sendInterrupt()
            }
            .disabled(!session.isShellReadyForInput)

            Button("Send End of File") {
                session.sendEndOfFile()
            }
            .disabled(!session.isShellReadyForInput)

            Divider()

            Button(session.mode == .blocks ? "Clear Blocks" : "Clear Terminal") {
                if session.mode == .blocks {
                    session.clearBlocks()
                } else {
                    session.clearTerminal()
                }
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Restart Shell") {
                session.requestRestartShell()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(session.isRestartInProgress || session.isShuttingDown)

            Button("Copy Local Diagnostics") {
                session.copyLocalDiagnostics()
            }

            Button("Copy Diagnostics with Sanitized Command Context") {
                session.copyLocalDiagnostics(includeSanitizedCommandContext: true)
            }

#if DEBUG
            Button("Export Diagnostics…") {
                Task { @MainActor in
                    await exportDiagnostics()
                }
            }
#endif
            }
        }
    }

#if DEBUG
    @MainActor
    private func exportDiagnostics() async {
        let runtimeCoordinator = AppDelegate.sharedRuntimeStatePersistenceCoordinator
        let runtimePersistenceStatus = await runtimeCoordinator?.diagnostic()
        let snapshot = await workspace.diagnosticsSnapshot(
            persistenceStatus: runtimePersistenceStatus
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "pane-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshot.encodedJSON().write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Pane could not export diagnostics"
            alert.runModal()
        }
    }
#endif
}
