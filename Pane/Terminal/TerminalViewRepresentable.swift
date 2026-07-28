import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

private func applyPaneTerminalPalette(to terminalView: TerminalView) {
    let background = PaneTheme.terminalBackground(
        for: terminalView.effectiveAppearance
    )
    let foreground = PaneTheme.terminalForeground(
        for: terminalView.effectiveAppearance
    )
    if !terminalView.nativeBackgroundColor.isEqual(background) {
        terminalView.nativeBackgroundColor = background
    }
    if !terminalView.nativeForegroundColor.isEqual(foreground) {
        terminalView.nativeForegroundColor = foreground
    }
    if !terminalView.caretColor.isEqual(NSColor.controlAccentColor) {
        terminalView.caretColor = .controlAccentColor
    }
    if terminalView.layer?.backgroundColor != background.cgColor {
        terminalView.layer?.backgroundColor = background.cgColor
    }
}

private func applyFrozenBlockTerminalPalette(to terminalView: TerminalView) {
    let foreground = PaneTheme.terminalForeground(
        for: terminalView.effectiveAppearance
    )
    if !terminalView.nativeBackgroundColor.isEqual(NSColor.clear) {
        terminalView.nativeBackgroundColor = .clear
    }
    if !terminalView.nativeForegroundColor.isEqual(foreground) {
        terminalView.nativeForegroundColor = foreground
    }
    terminalView.layer?.backgroundColor = NSColor.clear.cgColor
}


struct TerminalViewportInsets: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = TerminalViewportInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    static let fullTerminal = TerminalViewportInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    static let embeddedDirect = TerminalViewportInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
}

enum AuthoritativeTerminalPresentation: Equatable {
    case embeddedDirect
    case fullTerminal

    var viewportInsets: TerminalViewportInsets {
        switch self {
        case .embeddedDirect: .embeddedDirect
        case .fullTerminal: .fullTerminal
        }
    }
}

final class AuthoritativeTerminalHostView: NSView {
    let terminalView: PaneTerminalView
    var onMountedIntoWindow: (() -> Void)?
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private(set) var viewportInsets = TerminalViewportInsets.zero

    init(terminalView: PaneTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        leadingConstraint = terminalView.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingConstraint = terminalView.trailingAnchor.constraint(equalTo: trailingAnchor)
        topConstraint = terminalView.topAnchor.constraint(equalTo: topAnchor)
        bottomConstraint = terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([leadingConstraint, trailingConstraint, topConstraint, bottomConstraint])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.onMountedIntoWindow?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setViewportInsets(_ insets: TerminalViewportInsets) {
        guard viewportInsets != insets else { return }
        viewportInsets = insets
        leadingConstraint.constant = insets.leading
        trailingConstraint.constant = -insets.trailing
        topConstraint.constant = insets.top
        bottomConstraint.constant = -insets.bottom
        needsLayout = true
    }

}

final class AuthoritativeTerminalMountView: NSView {
    var onMountedIntoWindow: (() -> Void)?
    private weak var mountedHostView: AuthoritativeTerminalHostView?
    private var hasPendingWindowMountCallback = false
    private var isWindowMountCallbackScheduled = false
    private var hasPendingPostMountLayoutCallback = false
    private var isPostMountLayoutCallbackScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleWindowMountCallbackIfNeeded()
    }

    override func layout() {
        super.layout()
        schedulePostMountLayoutCallbackIfNeeded()
    }

    @discardableResult
    func mount(_ hostView: AuthoritativeTerminalHostView) -> Bool {
        guard hostView.superview !== self else { return false }
        hostView.removeFromSuperview()
        hostView.frame = bounds
        hostView.autoresizingMask = [.width, .height]
        addSubview(hostView)
        mountedHostView = hostView
        hasPendingWindowMountCallback = true
        hasPendingPostMountLayoutCallback = true
        scheduleWindowMountCallbackIfNeeded()
        return true
    }

    func requestPostMountLayoutCallback() {
        hasPendingPostMountLayoutCallback = true
        needsLayout = true
    }

