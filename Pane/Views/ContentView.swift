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
        ZStack {
            TerminalViewRepresentable(session: session)
                .padding(.leading, PaneMetrics.contentTextColumn)
                .padding(.trailing, PaneMetrics.contentTextColumn)
                .padding(.top, 8)
                .allowsHitTesting(session.mode == .terminal)
                .accessibilityHidden(session.mode != .terminal)

            if session.mode == .blocks {
                BlocksView(session: session)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaneTheme.contentSurface)
        .animation(nil, value: session.mode)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.mode == .blocks {
                CommandComposerView(session: session)
            } else {
                terminalModeBar
            }
        }
        .toolbar { terminalToolbar }
    }

    @ToolbarContentBuilder
    private var terminalToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .primaryAction) {
                shellStatus
                    .fixedSize(horizontal: true, vertical: false)

                ModeSwitcher(selection: modeBinding)

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

                ModeSwitcher(selection: modeBinding)

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

            Button("Send Interrupt", systemImage: "stop.circle") {
                session.sendInterrupt()
            }
            Button("Restart Shell", systemImage: "arrow.clockwise") {
                session.restartShell()
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 24)
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

    private var terminalModeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isAlternateScreenActive ? "rectangle.inset.filled" : "keyboard")
                .foregroundStyle(session.isAlternateScreenActive ? Color.accentColor : .secondary)

            Text(session.isAlternateScreenActive ? "Alternate screen" : "Direct terminal input")
                .font(.caption.weight(.medium))

            Text(
                session.isAlternateScreenActive
                    ? "The foreground terminal app owns this screen."
                    : "Keys and mouse events go directly to the foreground process."
            )
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PaneTheme.separator, lineWidth: 1)
        }
        .padding(.horizontal, PaneMetrics.composerOuterInset)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct ModeSwitcher: View {
    @Binding var selection: InputMode
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        if #available(macOS 26.0, *) {
            liquidGlassSwitcher
        } else {
            Picker("Input mode", selection: $selection) {
                ForEach(InputMode.allCases, id: \.self) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 150)
            .help("Switch between structured Blocks and direct Terminal input")
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlassSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(InputMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                        selection = mode
                    }
                } label: {
                    Text(mode.shortTitle)
                        .font(.callout.weight(selection == mode ? .semibold : .medium))
                        .foregroundStyle(selection == mode ? .primary : .secondary)
                        .frame(width: 76, height: 26)
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
                .accessibilityValue(selection == mode ? "Selected" : "Not selected")
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help("Switch between structured Blocks and direct Terminal input")
        .accessibilityElement(children: .contain)
    }

    private var selectionFill: Color {
        if colorSchemeContrast == .increased {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        return PaneTheme.selectedBlockBackground
    }
}
