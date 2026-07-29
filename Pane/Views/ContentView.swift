import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var session: TerminalSession
    @State private var isTerminalActionsPresented = false
    @State private var isOnboardingPresented = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .overlay(alignment: .topTrailing) {
            terminalActionsOverlay
        }
        .animation(nil, value: session.mode)
        .task {
            session.ensureAuthoritativeTerminalIsRunning()
            if !hasCompletedOnboarding { isOnboardingPresented = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPaneOnboarding)) { _ in
            isOnboardingPresented = true
        }
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
                    presentation: .fullTerminal,
                    mountGeneration: session.focusGeneration
                )
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !session.isShellReadyForInput {
                ShellReadinessOverlay(session: session)
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
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isTerminalActionsPresented.toggle()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(
                    isTerminalActionsPresented
                        ? PaneTheme.selectedBlockBackground
                        : PaneTheme.subtleControlFill,
                    in: Circle()
                )
                .overlay {
                    Circle().stroke(.primary.opacity(0.10), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Terminal actions")
        .accessibilityLabel("Terminal actions")
        .accessibilityValue(isTerminalActionsPresented ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private var terminalActionsOverlay: some View {
        if isTerminalActionsPresented {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissTerminalActions() }

                TerminalActionsMenu(session: session) {
                    dismissTerminalActions()
                }
                .padding(.top, 8)
                .padding(.trailing, 10)
            }
            .onExitCommand { dismissTerminalActions() }
            .transition(terminalActionsTransition)
        }
    }

    private var terminalActionsTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: 0.96, anchor: .topTrailing)
            .combined(with: .opacity)
    }

    private func dismissTerminalActions() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            isTerminalActionsPresented = false
        }
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

private struct TerminalActionsMenu: View {
    @ObservedObject var session: TerminalSession
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 1) {
            actionButton("Clear Blocks", systemImage: "rectangle.stack.badge.minus") {
                session.clearBlocks()
            }
            actionButton("Clear Terminal", systemImage: "eraser") {
                session.clearTerminal()
            }

            Divider().padding(.vertical, 3)

            actionButton("Direct Input", systemImage: "keyboard") {
                session.enterDirectInput()
            }
            .disabled(!session.isShellReadyForInput)
            actionButton(
                session.isSecureInputActive ? "Exit Secure Input" : "Enter Secure Input",
                systemImage: session.isSecureInputActive ? "lock.open" : "lock"
            ) {
                if session.isSecureInputActive {
                    session.exitSecureInput()
                } else {
                    session.enterSecureInput()
                }
            }
            .disabled(!session.isShellReadyForInput && !session.isSecureInputActive)

            Divider().padding(.vertical, 3)

            actionButton("Send Interrupt", systemImage: "stop.circle") {
                session.sendInterrupt()
            }
            .disabled(!session.isShellReadyForInput)
            actionButton("Restart Shell", systemImage: "arrow.clockwise") {
                session.requestRestartShell()
            }
            .disabled(session.isRestartInProgress || session.isShuttingDown)
            actionButton("Copy Local Diagnostics", systemImage: "stethoscope") {
                session.copyLocalDiagnostics()
            }
        }
        .padding(5)
        .frame(width: 188)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PaneTheme.blockBackground)
            } else {
                MenuMaterialBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.32), radius: 14, y: 7)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        TerminalActionButton(title: title, systemImage: systemImage) {
            action()
            dismiss()
        }
    }
}

private struct PaneOnboardingView: View {
    @ObservedObject var session: TerminalSession
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Pane").font(.largeTitle.bold())
                Text("A local-first, block-native terminal optimized for zsh. No account or network access is required.")
                    .foregroundStyle(.secondary)
            }
            concept("1", "Blocks", "Run normal commands from the composer. Commands and allowed sanitized excerpts become searchable, collapsible local blocks.", "rectangle.stack")
            concept("2", "Real terminal interaction", "Interactive programs use one authoritative SwiftTerm terminal and the same persistent PTY.", "terminal")
            concept("3", "Escape hatch", "Use Direct Input or Full Terminal whenever automatic interaction detection is wrong.", "keyboard")

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
    static let showPaneOnboarding = Notification.Name("Pane.showOnboarding")
}

private struct TerminalActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)

                Text(title)

                Spacer(minLength: 12)
            }
            .font(.system(size: 13))
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MenuMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
