import AppKit
import Combine
import SwiftUI

enum BlocksTimelineRow: Equatable, Identifiable {
    enum ID: Hashable { case block(UUID), session(UUID), newShell, queue, empty }
    case block(CommandBlock)
    case session(TerminalSession.SessionBoundary)
    case newShell(TerminalSession.NewShellBoundary)
    case queue([CommandBlock])
    case empty

    var id: ID {
        switch self {
        case .block(let block): return .block(block.id)
        case .session(let boundary): return .session(boundary.sessionID)
        case .newShell: return .newShell
        case .queue: return .queue
        case .empty: return .empty
        }
    }

    var estimatedHeight: CGFloat {
        switch self {
        case .block(let block):
            return block.isCollapsed || block.output.isEmpty ? 76 : 100
        case .session, .newShell: return PaneMetrics.systemEventHeight
        case .queue(let blocks): return CGFloat(blocks.count) * 40 + 28
        case .empty: return 100
        }
    }
}

struct BlocksPresentationSnapshot: Equatable {
    var rows: [BlocksTimelineRow] = []
    var selectedID: UUID?
    var lastFinalizedID: UUID?
    var finalizedCount = 0
    var removalNotice: String?
    var restartedAt: Date?
    var directory: String?
    var pruningNotice: ScrollbackPruningNotice?
}

/// Coalesces lifecycle publications, and publishes only data the timeline uses.
/// Draft edits with a nonempty history never invalidate the observed view tree.
@MainActor
final class BlocksPresentationState: ObservableObject {
    @Published private(set) var snapshot = BlocksPresentationSnapshot()
    private weak var session: TerminalSession?
    private var observation: AnyCancellable?
    private var refreshScheduled = false

