import AppKit
import SwiftUI

@main
struct PaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session: TerminalSession
    @StateObject private var runtimeStateSettings: RuntimeStateSettings

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let settings = RuntimeStateSettings()
        let controller = RuntimeStateController(
            databaseURL: Self.runtimeStateDatabaseURL,
            configuration: settings.configuration
        )
        let session = TerminalSession(
            runtimeStateController: controller,
            commandHistoryEnabled: settings.commandHistoryEnabled
        )
        _runtimeStateSettings = StateObject(wrappedValue: settings)
        _session = StateObject(wrappedValue: session)
        AppDelegate.sharedSession = session
    }

    var body: some Scene {
        Window("Pane", id: "main") {
            ContentView(session: session)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            TerminalCommands(session: session)
            CommandGroup(after: .help) {
                Button("Pane Onboarding") {
                    NotificationCenter.default.post(name: .showPaneOnboarding, object: nil)
                }
            }
        }

        Settings {
            RuntimeStateSettingsView(
                settings: runtimeStateSettings,
                session: session
            )
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
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedSession: TerminalSession?
    private var terminalControlKeyMonitor: Any?
    private var windowIconObserver: NSObjectProtocol?
    private var applicationIcon: NSImage?
    private var isFinalizingTermination = false
    private var hasRepliedToTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminalControlKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard let session = Self.sharedSession,
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
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
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
        guard !isFinalizingTermination, let session = Self.sharedSession else { return .terminateNow }
        isFinalizingTermination = true
        Task { @MainActor in
            await session.finalizeApplicationExit()
            replyToTerminationIfNeeded(sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak sender] in
            guard let self, let sender else { return }
            session.terminateForApplicationExit()
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
            Self.sharedSession?.terminateForApplicationExit()
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
    @ObservedObject var session: TerminalSession

    var body: some Commands {
        CommandMenu("Terminal") {
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
        }
    }
}
