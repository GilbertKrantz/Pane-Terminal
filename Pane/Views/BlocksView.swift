import SwiftUI

struct BlocksView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedFinalizedBlockCount = 0

    private enum TimelineAnchor: Hashable {
        case bottom
    }

    private var finalizedBlocks: [CommandBlock] {
        session.visibleBlocks.filter { block in
            switch block.state {
            case .completed, .interrupted, .unknown:
                return true
            case .queued, .running:
                return false
            }
        }
    }

    private var lastFinalizedBlockID: UUID? {
        finalizedBlocks.last?.id
    }

    private var liveBlocks: [CommandBlock] {
        finalizedBlocks.filter { $0.origin == .live }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                .frame(minHeight: PaneMetrics.systemEventHeight)
                .accessibilityLabel("Shell restarted at \(restartedAt.formatted(date: .omitted, time: .shortened)), \(restartDirectory)")
            }
            if let notice = session.scrollbackPruningNotice {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox")
                    Text(notice.message)
                    Spacer(minLength: 8)
                    Button("Dismiss") {
                        session.dismissScrollbackPruningNotice()
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PaneMetrics.blockOuterInset + PaneMetrics.blockInnerInset)
                .frame(minHeight: PaneMetrics.systemEventHeight)
                .accessibilityElement(children: .combine)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: PaneMetrics.blockVerticalSpacing) {
                        ForEach(session.restoredSessionOrder, id: \.self) { sessionID in
                            if let boundary = session.sessionBoundaries[sessionID] {
                                SessionBoundaryView(boundary: boundary)
                            }
                            ForEach(restoredBlocks(for: sessionID)) { block in
                                commandBlockView(block)
                            }
                        }

                        if !session.restoredSessionOrder.isEmpty,
                           let boundary = session.newShellBoundary {
                            NewShellBoundaryView(boundary: boundary)
                        }

                        ForEach(liveBlocks) { block in
                            commandBlockView(block)
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
                .onAppear {
                    let shouldRestoreAfterTerminal = session.consumeBlocksViewportRestoreRequest()
                    renderedFinalizedBlockCount = finalizedBlocks.count
                    if shouldRestoreAfterTerminal || !finalizedBlocks.isEmpty {
                        restoreTimelineViewport(using: proxy)
                    }
                }
                .onChange(of: session.blockTimelineGeneration) { _, _ in
                    let currentCount = finalizedBlocks.count
                    let needsBulkViewportRecovery = currentCount < renderedFinalizedBlockCount
                        || currentCount > renderedFinalizedBlockCount + 1
                    renderedFinalizedBlockCount = currentCount
                    if needsBulkViewportRecovery {
                        restoreTimelineViewport(using: proxy)
                    }
                }
                .onChange(of: session.selectedBlockID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
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
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
            }
            DispatchQueue.main.async {
                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private func restoreTimelineViewport(using proxy: ScrollViewProxy) {
        // BlocksView is removed while an expanded alternate-screen terminal is
        // mounted. On re-entry, SwiftUI can briefly reuse the terminal-sized
        // AppKit scroll geometry before the lazy timeline has laid itself out,
        // leaving the visible rect below every block. Re-pin after the first
        // two layout turns and once more after AppKit has committed its size.
        DispatchQueue.main.async {
            proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
            DispatchQueue.main.async {
                proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(TimelineAnchor.bottom, anchor: .bottom)
                }
            }
        }
    }

    private func restoredBlocks(for sessionID: UUID) -> [CommandBlock] {
        finalizedBlocks.filter { block in
            if case .restored(let restoredSessionID) = block.origin {
                return restoredSessionID == sessionID
            }
            return false
        }
    }

    private func commandBlockView(_ block: CommandBlock) -> some View {
        CommandBlockView(
            block: block,
            isSelected: session.selectedBlockID == block.id,
            session: session
        )
        .id(block.id)
    }
}

struct BlockSearchBar: View {
    @ObservedObject var session: TerminalSession
    @FocusState private var isSearchFocused: Bool

    private var matches: [CommandBlock] {
        session.blockSearchMatches
    }

    private var currentMatch: Int {
        guard let selected = session.selectedBlockID,
              let index = matches.firstIndex(where: { $0.id == selected }) else { return matches.isEmpty ? 0 : 1 }
        return index + 1
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commands, output, directories, and status", text: $session.blockSearchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        session.selectPreviousSearchMatch()
                    } else {
                        session.selectNextSearchMatch()
                    }
                    return .handled
                }
            Picker("Search scope", selection: $session.blockSearchFilter) {
                ForEach(BlockSearchFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 104)
            Text("\(currentMatch) / \(matches.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Search result \(currentMatch) of \(matches.count)")
            Button { session.selectPreviousSearchMatch() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).help("Previous match (Shift-Return)").disabled(matches.isEmpty)
            Button { session.selectNextSearchMatch() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Next match (Return)").disabled(matches.isEmpty)
            Button { session.dismissBlockSearch() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close Search (Escape)").accessibilityLabel("Close Search")
        }
        .controlSize(.small)
        .padding(.horizontal, PaneMetrics.blockOuterInset + PaneMetrics.blockInnerInset)
        .frame(height: PaneMetrics.searchRowHeight)
        .background(PaneTheme.contentSurface)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { isSearchFocused = true }
        .onChange(of: session.blockSearchFocusGeneration) { _, _ in isSearchFocused = true }
        .onChange(of: session.blockSearchText) { _, _ in session.ensureBlockSearchSelection() }
        .onChange(of: session.blockSearchFilter) { _, _ in session.ensureBlockSearchSelection() }
        .onExitCommand { session.dismissBlockSearch() }
    }
}

private struct SessionBoundaryView: View {
    let boundary: TerminalSession.SessionBoundary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: boundary.lifecycle == .interrupted ? "exclamationmark.triangle" : "clock.arrow.circlepath")
            Text(boundary.lifecycle == .interrupted ? "Previous session interrupted" : "Previous session closed")
            Text("· \(boundary.lastActiveAt.formatted(date: .abbreviated, time: .shortened)) · \(displayDirectory)")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: PaneMetrics.systemEventHeight)
        .padding(.horizontal, PaneMetrics.blockInnerInset)
        .accessibilityElement(children: .combine)
    }

    private var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return boundary.workingDirectory == home ? "~" : boundary.workingDirectory.replacingOccurrences(of: home + "/", with: "~/")
    }
}

private struct NewShellBoundaryView: View {
    let boundary: TerminalSession.NewShellBoundary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal")
            Text("New shell started")
            Text("· \(displayDirectory)").font(.caption.monospaced()).foregroundStyle(.tertiary)
            if boundary.previousDirectoryUnavailable {
                Text("· Previous directory unavailable").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: PaneMetrics.systemEventHeight)
        .padding(.horizontal, PaneMetrics.blockInnerInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New shell started, \(displayDirectory)")
    }

    private var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return boundary.workingDirectory == home ? "~" : boundary.workingDirectory.replacingOccurrences(of: home + "/", with: "~/")
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

            TerminalViewRepresentable(
                session: session,
                presentation: .embeddedDirect,
                mountGeneration: session.focusGeneration
            )
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
                .strokeBorder(PaneTheme.separator.opacity(0.75), lineWidth: 0.5)
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
