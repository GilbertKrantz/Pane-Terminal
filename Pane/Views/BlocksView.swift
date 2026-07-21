import SwiftUI

struct BlocksView: View {
    @ObservedObject var session: TerminalSession

    private var finalizedBlocks: [CommandBlock] {
        session.blocks.filter { block in
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
                    }
                }
                .padding(.horizontal, PaneMetrics.blockOuterInset)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            // Keep the newest command next to the pinned composer. When the
            // timeline exceeds the viewport, older blocks overflow upward.
            .defaultScrollAnchor(.bottom)
            .background(PaneTheme.contentSurface)
            .onChange(of: session.selectedBlockID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .onChange(of: lastFinalizedBlockID) { _, blockID in
                guard let blockID else { return }
                // Defer until LazyVStack has materialized the newly finalized
                // row. Scrolling does not mutate observable session state.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(blockID, anchor: .bottom)
                    }
                }
            }
        }
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
