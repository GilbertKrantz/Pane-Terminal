import SwiftUI

struct CommandBlockView: View {
    let block: CommandBlock
    let isSelected: Bool
    @ObservedObject var session: TerminalSession
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayDirectory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                statusLabel

                Spacer(minLength: 16)

                contextualToolbar
                    // The slot is always reserved so hovering a block never
                    // changes the command or status layout.
                    .frame(width: 116, alignment: .trailing)
                    .opacity(contextualToolbarOpacity)
                    .allowsHitTesting(showsContextualToolbar)
                    .accessibilityHidden(!showsContextualToolbar)
                    .animation(.easeOut(duration: 0.12), value: contextualToolbarOpacity)
            }

            Text(block.command)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if !block.isCollapsed, !block.output.isEmpty {
                Text(block.output)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PaneMetrics.blockInnerInset)
        .padding(.vertical, 9)
        .background(blockSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        PaneTheme.separator.opacity(colorSchemeContrast == .increased ? 1 : 0.75),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { session.selectBlock(block.id) }
        .onHover { isHovered = $0 }
        .contextMenu { overflowActions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command block: \(block.command), \(block.statusText)")
    }

    private var blockSurface: Color {
        if isSelected {
            return PaneTheme.selectedBlockBackground.opacity(
                colorSchemeContrast == .increased ? 1 : 0.55
            )
        }
        if isHovered { return PaneTheme.blockBackground }
        return .clear
    }

    private var showsContextualToolbar: Bool {
        isSelected || isHovered
    }

    private var contextualToolbarOpacity: Double {
        if isHovered { return 1 }
        if isSelected { return 0.5 }
        return 0
    }

    private var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if block.workingDirectory == home { return "~" }
        if block.workingDirectory.hasPrefix(home + "/") {
            return "~" + block.workingDirectory.dropFirst(home.count)
        }
        return block.workingDirectory
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch block.state {
        case .running:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text(block.statusText)
            }
            .foregroundStyle(.secondary)
            .font(.caption.monospacedDigit())

        default:
            Label(block.statusText, systemImage: statusSymbol)
                .font(.caption.monospacedDigit())
                .foregroundStyle(statusColor)
        }
    }

    private var statusSymbol: String {
        switch block.state {
        case .queued: "clock"
        case .running: "circle.dotted"
        case .completed(let exitCode): exitCode == 0 ? "checkmark" : "xmark"
        case .interrupted: "stop"
        }
    }

    private var statusColor: Color {
        switch block.state {
        case .completed(let exitCode): exitCode == 0 ? .green : .red
        case .interrupted: .orange
        case .queued, .running: .secondary
        }
    }

    private var contextualToolbar: some View {
        HStack(spacing: 1) {
            Button {
                session.copyOutput(id: block.id)
            } label: {
                ToolbarHoverSurface(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy output")

            Button {
                session.rerunBlock(id: block.id)
            } label: {
                ToolbarHoverSurface(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Rerun command")

            Button {
                session.toggleBlockCollapsed(id: block.id)
            } label: {
                ToolbarHoverSurface(
                    systemName: block.isCollapsed ? "chevron.down" : "chevron.up"
                )
            }
            .buttonStyle(.plain)
            .help(block.isCollapsed ? "Expand output" : "Collapse output")

            Menu {
                overflowActions
            } label: {
                ToolbarHoverSurface(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More block actions")
        }
        .controlSize(.small)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var overflowActions: some View {
        Button("Copy Command", systemImage: "text.badge.plus") {
            session.copyCommand(id: block.id)
        }
        Button("Edit in Composer", systemImage: "pencil") {
            session.editBlock(id: block.id)
        }

        Divider()

        Button("Delete Block", systemImage: "trash", role: .destructive) {
            session.removeBlock(id: block.id)
        }
    }
}

private struct ToolbarHoverSurface: View {
    let systemName: String
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .symbolVariant(isHovered ? .fill : .none)
            .frame(width: 25, height: 22)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? PaneTheme.selectedBlockBackground : .clear)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}
