import AppKit
import SwiftUI

@main
struct PaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session: TerminalSession

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let session = TerminalSession()
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
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedSession: TerminalSession?
    private var terminalControlKeyMonitor: Any?
    private var windowIconObserver: NSObjectProtocol?
    private var applicationIcon: NSImage?

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

    func applicationWillTerminate(_ notification: Notification) {
        if let terminalControlKeyMonitor {
            NSEvent.removeMonitor(terminalControlKeyMonitor)
            self.terminalControlKeyMonitor = nil
        }
        if let windowIconObserver {
            NotificationCenter.default.removeObserver(windowIconObserver)
            self.windowIconObserver = nil
        }
        Self.sharedSession?.terminateForApplicationExit()
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
            Button(session.mode == .blocks ? "Enter Terminal Mode" : "Return to Blocks Mode") {
                session.toggleMode()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

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
            .disabled(session.mode != .blocks || session.selectedBlockID == nil)

            Button("Edit Selected Command") {
                session.editSelectedBlock()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(session.mode != .blocks || session.selectedBlockID == nil)

            Divider()

            Button("Send Interrupt") {
                session.sendInterrupt()
            }

            Button("Send End of File") {
                session.sendEndOfFile()
            }

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
                session.restartShell()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
