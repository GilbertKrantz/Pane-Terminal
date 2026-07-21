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
                LazyVStack(spacing: 8) {
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
                .padding(.top, 8)
                .padding(.bottom, 10)
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
