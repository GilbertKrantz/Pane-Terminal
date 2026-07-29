import AppKit
import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var workspace: TerminalWorkspaceController
    @State private var didRestore = false
    @State private var renamingTabID: UUID?
    @State private var renameDraft = ""
    @State private var hoveredTabID: UUID?
    @State private var isNewTabHovered = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if let tab = workspace.selectedTab {
                if tab.showsInterruptedSessionNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("The previous process in this tab ended when Pane closed. A fresh shell was started.")
                        Spacer()
                        Button {
                            tab.showsInterruptedSessionNotice = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss previous session notice")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.08))
                }
                ContentView(session: tab.session)
                    .id(tab.id)
            } else {
                ProgressView("Restoring workspace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard !didRestore else { return }
            didRestore = true
            await workspace.restoreWorkspace()
        }
        .alert("Close this tab?", isPresented: closeConfirmationBinding) {
            Button("Cancel", role: .cancel) { workspace.pendingCloseTab = nil }
            Button("Close Tab", role: .destructive) {
                guard let id = workspace.pendingCloseTab?.id else { return }
                Task { await workspace.closeTab(id: id, policy: .force) }
            }
        } message: {
            Text("A process is still running: \(workspace.pendingCloseTab?.session.foregroundProcessName ?? "terminal process"). Closing the tab will terminate the process and its shell.")
        }
        .alert("Tab limit reached", isPresented: limitBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pane supports up to \(TerminalWorkspaceController.maximumLiveTabs) live tabs.")
        }
        .alert("Rename Tab", isPresented: renameBinding) {
            TextField("Tab title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingTabID = nil }
            Button("Rename") {
                workspace.tabs.first { $0.id == renamingTabID }?.rename(renameDraft)
                renamingTabID = nil
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(tab, index: index)
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 4) {
                Button {
                    Task { await workspace.createTab() }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            isNewTabHovered ? PaneTheme.hoveredTabBackground : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("New Tab (⌘T)")
                .onHover { isNewTabHovered = $0 }
                if workspace.tabs.count > 1 {
                    overflowMenu
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: PaneMetrics.tabStripHeight)
        .background(PaneTheme.tabStripBackground)
    }

    private func tabButton(_ tab: TerminalTab, index: Int) -> some View {
        let presentation = tab.presentation(
            isSelected: workspace.selectedTabID == tab.id,
            index: index,
            count: workspace.tabs.count
        )
        return HStack(spacing: 7) {
            tabActivityIndicator(presentation.activity)
            Text(presentation.title)
                .font(.system(.body, design: .default, weight: presentation.isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(presentation.truncation == .middle ? .middle : .tail)
                .frame(minWidth: 70, maxWidth: 190, alignment: .leading)
            Button {
                Task { await workspace.closeTab(id: tab.id, policy: .requestUserConfirmation) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 108, idealWidth: 164, maxWidth: 220, minHeight: 28)
        .background(
            presentation.isSelected
                ? PaneTheme.selectedTabBackground(increasedContrast: colorSchemeContrast == .increased)
                : (hoveredTabID == tab.id ? PaneTheme.hoveredTabBackground : .clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            if presentation.isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        PaneTheme.selectedTabBorder(increasedContrast: colorSchemeContrast == .increased),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectTab(id: tab.id) }
        .onHover { hoveredTabID = $0 ? tab.id : nil }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first,
                  let draggedID = UUID(uuidString: rawID),
                  draggedID != tab.id else { return false }
            workspace.moveTab(id: draggedID, to: index)
            return true
        }
        .help(presentation.tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(
            presentation.isSelected ? [.isButton, .isSelected] : .isButton
        )
        .contextMenu {
            Button("New Tab") { Task { await workspace.createTab() } }
            Button("Duplicate Tab") { Task { await workspace.duplicateTab(id: tab.id) } }
            Divider()
            Button("Move Tab Left") { workspace.moveTab(id: tab.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Tab Right") { workspace.moveTab(id: tab.id, to: index + 1) }
                .disabled(index == workspace.tabs.count - 1)
            Button("Rename Tab…") { beginRenaming(tab) }
            Button("Reset Automatic Title") { tab.resetAutomaticTitle() }
                .disabled(tab.titleSource != .custom)
            Button("Copy Working Directory") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.currentDirectory.path, forType: .string)
            }
            Divider()
            Button("Close Tab") { Task { await workspace.closeTab(id: tab.id, policy: .requestUserConfirmation) } }
        }
    }

    @ViewBuilder
    private func tabActivityIndicator(_ activity: TabActivityPresentation) -> some View {
        switch activity.indicator {
        case .dot:
            Circle()
                .fill(activityColor(activity.colorRole))
                .frame(width: activity.indicatorSize, height: activity.indicatorSize)
                .frame(width: 8, height: 8)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: activity.indicatorSize, weight: .semibold))
                .foregroundStyle(activityColor(activity.colorRole))
                .frame(width: 8, height: 8)
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                Button {
                    workspace.selectTab(id: tab.id)
                } label: {
                    HStack {
                        if workspace.selectedTabID == tab.id {
                            Image(systemName: "checkmark")
                        }
                        Text("\(index + 1). \(tab.title)")
                        Text(tab.currentDirectory.path)
                        Text(tab.activityState.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .frame(width: 24, height: 26)
        }
        .menuStyle(.borderlessButton)
        .help("All Tabs")
    }

    private func beginRenaming(_ tab: TerminalTab) {
        renameDraft = tab.title
        renamingTabID = tab.id
    }

    private func activityColor(_ role: TabActivityColorRole) -> Color {
        switch role {
        case .muted: return .secondary
        case .accent: return .accentColor
        case .failure: return .red
        }
    }

    private var closeConfirmationBinding: Binding<Bool> {
        Binding(get: { workspace.pendingCloseTab != nil }, set: { if !$0 { workspace.pendingCloseTab = nil } })
    }

    private var limitBinding: Binding<Bool> {
        Binding(get: { workspace.creationLimitReached }, set: { _ in })
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingTabID != nil },
            set: { if !$0 { renamingTabID = nil } }
        )
    }
}