    private func scheduleWindowMountCallbackIfNeeded() {
        guard window != nil,
              hasPendingWindowMountCallback,
              !isWindowMountCallbackScheduled else { return }
        isWindowMountCallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isWindowMountCallbackScheduled = false
            guard self.window != nil,
                  self.hasPendingWindowMountCallback,
                  let hostView = self.mountedHostView,
                  hostView.superview === self else { return }
            self.hasPendingWindowMountCallback = false
            self.onMountedIntoWindow?()
        }
    }

    private func schedulePostMountLayoutCallbackIfNeeded() {
        guard window != nil,
              hasPendingPostMountLayoutCallback,
              !isPostMountLayoutCallbackScheduled else { return }
        isPostMountLayoutCallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPostMountLayoutCallbackScheduled = false
            guard self.window != nil,
                  self.hasPendingPostMountLayoutCallback,
                  let hostView = self.mountedHostView,
                  hostView.superview === self else { return }
            self.hasPendingPostMountLayoutCallback = false
            self.onMountedIntoWindow?()
        }
    }
}

final class PaneTerminalView: TerminalView {
    var onAlternateScreenChanged: ((Bool) -> Void)?
    var onTerminalResponse: ((ArraySlice<UInt8>) -> Void)?
    private var lastQueuedAlternateScreenState = false
    private var alternateScreenNotificationGeneration = 0

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Terminal-generated replies (DA, DSR, color queries, and similar)
        // must reach the PTY even while this view is hidden behind Blocks.
        // User keystrokes use TerminalViewDelegate.send instead, where the
        // current input mode is still enforced.
        if let onTerminalResponse {
            onTerminalResponse(data)
        } else {
            super.send(source: source, data: data)
        }
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)

        // SwiftTerm owns the normal/alternate buffers.  Invalidate the whole
        // backing surface before exposing the newly-active one so AppKit never
        // composites cells from the previous buffer while the throttled
        // SwiftTerm repaint is pending.
        source.updateFullScreen()
        setNeedsDisplay(bounds)
        layer?.setNeedsDisplay()

        let isAlternate = source.isCurrentBufferAlternate
        guard isAlternate != lastQueuedAlternateScreenState else { return }
        lastQueuedAlternateScreenState = isAlternate
        alternateScreenNotificationGeneration += 1
        let generation = alternateScreenNotificationGeneration

        // A buffer switch happens synchronously inside TerminalView.feed().
        // Publishing the SwiftUI mode from that callback is re-entrant; defer
        // it until the next main-loop turn, after the redraw was invalidated.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.alternateScreenNotificationGeneration == generation else { return }
            self.onAlternateScreenChanged?(self.terminal.isCurrentBufferAlternate)
        }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let presentation: AuthoritativeTerminalPresentation
    let mountGeneration: UInt64

    func makeNSView(context: Context) -> AuthoritativeTerminalMountView {
        let mountView = AuthoritativeTerminalMountView()
        mountView.onMountedIntoWindow = { [weak session] in
            session?.authoritativeTerminalDidRemount()
            session?.restoreAuthoritativeFocusAfterMount()
        }
        guard session.isCurrentTerminalMountGeneration(mountGeneration) else {
            return mountView
        }
        let hostView = session.makeAuthoritativeTerminalHostView()
        hostView.onMountedIntoWindow = { [weak session] in
            session?.authoritativeTerminalDidRemount()
            session?.restoreAuthoritativeFocusAfterMount()
        }
        applyPaneTerminalPalette(to: hostView.terminalView)
        mountView.mount(hostView)
        hostView.setViewportInsets(presentation.viewportInsets)
        mountView.requestPostMountLayoutCallback()
        session.restoreAuthoritativeFocusAfterMount()
        return mountView
    }

    func updateNSView(_ mountView: AuthoritativeTerminalMountView, context: Context) {
        guard session.isCurrentTerminalMountGeneration(mountGeneration) else {
            return
        }
        let hostView = session.makeAuthoritativeTerminalHostView()
        hostView.onMountedIntoWindow = { [weak session] in
            session?.authoritativeTerminalDidRemount()
            session?.restoreAuthoritativeFocusAfterMount()
        }
        let didReparent = mountView.mount(hostView)
        hostView.setViewportInsets(presentation.viewportInsets)
        mountView.requestPostMountLayoutCallback()
        applyPaneTerminalPalette(to: hostView.terminalView)
        hostView.terminalView.isHidden = false
        hostView.terminalView.terminal.updateFullScreen()
        hostView.terminalView.setNeedsDisplay(hostView.terminalView.bounds)
        hostView.terminalView.layer?.setNeedsDisplay()
        if didReparent {
            session.authoritativeTerminalDidRemount()
        }
        session.restoreAuthoritativeFocusAfterMount()
    }

    static func dismantleNSView(_ mountView: AuthoritativeTerminalMountView, coordinator: ()) {
        mountView.onMountedIntoWindow = nil
    }
}

