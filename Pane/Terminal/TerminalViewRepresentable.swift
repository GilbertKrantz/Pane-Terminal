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


final class AuthoritativeTerminalHostView: NSView {
    let terminalView: PaneTerminalView

    init(terminalView: PaneTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

final class AuthoritativeTerminalMountView: NSView {
    func mount(_ hostView: AuthoritativeTerminalHostView) {
        guard hostView.superview !== self else { return }
        hostView.removeFromSuperview()
        hostView.frame = bounds
        hostView.autoresizingMask = [.width, .height]
        addSubview(hostView)
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

    func makeNSView(context: Context) -> AuthoritativeTerminalMountView {
        let mountView = AuthoritativeTerminalMountView()
        let hostView = session.makeAuthoritativeTerminalHostView()
        applyPaneTerminalPalette(to: hostView.terminalView)
        mountView.mount(hostView)
        return mountView
    }

    func updateNSView(_ mountView: AuthoritativeTerminalMountView, context: Context) {
        let hostView = session.makeAuthoritativeTerminalHostView()
        mountView.mount(hostView)
        applyPaneTerminalPalette(to: hostView.terminalView)
        hostView.terminalView.isHidden = false
        hostView.terminalView.terminal.updateFullScreen()
        hostView.terminalView.setNeedsDisplay(hostView.terminalView.bounds)
        hostView.terminalView.layer?.setNeedsDisplay()
        DispatchQueue.main.async { [weak terminalView = hostView.terminalView] in
            terminalView?.window?.makeFirstResponder(terminalView)
        }
    }

    static func dismantleNSView(_ mountView: AuthoritativeTerminalMountView, coordinator: ()) {}
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
