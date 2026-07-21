import SwiftUI

struct ContentView: View {
    @ObservedObject var session: TerminalSession

    private var modeBinding: Binding<InputMode> {
        Binding(
            get: { session.mode },
            set: { session.setMode($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceContent

            if session.mode == .blocks && !session.shouldPresentExpandedAuthoritativeTerminal {
                Divider()
                    .overlay(PaneTheme.separator.opacity(0.65))

                CommandComposerView(session: session)
            } else if session.mode == .terminal {
                Divider()
                    .overlay(PaneTheme.separator.opacity(0.65))

                terminalModeBar
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
                TerminalViewRepresentable(session: session)
                    .padding(.leading, PaneMetrics.contentTextColumn)
                    .padding(.trailing, PaneMetrics.contentTextColumn)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var terminalToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .primaryAction) {
                shellStatus
                    .fixedSize(horizontal: true, vertical: false)

                ModeMenu(selection: modeBinding)

                terminalActionsMenu
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            // Tahoe gives every custom toolbar item a shared glass capsule by
            // default. These controls provide their own intentional hierarchy,
            // so hiding that automatic layer prevents the nested-pill effect.
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                shellStatus
                    .fixedSize(horizontal: true, vertical: false)

                ModeMenu(selection: modeBinding)

                terminalActionsMenu
            }
        }
    }

    private var terminalActionsMenu: some View {
        Menu {
            Button("Clear Blocks", systemImage: "rectangle.stack.badge.minus") {
                session.clearBlocks()
            }
            Button("Clear Terminal", systemImage: "eraser") {
                session.clearTerminal()
            }

            Divider()

            Button("Direct Input", systemImage: "keyboard") {
                session.enterDirectInput()
            }
            if session.isSecureInputActive {
                Button("Exit Secure Input", systemImage: "lock.open") {
                    session.exitSecureInput()
                }
            } else {
                Button("Enter Secure Input", systemImage: "lock") {
                    session.enterSecureInput()
                }
            }

            Divider()

            Button("Send Interrupt", systemImage: "stop.circle") {
                session.sendInterrupt()
            }
            Button("Restart Shell", systemImage: "arrow.clockwise") {
                session.restartShell()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(PaneTheme.subtleControlFill, in: Circle())
                .overlay {
                    Circle().stroke(.primary.opacity(0.10), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
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
        if !session.isShellRunning { return .red }
        if session.blockTimeline.activeBlockID != nil { return .yellow }
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

private struct ModeMenu: View {
    @Binding var selection: InputMode

    var body: some View {
        Menu {
            // Picker-in-Menu uses AppKit's native selected-item checkmark, which
            // matches macOS menu conventions better than a custom sliding toggle.
            Picker("Input mode", selection: $selection) {
                ForEach(InputMode.allCases, id: \.self) { mode in
                    Text(mode.title)
                        .tag(mode)
                        .accessibilityLabel(mode.title)
                        .accessibilityValue(selection == mode ? "Selected" : "Not selected")
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(selection.shortTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .frame(minWidth: 108, minHeight: 26)
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .modifier(ModeMenuGlassChrome())
        .help("Switch between structured Blocks and direct Terminal input")
        .accessibilityLabel("Input mode")
        .accessibilityValue(selection.title)
    }
}

private struct ModeMenuGlassChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(PaneTheme.separator, lineWidth: 1)
                }
        }
    }
}