/// A read-only terminal emulator used only while a block command is active.
/// It never owns the PTY, participates in PTY sizing, or forwards terminal
/// replies; the persistent PaneTerminalView remains the sole interactive view.
final class LiveCommandTerminalView: TerminalView {
    var onGeometryReady: (() -> Void)?

    override func layout() {
        super.layout()
        hidePresentationScroller()
        onGeometryReady?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hidePresentationScroller()
        onGeometryReady?()
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Suppress emulator-generated replies as well as keyboard input. The
        // primary terminal sends the one authoritative response to the PTY.
    }

    /// The live mirror is deliberately non-interactive, so SwiftTerm's own
    /// scroller would be a prominent control that cannot be used. The primary
    /// terminal keeps its native overlay scroller.
    private func hidePresentationScroller() {
        for case let scroller as NSScroller in subviews where !scroller.isHidden {
            scroller.isHidden = true
        }
    }
}

struct LiveCommandTerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let blockID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, blockID: blockID)
    }

    func makeNSView(context: Context) -> LiveCommandTerminalView {
        let terminalView = LiveCommandTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        terminalView.autoresizingMask = [.width, .height]
        terminalView.changeScrollback(10_000)
        terminalView.scrollerStyle = .overlay
        terminalView.optionAsMetaKey = false
        terminalView.allowMouseReporting = false
        terminalView.caretViewTracksFocus = true
        terminalView.terminalDelegate = nil
        applyPaneTerminalPalette(to: terminalView)
        context.coordinator.observe(terminalView)
        return terminalView
    }

    func updateNSView(_ terminalView: LiveCommandTerminalView, context: Context) {
        applyPaneTerminalPalette(to: terminalView)
        context.coordinator.observe(terminalView)
    }

    static func dismantleNSView(
        _ terminalView: LiveCommandTerminalView,
        coordinator: Coordinator
    ) {
        coordinator.detach(terminalView)
    }

    @MainActor
    final class Coordinator {
        weak var session: TerminalSession?
        let blockID: UUID
        private weak var observedView: LiveCommandTerminalView?
        private weak var attachedView: LiveCommandTerminalView?
        private var attachmentGeneration = 0
        private var attachmentQueued = false
        private var isMounted = true

        init(session: TerminalSession, blockID: UUID) {
            self.session = session
            self.blockID = blockID
        }

        func observe(_ terminalView: LiveCommandTerminalView) {
            guard isMounted else { return }

            if observedView !== terminalView {
                attachmentGeneration += 1
                attachmentQueued = false
                if let observedView {
                    observedView.onGeometryReady = nil
                }
                if let attachedView, attachedView !== terminalView {
                    session?.detachLiveCommandTerminalView(attachedView, blockID: blockID)
                    self.attachedView = nil
                }

                observedView = terminalView
                terminalView.onGeometryReady = { [weak self, weak terminalView] in
                    guard let terminalView else { return }
                    self?.scheduleAttachmentIfReady(terminalView)
                }
            }

            scheduleAttachmentIfReady(terminalView)
        }

        func detach(_ terminalView: LiveCommandTerminalView) {
            isMounted = false
            attachmentGeneration += 1
            attachmentQueued = false
            terminalView.onGeometryReady = nil

            if let attachedView {
                session?.detachLiveCommandTerminalView(attachedView, blockID: blockID)
                self.attachedView = nil
            }
            if let observedView, observedView !== terminalView {
                observedView.onGeometryReady = nil
            }
            observedView = nil
        }

        private func scheduleAttachmentIfReady(_ terminalView: LiveCommandTerminalView) {
            guard isMounted,
                  attachedView !== terminalView,
                  !attachmentQueued,
                  terminalView.window != nil,
                  terminalView.bounds.width >= 32,
                  terminalView.bounds.height >= 16 else { return }

            attachmentQueued = true
            attachmentGeneration += 1
            let generation = attachmentGeneration

            // TerminalView updates its grid during layout. Replaying buffered
            // output inside that layout pass can produce a zero-column or
            // partially-sized frame, so attach on the following main turn.
            DispatchQueue.main.async { [weak self, weak terminalView] in
                guard let self else { return }
                self.attachmentQueued = false
                guard self.isMounted,
                      self.attachmentGeneration == generation,
                      let terminalView,
                      self.observedView === terminalView,
                      terminalView.window != nil,
                      terminalView.bounds.width >= 32,
                      terminalView.bounds.height >= 16 else { return }

                self.attachedView = terminalView
                self.session?.attachLiveCommandTerminalView(
                    terminalView,
                    blockID: self.blockID
                )
            }
        }
    }
}

