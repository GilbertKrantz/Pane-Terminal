import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var session: TerminalSession
    @State private var isHelpPresented = false
    @State private var isOnboardingPresented = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var modeBinding: Binding<InputMode> {
        Binding(
            get: { session.mode },
            set: { session.setMode($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.isBlockSearchPresented {
                BlockSearchBar(session: session)
            }

            workspaceContent

            if session.mode == .blocks && !session.shouldPresentExpandedAuthoritativeTerminal {
                Divider()
                    .overlay(PaneTheme.separator.opacity(0.65))

                if session.isShellReadyForInput {
                    CommandComposerView(session: session)
                } else {
                    ShellReadinessBar(session: session)
                }
            } else if session.mode == .terminal {
                Divider()
                    .overlay(PaneTheme.separator.opacity(0.65))

                if session.isShellReadyForInput {
                    terminalModeBar
                } else {
                    ShellReadinessBar(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaneTheme.contentSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PaneTheme.separator.opacity(0.55), lineWidth: 0.5)
                .padding(1)
        }
        .animation(nil, value: session.mode)
        .task {
            session.ensureAuthoritativeTerminalIsRunning()
            if !hasCompletedOnboarding { isOnboardingPresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPaneOnboarding)) { _ in
            isOnboardingPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPaneHelp)) { _ in
            isHelpPresented = true
        }
        .sheet(isPresented: $isHelpPresented) { PaneHelpView() }
        .sheet(isPresented: $isOnboardingPresented) {
            PaneOnboardingView(session: session) {
                hasCompletedOnboarding = true
                isOnboardingPresented = false
            }
        }
        .alert("Restart the shell?", isPresented: $session.isRestartConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Restart Shell", role: .destructive) { session.confirmRestartShell() }
        } message: {
            Text("The foreground process will be terminated. Completed blocks remain, and Pane starts a fresh shell in the last safe directory.")
        }
        .toolbarBackground(PaneTheme.contentSurface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar { terminalToolbar }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        ZStack {
            if session.mode == .blocks {
                if session.shouldPresentExpandedAuthoritativeTerminal,
                   let activeBlock = session.activeCommandBlock {
                    AuthoritativeInputCommandView(
                        block: activeBlock,
                        session: session
                    )
                    .transition(.identity)
                } else {
                    BlocksView(session: session)
                        .transition(.identity)
                }
            } else {
                TerminalViewRepresentable(
                    session: session,
                    placement: .fullTerminal
                )
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !session.isShellReadyForInput {
                ShellReadinessOverlay(session: session)
            }
        }
        .overlay {
            if session.terminalMountRecoveryRequired {
                TerminalMountRecoveryOverlay(session: session)
            }
        }
    }

    @ToolbarContentBuilder
    private var terminalToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .primaryAction) {
                shellStatus
                    .fixedSize(horizontal: true, vertical: false)

                ModeSwitcher(selection: modeBinding)
                    .disabled(!session.isShellReadyForInput)

                terminalActionsMenu
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            // Each control owns its intended surface. Suppressing Tahoe's
            // shared capsule keeps status plain and preserves native group and
            // trailing-edge spacing around the slider and overflow button.
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                shellStatus
                    .fixedSize(horizontal: true, vertical: false)

                ModeSwitcher(selection: modeBinding)
                    .disabled(!session.isShellReadyForInput)

                terminalActionsMenu
            }
        }
    }

    private var terminalActionsMenu: some View {
        Menu {
            Button("Find in Blocks", systemImage: "magnifyingglass") { session.presentBlockSearch() }
            Button("Clear Blocks", systemImage: "rectangle.stack.badge.minus") { session.clearBlocks() }
            Button("Undo Block Removal", systemImage: "arrow.uturn.backward") { session.undoBlockRemoval() }
                .disabled(session.blockRemovalNotice == nil)
            Menu("Input") {
                Button("Direct Input", systemImage: "keyboard") { session.enterDirectInput() }
                    .disabled(!session.isShellReadyForInput)
                Button(session.isSecureInputActive ? "Exit Secure Input" : "Enter Secure Input") {
                    if session.isSecureInputActive { session.exitSecureInput() }
                    else { session.enterSecureInput() }
                }
                .disabled(!session.isShellReadyForInput && !session.isSecureInputActive)
            }
            Divider()
            Button("Send Interrupt", systemImage: "stop.circle") { session.sendInterrupt() }
                .disabled(!session.isShellReadyForInput)
            Menu("Shell and Diagnostics") {
                Button("Clear Terminal", systemImage: "eraser") { session.clearTerminal() }
                Button("Restart Shell…", systemImage: "arrow.clockwise") { session.requestRestartShell() }
                    .disabled(session.isRestartInProgress || session.isShuttingDown)
                Button("Repair Terminal View", systemImage: "wrench.and.screwdriver") { session.repairTerminalView() }
                Button("Copy Local Diagnostics", systemImage: "stethoscope") { session.copyLocalDiagnostics() }
            }
            Divider()
            Button("Using Pane", systemImage: "questionmark.circle") { isHelpPresented = true }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Terminal actions")
        .accessibilityLabel("Terminal actions")
    }

    private var shellStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(shellStatusColor)
                .frame(width: 6, height: 6)

            Text(session.activeProcessLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shell status: \(session.activeProcessLabel)")
    }

    private var shellStatusColor: Color {
        switch session.shellReadiness {
        case .starting, .initializing:
            return .secondary
        case .stopped:
            return .red
        case .ready:
            break
        }
        if session.blockTimeline.activeBlockID != nil { return .accentColor }
        return .secondary
    }

    private var terminalModeExplanation: String {
        if session.isAlternateScreenActive {
            return "The foreground terminal app owns this screen."
        }
        if session.modeAttribution != .manual {
            return "Terminal mode because \(session.modeAttribution.explanation)."
        }
        return "Keys and mouse events go directly to the foreground process."
    }

    private var terminalModeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isAlternateScreenActive ? "rectangle.inset.filled" : "keyboard")
                .foregroundStyle(session.isAlternateScreenActive ? Color.accentColor : .secondary)

            Text(session.isAlternateScreenActive ? "Alternate screen" : "Direct terminal input")
                .font(.caption.weight(.medium))

            Text(terminalModeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text("⌘⇧I")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Button("Return to Blocks") {
                session.setMode(.blocks)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.bar)
        .padding(.horizontal, PaneMetrics.composerOuterInset)
        .padding(.vertical, 6)
    }
}

private struct ShellReadinessOverlay: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())

            VStack(spacing: 12) {
                if session.shellReadiness == .stopped && !session.isShuttingDown {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                VStack(spacing: 5) {
                    Text(title)
                        .font(.headline)

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if session.shellReadiness == .stopped && !session.isShuttingDown {
                    Button("Restart Shell") {
                        session.requestRestartShell()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(session.isRestartInProgress)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 360)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PaneTheme.separator.opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var title: String {
        if session.isShuttingDown { return "Closing shell…" }
        if session.isRestartInProgress { return "Starting a new shell…" }
        switch session.shellReadiness {
        case .starting:
            return "Starting your shell…"
        case .initializing:
            return "Initializing your shell…"
        case .stopped:
            return "Shell stopped"
        case .ready:
            return ""
        }
    }

    private var detail: String {
        if session.isShuttingDown {
            return "Pane is saving the current session before closing."
        }
        if session.isRestartInProgress {
            return "Input will be available when the new shell finishes initializing."
        }
        switch session.shellReadiness {
        case .starting:
            return "Pane is launching \(session.shellDisplayName). Input is temporarily unavailable."
        case .initializing:
            return "Loading your shell configuration. Input will be available when initialization finishes."
        case .stopped:
            return "Start a new shell to continue entering commands."
        case .ready:
            return ""
        }
    }
}

private struct ShellReadinessBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 8) {
            if session.shellReadiness == .stopped && !session.isShuttingDown {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(session.activeProcessLabel)
                .font(.caption.weight(.medium))

            Text("Input is unavailable until the shell is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, PaneMetrics.composerOuterInset)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

private struct ModeSwitcher: View {
    @Binding var selection: InputMode
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        if #available(macOS 26.0, *) {
            slidingSwitcher
        } else {
            Picker("Input mode", selection: $selection) {
                ForEach(InputMode.allCases, id: \.self) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: ModeSwitcherPresentation.fallbackWidth)
            .help(ModeSwitcherPresentation.help)
        }
    }

    @available(macOS 26.0, *)
    private var slidingSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(InputMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(
                        ModeSwitcherPresentation.shouldAnimateSelection(reduceMotion: reduceMotion)
                            ? .snappy(duration: 0.24)
                            : nil
                    ) {
                        selection = mode
                    }
                } label: {
                    Text(mode.shortTitle)
                        .font(.callout.weight(selection == mode ? .semibold : .medium))
                        .foregroundStyle(selection == mode ? .primary : .secondary)
                        .frame(
                            width: ModeSwitcherPresentation.segmentWidth,
                            height: ModeSwitcherPresentation.segmentHeight
                        )
                        .background {
                            if selection == mode {
                                Capsule()
                                    .fill(selectionFill)
                                    .matchedGeometryEffect(
                                        id: "selected-mode",
                                        in: selectionAnimation
                                    )
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityValue(
                    ModeSwitcherPresentation.accessibilityValue(
                        for: mode,
                        selection: selection
                    )
                )
            }
        }
        .padding(ModeSwitcherPresentation.trackInset)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help(ModeSwitcherPresentation.help)
        .accessibilityElement(children: .contain)
    }

    private var selectionFill: Color {
        if colorSchemeContrast == .increased {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        return PaneTheme.selectedBlockBackground
    }
}

struct ModeSwitcherPresentation {
    static let segmentWidth: CGFloat = 76
    static let segmentHeight: CGFloat = 26
    static let trackInset: CGFloat = 3
    static let fallbackWidth: CGFloat = 150
    static let help = "Switch between structured Blocks and direct Terminal input"

    static func shouldAnimateSelection(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func accessibilityValue(for mode: InputMode, selection: InputMode) -> String {
        mode == selection ? "Selected" : "Not selected"
    }
}

private struct TerminalMountRecoveryOverlay: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.badge.exclamationmark")
                .font(.title2)
            Text("Terminal view needs repair")
                .font(.headline)
            Text("The shell is still running. Repairing the view preserves its terminal state.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Repair Terminal View") {
                    session.repairTerminalView()
                }
                .buttonStyle(.borderedProminent)
                Button("Copy Diagnostics") {
                    session.copyLocalDiagnostics()
                }
                .buttonStyle(.bordered)
                Button("Restart Shell", role: .destructive) {
                    session.requestRestartShell()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PaneTheme.separator, lineWidth: 0.5)
        }
        .shadow(radius: 12, y: 4)
        .padding()
    }
}

private struct PaneOnboardingView: View {
    @ObservedObject var session: TerminalSession
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Pane").font(.largeTitle.bold())
                Text("A local terminal that keeps your commands and output easy to revisit. No account or network access is required.")
                    .foregroundStyle(.secondary)
            }
            concept("1", "Blocks", "Run normal commands from the composer. Commands and allowed sanitized excerpts become searchable, collapsible local blocks.", "rectangle.stack")
            concept("2", "Real terminal interaction", "Use Terminal for interactive programs. Your commands, working directory, and shell session stay connected.", "terminal")
            concept("3", "Escape hatch", "Switch to Terminal whenever a program needs direct keyboard input. Return to Blocks to compose your next command.", "keyboard")

            HStack {
                Menu("Try a command") {
                    Button("pwd") { session.commandDraft = "pwd" }
                    Button("ls") { session.commandDraft = "ls" }
                    Button("printf Hello from Pane") { session.commandDraft = "printf \"Hello from Pane\\n\"" }
                    Divider()
                    Button("python3 (interactive)") { session.commandDraft = "python3" }
                }
                Text("Commands are placed in the composer and never run without your action.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Get Started", action: dismiss).keyboardShortcut(.defaultAction)
            }

            Text("History is stored only in ~/Library/Application Support/Pane when enabled. Open Settings to inspect categories or clear Pane data.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 620)
    }

    private func concept(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)").font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

extension Notification.Name {
    static let showPaneHelp = Notification.Name("Pane.showHelp")
    static let showPaneOnboarding = Notification.Name("Pane.showOnboarding")
}


private struct PaneHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let topics: [(String, String)] = [
        ("Run a command", "In Blocks, type a command and press Return. Shift-Return adds a new line. Completed commands appear above the composer."),
        ("Use an interactive program", "Switch to Terminal for editors, prompts, and direct keyboard input. Return to Blocks when you want the command composer. Both modes share your shell session."),
        ("Complete a command", "Tab and Shift-Tab select suggestions; Return accepts the selected suggestion. Escape dismisses suggestions."),
        ("Find and reuse commands", "Use Find in Blocks in Terminal actions to search history. Select a block to copy output, expand it, or open More block actions to edit and rerun."),
        ("Remove blocks", "Clear Blocks and Delete Block hide completed entries from the timeline. Use Undo in the removal notice to restore the latest removal. Settings manages permanent history deletion."),
        ("Stop or recover", "Use Send Interrupt to stop a command. Restart Shell starts a fresh shell. Repair Terminal View preserves your running shell."),
        ("History and privacy", "Settings > History & Privacy controls local collection, restoration, and permanent deletion. New commands may be saved again while collection is enabled.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Using Pane").font(.title2.bold())
            TextField("Search help", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(topics.filter { query.isEmpty || ($0.0 + $0.1).localizedCaseInsensitiveContains(query) }, id: \.0) { topic in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topic.0).font(.headline)
                            Text(topic.1).foregroundStyle(.secondary)
                        }
                    }
                    if !query.isEmpty && !topics.contains(where: { ($0.0 + $0.1).localizedCaseInsensitiveContains(query) }) {
                        Text("No matching help. Try “commands”, “Terminal”, or “history”.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520, height: 460)
    }
}
