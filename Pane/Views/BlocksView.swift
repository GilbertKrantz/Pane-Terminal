import SwiftUI

struct BlocksView: View {
    @ObservedObject var session: TerminalSession

    private enum TimelineAnchor: Hashable {
        case bottom
    }

    private var finalizedBlocks: [CommandBlock] {
        session.visibleBlocks.filter { block in
            switch block.state {
            case .completed, .interrupted:
                return true
            case .queued, .running:
                return false
            }
        }
    }

    private var lastFinalizedBlockID: UUID? {
        finalizedBlocks.last?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            BlockSearchBar(session: session, matchCount: finalizedBlocks.count)
            if let restartedAt = session.lastShellRestartAt {
                let restartDirectory = session.currentDirectory ?? "home directory"
                Label(
                    "Shell restarted at \(restartedAt.formatted(date: .omitted, time: .shortened)) · fresh shell in \(restartDirectory)",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PaneMetrics.blockOuterInset + PaneMetrics.blockInnerInset)
                .padding(.vertical, 6)
                .background(PaneTheme.subtleControlFill)
            }
            Divider().overlay(PaneTheme.separator.opacity(0.5))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(finalizedBlocks) { block in
                            CommandBlockView(
                                block: block,
                                isSelected: session.selectedBlockID == block.id,
                                session: session
                            )
                            .id(block.id)

                            if block.id == lastVisibleRestoredBlockID,
                               let boundary = session.sessionBoundary {
                                SessionBoundaryView(boundary: boundary)
                            }
                        }

                        Color.clear
                            .frame(height: 8)
                            .id(TimelineAnchor.bottom)
                    }
                    .padding(.horizontal, PaneMetrics.blockOuterInset)
                    .padding(.top, 6)
                }
                .defaultScrollAnchor(.bottom)
                .background(PaneTheme.contentSurface)
                .onChange(of: session.selectedBlockID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
                .onChange(of: lastFinalizedBlockID) { _, blockID in
                    guard blockID != nil else { return }
                    scrollToTimelineBottom(using: proxy)
                }
            }
        }
    }

    private func scrollToTimelineBottom(using proxy: ScrollViewProxy) {
        // The finalized AppKit output view receives its proposed width during
        // the next layout pass. Scroll to the end marker, then pin it again on
        // the following pass so newly wrapped output cannot leave the viewport
        // slightly above the true bottom.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
            }
            DispatchQueue.main.async {
                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private var lastVisibleRestoredBlockID: UUID? {
        finalizedBlocks.last(where: { session.restoredBlockIDs.contains($0.id) })?.id
    }
}

private struct BlockSearchBar: View {
    @ObservedObject var session: TerminalSession
    let matchCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commands, output, directories, and status", text: $session.blockSearchText)
                .textFieldStyle(.plain)
            Picker("Filter", selection: $session.blockSearchFilter) {
                ForEach(BlockSearchFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 112)
            Text("\(matchCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { session.selectPreviousSearchMatch() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).help("Previous match")
            Button { session.selectNextSearchMatch() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Next match")
            Menu {
                Button("Collapse All Completed") { session.setAllCompletedBlocksCollapsed(true) }
                Button("Expand All Matches") {
                    for block in session.visibleBlocks where block.isCollapsed {
                        session.toggleBlockCollapsed(id: block.id)
                    }
                }
            } label: { Image(systemName: "rectangle.compress.vertical") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .controlSize(.small)
        .padding(.horizontal, PaneMetrics.blockOuterInset + PaneMetrics.blockInnerInset)
        .padding(.vertical, 7)
        .background(PaneTheme.contentSurface)
    }
}

private struct SessionBoundaryView: View {
    let boundary: TerminalSession.SessionBoundary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(boundary.lifecycle == .interrupted ? "Previous session was interrupted" : "Previous session", systemImage: boundary.lifecycle == .interrupted ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
            Text("Last active \(boundary.lastActiveAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text(boundary.usedDirectoryFallback
                ? "Pane restarted with a fresh shell in the home directory because the previous directory was unavailable."
                : "Pane restarted with a fresh shell in \(displayDirectory).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PaneTheme.subtleControlFill, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return boundary.restoredDirectory == home ? "~" : boundary.restoredDirectory.replacingOccurrences(of: home + "/", with: "~/")
    }
}

struct AuthoritativeInputCommandView: View {
    let block: CommandBlock
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(block.command.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Label(inputLabel, systemImage: inputSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusText(at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button {
                    session.sendInterrupt()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Send Interrupt")

                Button("Full Terminal") {
                    session.setMode(.terminal)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .frame(minHeight: 28)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Running \(inputLabel.lowercased()) command \(block.command)")

            TerminalViewRepresentable(session: session)
                .id("authoritative-active-input")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(PaneMetrics.blockInnerInset)
        .background(
            PaneTheme.blockBackground,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
        }
        .padding(.horizontal, PaneMetrics.blockOuterInset)
        .padding(.vertical, 8)
        .background(PaneTheme.contentSurface)
    }

    private func statusText(at date: Date) -> String {
        guard let startedAt = block.startedAt else { return "Starting…" }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        if elapsed < 1 { return "Running" }
        if elapsed < 60 { return "Running for \(Int(elapsed))s" }
        return "Running for \(Int(elapsed / 60))m"
    }

    private var inputLabel: String {
        if session.isSecureInputActive { return "Secure Input" }
        if session.isAlternateScreenActive { return "Alternate Screen" }
        return "Direct Input"
    }

    private var inputSymbol: String {
        if session.isSecureInputActive { return "lock.fill" }
        if session.isAlternateScreenActive { return "rectangle.inset.filled" }
        return "keyboard"
    }
}
