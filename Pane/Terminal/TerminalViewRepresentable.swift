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

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> PaneTerminalView {
        let terminalView = PaneTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        terminalView.autoresizingMask = [.width, .height]
        context.coordinator.applyPaletteIfNeeded(
            to: terminalView,
            using: applyPalette
        )
        terminalView.changeScrollback(10_000)
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.caretViewTracksFocus = true
        terminalView.isHidden = session.mode != .terminal
        context.coordinator.isTerminalVisible = !terminalView.isHidden
        context.coordinator.isMounted = true
        DispatchQueue.main.async { [
            weak terminalView,
            weak coordinator = context.coordinator
        ] in
            guard let terminalView, let coordinator, coordinator.isMounted else { return }
            coordinator.session?.attach(terminalView: terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: PaneTerminalView, context: Context) {
        context.coordinator.applyPaletteIfNeeded(
            to: terminalView,
            using: applyPalette
        )

        let shouldShowTerminal = session.mode == .terminal
        context.coordinator.scheduleVisibility(
            shouldShowTerminal,
            for: terminalView
        )
    }

    static func dismantleNSView(_ terminalView: PaneTerminalView, coordinator: Coordinator) {
        coordinator.isMounted = false
        coordinator.session?.detach(terminalView: terminalView)
    }

    private func applyPalette(to terminalView: TerminalView) {
        applyPaneTerminalPalette(to: terminalView)
    }

    @MainActor
    final class Coordinator {
        weak var session: TerminalSession?
        var isMounted = false
        var isTerminalVisible = false
        private var appliedAppearanceName: NSAppearance.Name?
        private var visibilityGeneration = 0

        init(session: TerminalSession) {
            self.session = session
        }

        func applyPaletteIfNeeded(
            to terminalView: TerminalView,
            using apply: (TerminalView) -> Void
        ) {
            let appearanceName = terminalView.effectiveAppearance.bestMatch(
                from: [.aqua, .darkAqua]
            )
            guard appearanceName != appliedAppearanceName else { return }
            appliedAppearanceName = appearanceName
            apply(terminalView)
        }

        func scheduleVisibility(
            _ shouldShowTerminal: Bool,
            for terminalView: TerminalView
        ) {
            guard isTerminalVisible != shouldShowTerminal
                || terminalView.isHidden == shouldShowTerminal else { return }

            isTerminalVisible = shouldShowTerminal
            visibilityGeneration += 1
            let generation = visibilityGeneration

            DispatchQueue.main.async { [weak self, weak terminalView] in
                guard let self,
                      let terminalView,
                      self.isMounted,
                      self.visibilityGeneration == generation,
                      self.isTerminalVisible == shouldShowTerminal else { return }

                let wasHidden = terminalView.isHidden
                terminalView.isHidden = !shouldShowTerminal

                guard shouldShowTerminal else { return }
                terminalView.terminal.updateFullScreen()
                terminalView.setNeedsDisplay(terminalView.bounds)
                terminalView.layer?.setNeedsDisplay()

                guard wasHidden,
                      self.session?.mode == .terminal,
                      let window = terminalView.window else { return }
                window.makeFirstResponder(terminalView)
            }
        }
    }
}

/// A read-only terminal emulator used only while a block command is active.
/// It never owns the PTY, participates in PTY sizing, or forwards terminal
/// replies; the persistent PaneTerminalView remains the sole interactive view.
final class LiveCommandTerminalView: TerminalView {
    var onGeometryReady: (() -> Void)?

    override func layout() {
        super.layout()
        onGeometryReady?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onGeometryReady?()
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Suppress emulator-generated replies as well as keyboard input. The
        // primary terminal sends the one authoritative response to the PTY.
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
