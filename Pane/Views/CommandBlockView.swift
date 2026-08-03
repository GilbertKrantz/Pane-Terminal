import SwiftUI

struct CommandBlockView: View {
    let block: CommandBlock
    let isSelected: Bool
    @ObservedObject var session: TerminalSession
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    private var presentation: BlockPresentationModel {
        block.presentation()
    }

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
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: contextualToolbarOpacity)
            }

            Text(block.command)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if !block.isCollapsed, hasVisibleOutput {
                plainTextOutput
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
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(timelineRailColor.opacity(isSelected ? 0.9 : 0.55))
                .frame(width: PaneMetrics.timelineRailWidth)
                .padding(.vertical, 6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { session.selectBlock(block.id) }
        .onHover { isHovered = $0 }
        .contextMenu { overflowActions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command block: \(block.command), \(presentation.status.accessibilityLabel)")
    }


    private var hasVisibleOutput: Bool {
        !block.output.isEmpty
    }

    private var plainTextOutput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if block.outputKind == .excerpt {
                Text("Stored output excerpt")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.vertical) {
                CommandClickableTextView(
                    text: block.output,
                    font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    textColor: .labelColor
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            .frame(maxHeight: PaneMetrics.blockOutputMaxHeight)
            .help("Command-click links to open them")
        }
    }

    private var blockSurface: Color {
        if isSelected {
            return PaneTheme.selectedBlockBackground.opacity(
                colorSchemeContrast == .increased ? 0.65 : 0.28
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
        presentation.directoryLabel
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch block.state {
        case .running:
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                Text(block.statusText)
            }
            .foregroundStyle(.secondary)
            .font(.caption.monospacedDigit())

        case .completed(let exitCode) where exitCode == 0:
            Image(systemName: "checkmark")
                .accessibilityLabel(presentation.status.accessibilityLabel)
                .help("Succeeded")
                .font(.caption)
                .foregroundStyle(statusColor)

        default:
            Label(presentation.status.compactLabel ?? block.statusText, systemImage: presentation.status.symbolName)
                .font(.caption.monospacedDigit())
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch block.state {
        case .completed(let exitCode): exitCode == 0 ? .green : .red
        case .interrupted: .secondary
        case .unknown: .secondary
        case .queued, .running: .secondary
        }
    }

    private var timelineRailColor: Color {
        switch block.state {
        case .completed(let exitCode):
            return exitCode == 0 ? PaneTheme.separator : .red
        case .interrupted, .unknown, .queued:
            return PaneTheme.separator
        case .running:
            return PaneTheme.separator
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
            .disabled(!block.isRerunnable)
            .help(block.isRerunnable ? "Edit and rerun" : "Rerun unavailable for sensitive or redacted commands")

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
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(PaneTheme.blockBackground)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
    }

    @ViewBuilder
    private var overflowActions: some View {
        Button("Copy Command", systemImage: "text.badge.plus") {
            session.copyCommand(id: block.id)
        }
        Button("Copy Output", systemImage: "doc.on.doc") {
            session.copyOutput(id: block.id)
        }
        Button("Copy Command and Output", systemImage: "doc.on.clipboard") {
            session.copyCommandAndOutput(id: block.id)
        }
        Button("Copy Working Directory", systemImage: "folder") {
            session.copyWorkingDirectory(id: block.id)
        }

        Divider()

        Button("Edit in Composer", systemImage: "pencil") {
            session.editBlock(id: block.id)
        }
        .disabled(!block.isRerunnable)
        Button("Run Again", systemImage: "arrow.clockwise") {
            session.runAgainBlock(id: block.id)
        }
        .disabled(!block.isRerunnable)
        Button("Run in Original Directory", systemImage: "folder.badge.gearshape") {
            session.runBlockInOriginalDirectory(id: block.id)
        }
        .disabled(!block.isRerunnable)

        Divider()

        Button("Delete Block", systemImage: "trash", role: .destructive) {
            session.removeBlock(id: block.id)
        }
    }
}

private struct ToolbarHoverSurface: View {
    let systemName: String
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
    }
}
