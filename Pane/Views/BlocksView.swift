import SwiftUI

struct BlocksView: View {
    let session: TerminalSession
    @ObservedObject private var presentation: BlocksPresentationState

    init(session: TerminalSession) {
        self.session = session
        self.presentation = session.blocksPresentation
        session.blocksPresentation.refresh()
    }

    var body: some View {
        let snapshot = presentation.snapshot
        VStack(spacing: 0) {
            if let notice = snapshot.removalNotice {
                HStack {
                    Text(notice)
                    Spacer()
                    Button("Undo") { session.undoBlockRemoval() }
                    Button("Dismiss") { session.dismissBlockRemovalNotice() }
                }
                .font(.caption)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            if let restartedAt = snapshot.restartedAt {
                Label("Shell restarted at \(restartedAt.formatted(date: .omitted, time: .shortened)) · fresh shell in \(snapshot.directory ?? "home directory")",
                      systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PaneMetrics.blockOuterInset + PaneMetrics.blockInnerInset)
                    .frame(minHeight: PaneMetrics.systemEventHeight)
                    .accessibilityLabel("Shell restarted at \(restartedAt.formatted(date: .omitted, time: .shortened)), \(snapshot.directory ?? "home directory")")
            }
            if let notice = snapshot.pruningNotice {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox")
                    Text(notice.message)
                    Spacer(minLength: 8)
                    Button("Dismiss") { session.dismissScrollbackPruningNotice() }.buttonStyle(.borderless)
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PaneMetrics.blockOuterInset + PaneMetrics.blockInnerInset)
                .frame(minHeight: PaneMetrics.systemEventHeight)
                .accessibilityElement(children: .combine)
            }
            RecycledBlocksTimeline(snapshot: snapshot, content: { row in
                rowContent(row, selectedID: snapshot.selectedID)
            }, onDisplay: { ids in
                guard session.visibilityState == .selected else { return }
                session.presentationTimings.didSubmitDisplay(visibleBlocks: ids)
            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PaneTheme.contentSurface)
        }
    }

    private func rowContent(_ row: BlocksTimelineRow, selectedID: UUID?) -> AnyView {
        switch row {
        case .block(let block):
            return AnyView(CommandBlockView(block: block, isSelected: selectedID == block.id, session: session))
        case .session(let boundary): return AnyView(SessionBoundaryView(boundary: boundary))
        case .newShell(let boundary): return AnyView(NewShellBoundaryView(boundary: boundary))
        case .queue(let blocks): return AnyView(queuedCommands(blocks))
        case .empty:
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Text("Type a command below").font(.headline)
                Text("Blocks keeps completed commands here. Switch to Terminal for interactive programs.")
                    .foregroundStyle(.primary.opacity(0.75))
                Button("Using Pane") { NotificationCenter.default.post(name: .showPaneHelp, object: nil) }
                    .buttonStyle(.link)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12))
        }
    }

    private func queuedCommands(_ blocks: [CommandBlock]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up next · \(blocks.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(block.command)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        guard index > 0 else { return }
                        session.moveQueuedBlock(id: block.id, before: blocks[index - 1].id)
                    } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move earlier")
                        .accessibilityLabel("Move queued command earlier")
                    Button {
                        guard index + 1 < blocks.count else { return }
                        session.moveQueuedBlock(
                            id: blocks[index + 1].id,
                            before: block.id
                        )
                    } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index + 1 == blocks.count)
                        .help("Move later")
                        .accessibilityLabel("Move queued command later")
                    Button { session.editBlock(id: block.id) } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit queued command")
                    Button { session.removeQueuedBlock(id: block.id) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove queued command")
                }
                .padding(.horizontal, PaneMetrics.blockInnerInset)
                .frame(minHeight: 36)
                .background(
                    session.selectedBlockID == block.id
                        ? PaneTheme.selectedBlockBackground.opacity(0.28)
                        : PaneTheme.blockBackground,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
                .onTapGesture { session.selectBlock(block.id) }
                .accessibilityLabel("Queued command \(index + 1), \(block.command)")
                .id(block.id)
            }
        }
        .padding(.top, 4)
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

                Button("Terminal") {
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
                placement: .expandedAlternateScreen(blockID: block.id)
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