/// Read-only terminal emulator for completed blocks. It replays sanitized VT
/// bytes into an emulator that owns no PTY and suppresses all protocol replies.
final class FrozenBlockTerminalView: TerminalView {
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        hideSnapshotChrome()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideSnapshotChrome()
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Frozen terminal snapshots never send keyboard, mouse, or terminal
        // protocol replies back to the live shell.
    }

    override func paste(_ sender: Any?) {}

    func replay(_ snapshot: TerminalReplaySnapshot) {
        applyFrozenBlockTerminalPalette(to: self)
        terminalDelegate = nil
        terminal.resetToInitialState()
        terminal.resize(
            cols: max(1, snapshot.columns),
            rows: max(1, snapshot.rows)
        )
        feed(byteArray: Array(snapshot.bytes)[...])
        terminal.hideCursor()
        hideSnapshotChrome()
        terminal.updateFullScreen()
        setNeedsDisplay(bounds)
    }

    private func hideSnapshotChrome() {
        for case let scroller as NSScroller in subviews {
            scroller.isHidden = true
        }
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

struct FrozenBlockTerminalViewRepresentable: NSViewRepresentable {
    let snapshot: TerminalReplaySnapshot
    let accessibilityText: String

    func makeNSView(context: Context) -> FrozenBlockTerminalView {
        let terminalView = FrozenBlockTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        terminalView.autoresizingMask = [.width, .height]
        terminalView.changeScrollback(10_000)
        terminalView.scrollerStyle = .overlay
        terminalView.optionAsMetaKey = false
        terminalView.allowMouseReporting = false
        terminalView.caretViewTracksFocus = false
        terminalView.terminalDelegate = nil
        terminalView.setAccessibilityRole(.textArea)
        terminalView.setAccessibilityValue(accessibilityText)
        applyFrozenBlockTerminalPalette(to: terminalView)
        terminalView.replay(snapshot)
        return terminalView
    }

    func updateNSView(_ terminalView: FrozenBlockTerminalView, context: Context) {
        applyFrozenBlockTerminalPalette(to: terminalView)
        terminalView.setAccessibilityValue(accessibilityText)
        if context.coordinator.snapshot != snapshot {
            terminalView.replay(snapshot)
            context.coordinator.snapshot = snapshot
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot)
    }

    final class Coordinator {
        var snapshot: TerminalReplaySnapshot

        init(snapshot: TerminalReplaySnapshot) {
            self.snapshot = snapshot
        }
    }
}

struct ActiveBlockAuthoritativeTerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> AuthoritativeTerminalMountView {
        let mountView = AuthoritativeTerminalMountView()
        mountView.onMountedIntoWindow = { [weak session] in
            session?.authoritativeTerminalDidRemount()
            session?.restoreAuthoritativeFocusAfterMount()
        }
        let hostView = session.makeAuthoritativeTerminalHostView()
        hostView.onMountedIntoWindow = { [weak session] in
            session?.authoritativeTerminalDidRemount()
            session?.restoreAuthoritativeFocusAfterMount()
        }
        applyPaneTerminalPalette(to: hostView.terminalView)
        mountView.mount(hostView)
        hostView.setViewportInsets(.embeddedDirect)
        mountView.requestPostMountLayoutCallback()
        session.restoreAuthoritativeFocusAfterMount()
        return mountView
    }

    func updateNSView(_ mountView: AuthoritativeTerminalMountView, context: Context) {
        let hostView = session.makeAuthoritativeTerminalHostView()
        hostView.onMountedIntoWindow = { [weak session] in
            session?.authoritativeTerminalDidRemount()
            session?.restoreAuthoritativeFocusAfterMount()
        }
        applyPaneTerminalPalette(to: hostView.terminalView)
        let didReparent = mountView.mount(hostView)
        hostView.setViewportInsets(.embeddedDirect)
        mountView.requestPostMountLayoutCallback()
        hostView.terminalView.isHidden = false
        hostView.terminalView.terminal.updateFullScreen()
        hostView.terminalView.setNeedsDisplay(hostView.terminalView.bounds)
        hostView.terminalView.layer?.setNeedsDisplay()
        if didReparent {
            session.authoritativeTerminalDidRemount()
        }
        session.restoreAuthoritativeFocusAfterMount()
    }

    static func dismantleNSView(_ mountView: AuthoritativeTerminalMountView, coordinator: ()) {
        mountView.onMountedIntoWindow = nil
    }
}