    init(session: TerminalSession) {
        self.session = session
        refresh()
        observation = session.objectWillChange.sink { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    func refresh() {
        guard let session else { return }
        let blocks = session.visibleBlocks.filter(\.isFinalized)
        var restored: [UUID: [CommandBlock]] = [:]
        var live: [CommandBlock] = []
        for block in blocks {
            switch block.origin {
            case .live: live.append(block)
            case .restored(let id): restored[id, default: []].append(block)
            }
        }
        var rows: [BlocksTimelineRow] = []
        for id in session.restoredSessionOrder {
            if let boundary = session.sessionBoundaries[id] { rows.append(.session(boundary)) }
            rows.append(contentsOf: (restored[id] ?? []).map(BlocksTimelineRow.block))
        }
        if !session.restoredSessionOrder.isEmpty, let boundary = session.newShellBoundary {
            rows.append(.newShell(boundary))
        }
        rows.append(contentsOf: live.map(BlocksTimelineRow.block))
        let queue = session.queuedBlocks
        if !queue.isEmpty { rows.append(.queue(queue)) }
        if session.blocks.isEmpty, session.commandDraft.isEmpty, session.isShellReadyForInput {
            rows.append(.empty)
        }
        let next = BlocksPresentationSnapshot(
            rows: rows, selectedID: session.selectedBlockID,
            lastFinalizedID: blocks.last?.id, finalizedCount: blocks.count,
            removalNotice: session.blockRemovalNotice, restartedAt: session.lastShellRestartAt,
            directory: session.currentDirectory, pruningNotice: session.scrollbackPruningNotice
        )
        if snapshot != next { snapshot = next }
    }
}

struct RecycledBlocksTimeline: NSViewRepresentable {
    let snapshot: BlocksPresentationSnapshot
    let content: (BlocksTimelineRow) -> AnyView
    var onDisplay: ((Set<UUID>) -> Void)?

    func makeNSView(context: Context) -> BlocksTimelineScrollView {
        BlocksTimelineScrollView()
    }

    func updateNSView(_ view: BlocksTimelineScrollView, context: Context) {
        view.update(snapshot: snapshot, content: content, onDisplay: onDisplay)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BlocksTimelineScrollView,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 800,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 400)
    }
}

/// The document always has explicit geometry. Unlike estimated SwiftUI lazy
/// stacks, a scroll destination never depends on materializing preceding rows.
/// Visible rows are measured and reconciled synchronously while retaining the
/// same bottom or row-relative anchor, before the next display pass.
@MainActor
final class BlocksTimelineScrollView: NSScrollView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
        var didDisplay: (() -> Void)?
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            didDisplay?()
        }
    }
    private struct MountedRow {
        var row: BlocksTimelineRow
        var selected: Bool
        let host: NSHostingView<AnyView>
    }
    private struct Anchor {
        let id: BlocksTimelineRow.ID?
        let offset: CGFloat
        let bottom: Bool
    }

    private let document = DocumentView()
    private var snapshot = BlocksPresentationSnapshot()
    private var makeContent: ((BlocksTimelineRow) -> AnyView)?
    private var onDisplay: ((Set<UUID>) -> Void)?
    private var mounted: [BlocksTimelineRow.ID: MountedRow] = [:]
    private var heights: [BlocksTimelineRow.ID: CGFloat] = [:]
    private var frames: [NSRect] = []
    private var measuredWidth: CGFloat = 0
    private var isReconciling = false
    private var initialLayout = true
    private var pendingBottom = true
    private var pendingSelection: UUID?
    private var boundsObservation: NSObjectProtocol?
    private var lastDisplayedIDs: Set<UUID> = []
    private var updateAnchor: Anchor?
    private var lastVisibleRect: NSRect?
    private var lastViewportHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        boundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        document.didDisplay = { [weak self] in
            guard let self, self.window != nil else { return }
            let ids = self.lastDisplayedIDs
            // Finish after the hosting subviews' drawing turn, not in the
            // representable update or during geometry reconciliation.
            DispatchQueue.main.async { [weak self] in self?.onDisplay?(ids) }
        }
        setAccessibilityLabel("Command history")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObservation { NotificationCenter.default.removeObserver(boundsObservation) }
    }

    func update(snapshot next: BlocksPresentationSnapshot,
                content: @escaping (BlocksTimelineRow) -> AnyView,
                onDisplay: ((Set<UUID>) -> Void)?) {
        makeContent = content
        self.onDisplay = onDisplay
        guard snapshot != next || initialLayout else { return }
        updateAnchor = currentAnchor()
        let oldRows = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        let retained = Set(next.rows.map(\.id))
        heights = heights.filter { retained.contains($0.key) }
        for row in next.rows where oldRows[row.id] != row { heights.removeValue(forKey: row.id) }
        pendingBottom = pendingBottom || next.lastFinalizedID != snapshot.lastFinalizedID
            || next.finalizedCount < snapshot.finalizedCount
            || next.finalizedCount > snapshot.finalizedCount + 1
            || next.rows.last?.id == .queue && next.rows != snapshot.rows
        if !pendingBottom, next.selectedID != snapshot.selectedID {
            pendingSelection = next.selectedID
        }
        snapshot = next
        needsLayout = true
        reconcile()
    }

    override func layout() {
        super.layout()
        reconcile()
    }

    private func currentAnchor(rect previous: NSRect? = nil) -> Anchor {
        let rect = previous ?? documentVisibleRect
        let bottom = initialLayout || abs(rect.maxY - document.bounds.maxY) < 2
        let index = frames.firstIndex { $0.maxY > rect.minY }
        return Anchor(id: index.map { snapshot.rows[$0].id },
                      offset: index.map { rect.minY - frames[$0].minY } ?? 0, bottom: bottom)
    }

    private func buildFrames(width: CGFloat, viewportHeight: CGFloat) {
        var y: CGFloat = 6
        frames = snapshot.rows.map { row in
            let height = heights[row.id] ?? row.estimatedHeight
            defer { y += height + PaneMetrics.blockVerticalSpacing }
            return NSRect(x: PaneMetrics.blockOuterInset, y: y, width: width, height: height)
        }
        let total = y + 8
        if total < viewportHeight {
            let shift = viewportHeight - total
            frames = frames.map { $0.offsetBy(dx: 0, dy: shift) }
        }
        let size = NSSize(width: contentView.bounds.width, height: max(viewportHeight, total))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    private func restore(_ anchor: Anchor, selection: UUID?) {
        let maximum = max(0, document.bounds.height - contentView.bounds.height)
        let y: CGFloat
        if let selection, let index = snapshot.rows.firstIndex(where: { $0.id == .block(selection) }) {
            y = frames[index].midY - contentView.bounds.height / 2
        } else if pendingBottom || anchor.bottom {
            y = maximum
        } else if let id = anchor.id, let index = snapshot.rows.firstIndex(where: { $0.id == id }) {
            y = frames[index].minY + anchor.offset
        } else {
            y = contentView.bounds.minY
        }
        let origin = NSPoint(x: 0, y: min(maximum, max(0, y)))
        if abs(contentView.bounds.minY - origin.y) > 0.1 {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
    }

    private func reconcile() {
        guard !isReconciling, let makeContent else { return }
        let width = contentView.bounds.width - 2 * PaneMetrics.blockOuterInset
        let viewportHeight = contentView.bounds.height
        guard width.isFinite, width > 0, viewportHeight > 0 else { return }
        isReconciling = true
        defer { isReconciling = false }
        // AppKit can change the clip height before layout is called. Determine
        // whether we were at the bottom using the previous settled viewport,
        // rather than mistaking a resize for a user scroll away from it.
        let resized = abs(measuredWidth - width) > 0.1 || abs(lastViewportHeight - viewportHeight) > 0.1
        let anchor = updateAnchor ?? currentAnchor(rect: resized ? lastVisibleRect : nil)
        updateAnchor = nil
        let widthChanged = abs(measuredWidth - width) > 0.1
        if widthChanged {
            measuredWidth = width
            heights.removeAll(keepingCapacity: true)
        }
        let selection = pendingSelection
        // At most one extra viewport is prefetched. Each pass replaces an
        // estimate with an actual fitting height; mounting continues until the
        // current visible range is complete, never leaving an estimated gap.
        for _ in 0..<8 {
            buildFrames(width: width, viewportHeight: viewportHeight)
            restore(anchor, selection: selection)
            let visible = documentVisibleRect
            let range = visible.insetBy(dx: 0, dy: -min(240, viewportHeight / 2))
            var changedHeight = false
            var needed: Set<BlocksTimelineRow.ID> = []
            for (index, row) in snapshot.rows.enumerated() where frames[index].intersects(range) {
                needed.insert(row.id)
                let selected = row.id == snapshot.selectedID.map(BlocksTimelineRow.ID.block)
                var item: MountedRow
                if let existing = mounted[row.id] {
                    item = existing
                    if widthChanged || item.row != row || item.selected != selected {
                        item.host.rootView = makeContent(row)
                            .frame(width: width, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).eraseToAnyView()
                        item.row = row
                        item.selected = selected
                    }
                } else {
                    let host = NSHostingView(rootView: makeContent(row)
                        .frame(width: width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).eraseToAnyView())
                    host.sizingOptions = [.intrinsicContentSize]
                    item = MountedRow(row: row, selected: selected, host: host)
                    document.addSubview(host)
                }
                item.host.frame = frames[index]
                item.host.layoutSubtreeIfNeeded()
                if heights[row.id] == nil {
                    let height = max(1, ceil(item.host.fittingSize.height))
                    heights[row.id] = height
                    changedHeight = changedHeight || abs(height - frames[index].height) > 0.1
                }
                mounted[row.id] = item
            }
            for (id, item) in mounted where !needed.contains(id) {
                // Retain a focused editor/row while scrolling to preserve
                // native text selection and the keyboard responder chain.
                if let responder = window?.firstResponder as? NSView,
                   responder === item.host || responder.isDescendant(of: item.host) { continue }
                item.host.removeFromSuperview()
                mounted.removeValue(forKey: id)
            }
            if !changedHeight { break }
        }
        buildFrames(width: width, viewportHeight: viewportHeight)
        restore(anchor, selection: selection)
        for (index, row) in snapshot.rows.enumerated() {
            mounted[row.id]?.host.frame = frames[index]
        }
        lastDisplayedIDs = Set(snapshot.rows.enumerated().compactMap { index, row in
            guard frames[index].intersects(documentVisibleRect), case .block(let block) = row else { return nil }
            return block.id
        })
        pendingBottom = false
        pendingSelection = nil
        initialLayout = false
        lastVisibleRect = documentVisibleRect
        lastViewportHeight = viewportHeight
        document.needsDisplay = true
    }
}

private extension View {
    func eraseToAnyView() -> AnyView { AnyView(self) }
}
