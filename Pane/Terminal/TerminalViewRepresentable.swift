import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

func applyPaneTerminalPalette(to terminalView: TerminalView) {
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

enum AuthoritativeTerminalPlacement: Equatable, Hashable, Sendable {
    case fullTerminal
    case embeddedDirect(blockID: UUID)
    case expandedAlternateScreen(blockID: UUID)

    var viewportInsets: TerminalViewportInsets {
        switch self {
        case .fullTerminal:
            return .fullTerminal
        case .embeddedDirect, .expandedAlternateScreen:
            return .embeddedDirect
        }
    }
}

struct TerminalMountLease: Equatable, Sendable {
    let id: UUID
    let placement: AuthoritativeTerminalPlacement
    fileprivate let sequence: UInt64

    fileprivate init(
        id: UUID = UUID(),
        placement: AuthoritativeTerminalPlacement,
        sequence: UInt64
    ) {
        self.id = id
        self.placement = placement
        self.sequence = sequence
    }
}

struct TerminalMountHealthSnapshot: Sendable {
    let expectedPlacement: AuthoritativeTerminalPlacement?
    let leaseID: UUID?
    let mountID: ObjectIdentifier?
    let hostParentID: ObjectIdentifier?
    let hasWindow: Bool
    let isUnderExpectedMount: Bool
    let width: CGFloat
    let height: CGFloat
    let terminalColumns: Int
    let terminalRows: Int
    let ptyRunning: Bool

    var isHealthy: Bool {
        expectedPlacement != nil
            && leaseID != nil
            && mountID != nil
            && hasWindow
            && isUnderExpectedMount
            && width > 0
            && height > 0
            && terminalColumns > 0
            && terminalRows > 0
            && ptyRunning
    }
}

struct TerminalMountRepairPolicy: Equatable, Sendable {
    static let minimumAutomaticInterval: TimeInterval = 1
    static let maximumConsecutiveAttempts = 3

    static func allowsAutomaticRepair(
        now: Date,
        lastAttempt: Date?,
        consecutiveFailures: Int
    ) -> Bool {
        guard consecutiveFailures < maximumConsecutiveAttempts else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= minimumAutomaticInterval
    }

    static func requiresRecoveryOverlay(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= maximumConsecutiveAttempts
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
    let diagnosticID = UUID()
    var onMountedIntoWindow: (() -> Void)?
    private weak var mountedHostView: AuthoritativeTerminalHostView?
    private(set) var mountedLeaseID: UUID?
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
    fileprivate func mount(
        _ hostView: AuthoritativeTerminalHostView,
        authorizedBy lease: TerminalMountLease
    ) -> Bool {
        if hostView.superview === self {
            mountedHostView = hostView
            mountedLeaseID = lease.id
            return false
        }
        hostView.removeFromSuperview()
        hostView.frame = bounds
        hostView.autoresizingMask = [.width, .height]
        addSubview(hostView)
        mountedHostView = hostView
        mountedLeaseID = lease.id
        hasPendingWindowMountCallback = true
        hasPendingPostMountLayoutCallback = true
        scheduleWindowMountCallbackIfNeeded()
        return true
    }

    fileprivate func relinquish(leaseID: UUID) {
        guard mountedLeaseID == leaseID else { return }
        mountedLeaseID = nil
        onMountedIntoWindow = nil
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

@MainActor
final class TerminalMountCoordinator {
    private weak var session: TerminalSession?
    private(set) var currentLease: TerminalMountLease?
    private weak var currentMount: AuthoritativeTerminalMountView?
    private var nextLeaseSequence: UInt64 = 0
    private var highestClaimedLeaseSequence: UInt64 = 0
    private var validationGeneration: UInt64 = 0
    private var lastAutomaticRepairAt: [AuthoritativeTerminalPlacement: Date] = [:]
    private var consecutiveRepairFailures: [AuthoritativeTerminalPlacement: Int] = [:]
    private(set) var claimCount = 0
    private(set) var releaseCount = 0
    private(set) var staleUpdateRejectionCount = 0
    private(set) var validationFailureCount = 0
    private(set) var automaticRepairCount = 0
    private(set) var successfulRepairCount = 0
    private(set) var terminalIdentityChangeCount = 0
    private(set) var ptyGenerationChangeCount = 0
    private(set) var lastMountAt: Date?
    private(set) var lastDetachAt: Date?
    private(set) var lastFailedValidationAt: Date?
    private(set) var lastRepairAttemptAt: Date?
    private(set) var lastRepairResultAt: Date?
    private(set) var lastSnapshot: TerminalMountHealthSnapshot?

    init(session: TerminalSession) {
        self.session = session
    }

    func issueLease(for placement: AuthoritativeTerminalPlacement) -> TerminalMountLease {
        nextLeaseSequence &+= 1
        return TerminalMountLease(
            placement: placement,
            sequence: nextLeaseSequence
        )
    }

    @discardableResult
    func present(
        lease: TerminalMountLease,
        in mount: AuthoritativeTerminalMountView
    ) -> Bool {
        guard let session,
              session.expectedAuthoritativeTerminalPlacement == lease.placement else {
            staleUpdateRejectionCount += 1
            return false
        }
        guard lease.sequence > 0,
              lease.sequence >= highestClaimedLeaseSequence else {
            staleUpdateRejectionCount += 1
            return false
        }

        if let currentLease, currentLease.id != lease.id {
            currentMount?.relinquish(leaseID: currentLease.id)
        }
        let isNewClaim = currentLease?.id != lease.id || currentMount !== mount
        currentLease = lease
        highestClaimedLeaseSequence = max(
            highestClaimedLeaseSequence,
            lease.sequence
        )
        currentMount = mount
        if isNewClaim { claimCount += 1 }
        let host = session.makeAuthoritativeTerminalHostView()
        host.setViewportInsets(lease.placement.viewportInsets)
        let didReparent = mount.mount(host, authorizedBy: lease)
        lastMountAt = Date()
        configureCallbacks(for: lease, mount: mount)
        session.applyAuthoritativeTerminalAttachmentGeometry(
            lease: lease,
            mount: mount,
            redraw: true
        )
        scheduleSettledValidation(for: lease, mount: mount)
        return didReparent
    }

    func release(lease: TerminalMountLease, from mount: AuthoritativeTerminalMountView) {
        mount.onMountedIntoWindow = nil
        guard currentLease?.id == lease.id, currentMount === mount else {
            return
        }
        mount.relinquish(leaseID: lease.id)
        currentLease = nil
        currentMount = nil
        releaseCount += 1
        lastDetachAt = Date()
        validationGeneration &+= 1
    }

    func isCurrent(lease: TerminalMountLease, mount: AuthoritativeTerminalMountView) -> Bool {
        currentLease == lease && currentMount === mount
    }

    func healthSnapshot() -> TerminalMountHealthSnapshot {
        guard let session else {
            return TerminalMountHealthSnapshot(
                expectedPlacement: nil, leaseID: nil, mountID: nil,
                hostParentID: nil, hasWindow: false,
                isUnderExpectedMount: false, width: 0, height: 0,
                terminalColumns: 0, terminalRows: 0, ptyRunning: false
            )
        }
        let mount = currentMount
        let host = session.authoritativeTerminalHostView
        let terminal = session.terminalView
        return TerminalMountHealthSnapshot(
            expectedPlacement: session.expectedAuthoritativeTerminalPlacement,
            leaseID: currentLease?.id,
            mountID: mount.map(ObjectIdentifier.init),
            hostParentID: host?.superview.map(ObjectIdentifier.init),
            hasWindow: host?.window != nil && terminal?.window != nil,
            isUnderExpectedMount: mount != nil && host?.isDescendant(of: mount!) == true,
            width: terminal?.bounds.width ?? 0,
            height: terminal?.bounds.height ?? 0,
            terminalColumns: terminal?.terminal.cols ?? 0,
            terminalRows: terminal?.terminal.rows ?? 0,
            ptyRunning: session.ptyController.isRunning
        )
    }

    func repairCurrentMount(manual: Bool = false) {
        guard let lease = currentLease, let mount = currentMount else { return }
        repair(lease: lease, mount: mount, manual: manual)
    }

    func validateCurrentMountAfterTransition() {
        guard let lease = currentLease, let mount = currentMount else { return }
        scheduleSettledValidation(for: lease, mount: mount)
    }

    private func configureCallbacks(
        for lease: TerminalMountLease,
        mount: AuthoritativeTerminalMountView
    ) {
        mount.onMountedIntoWindow = { [weak self, weak mount] in
            guard let self, let mount, self.isCurrent(lease: lease, mount: mount) else {
                return
            }
            self.session?.applyAuthoritativeTerminalAttachmentGeometry(
                lease: lease,
                mount: mount,
                redraw: true
            )
            self.scheduleSettledValidation(for: lease, mount: mount)
            self.session?.restoreAuthoritativeFocusAfterMount()
        }
        mount.requestPostMountLayoutCallback()
    }

    private func scheduleSettledValidation(
        for lease: TerminalMountLease,
        mount: AuthoritativeTerminalMountView
    ) {
        validationGeneration &+= 1
        let generation = validationGeneration
        DispatchQueue.main.async { [weak self, weak mount] in
            guard let self, let mount,
                  self.validationGeneration == generation else { return }
            if !self.validate(lease: lease, mount: mount) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak mount] in
                    guard let self, let mount,
                          self.validationGeneration == generation,
                          !self.validate(lease: lease, mount: mount) else { return }
                    self.repair(lease: lease, mount: mount, manual: false)
                }
            }
        }
    }

    @discardableResult
    private func validate(
        lease: TerminalMountLease,
        mount: AuthoritativeTerminalMountView
    ) -> Bool {
        guard isCurrent(lease: lease, mount: mount),
              session?.expectedAuthoritativeTerminalPlacement == lease.placement else {
            staleUpdateRejectionCount += 1
            return false
        }
        let snapshot = healthSnapshot()
        lastSnapshot = snapshot
        if !snapshot.isHealthy {
            validationFailureCount += 1
            lastFailedValidationAt = Date()
        } else {
            consecutiveRepairFailures[lease.placement] = 0
            session?.terminalMountRecoveryRequired = false
        }
        return snapshot.isHealthy
    }

    private func repair(
        lease: TerminalMountLease,
        mount: AuthoritativeTerminalMountView,
        manual: Bool
    ) {
        guard let session,
              isCurrent(lease: lease, mount: mount),
              session.visibilityState == .selected,
              session.expectedAuthoritativeTerminalPlacement == lease.placement else { return }
        let failures = consecutiveRepairFailures[lease.placement, default: 0]
        guard manual || !TerminalMountRepairPolicy.requiresRecoveryOverlay(
            consecutiveFailures: failures
        ) else {
            session.terminalMountRecoveryRequired = true
            return
        }
        let now = Date()
        if !manual, !TerminalMountRepairPolicy.allowsAutomaticRepair(
            now: now,
            lastAttempt: lastAutomaticRepairAt[lease.placement],
            consecutiveFailures: failures
        ) { return }
        if !manual {
            lastAutomaticRepairAt[lease.placement] = now
            automaticRepairCount += 1
        }
        lastRepairAttemptAt = now
        let terminal = session.makeAuthoritativeTerminalView()
        let terminalIdentity = ObjectIdentifier(terminal)
        let ptyGeneration = session.processGeneration
        let host = session.makeAuthoritativeTerminalHostView()
        if host.superview !== mount {
            host.removeFromSuperview()
            _ = mount.mount(host, authorizedBy: lease)
        }
        host.setViewportInsets(lease.placement.viewportInsets)
        session.applyAuthoritativeTerminalAttachmentGeometry(
            lease: lease,
            mount: mount,
            redraw: true
        )
        if ObjectIdentifier(session.makeAuthoritativeTerminalView()) != terminalIdentity {
            terminalIdentityChangeCount += 1
        }
        if session.processGeneration != ptyGeneration {
            ptyGenerationChangeCount += 1
        }
        lastRepairResultAt = Date()
        let healthy = validate(lease: lease, mount: mount)
        if healthy {
            successfulRepairCount += 1
            consecutiveRepairFailures[lease.placement] = 0
            session.terminalMountRecoveryRequired = false
            session.restoreAuthoritativeFocusAfterMount()
        } else {
            let next = failures + 1
            consecutiveRepairFailures[lease.placement] = next
            session.terminalMountRecoveryRequired = TerminalMountRepairPolicy
                .requiresRecoveryOverlay(consecutiveFailures: next)
            if !manual, next < TerminalMountRepairPolicy.maximumConsecutiveAttempts {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + TerminalMountRepairPolicy.minimumAutomaticInterval
                ) { [weak self, weak mount] in
                    guard let self, let mount,
                          self.isCurrent(lease: lease, mount: mount) else { return }
                    self.repair(lease: lease, mount: mount, manual: false)
                }
            }
        }
    }
}

final class PaneTerminalView: TerminalView {
    var onAlternateScreenChanged: ((Bool) -> Void)?
    var onTerminalResponse: ((ArraySlice<UInt8>) -> Void)?
    private var lastQueuedAlternateScreenState = false
    private var alternateScreenNotificationGeneration = 0
    private var userEncodedInputDepth = 0

    override init(frame frameRect: NSRect, font: NSFont?) {
        super.init(frame: frameRect, font: font)
        PaneResourceCounters.increment(.terminalView)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        PaneResourceCounters.increment(.terminalView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        PaneResourceCounters.increment(.terminalView)
    }

    deinit {
        PaneResourceCounters.decrement(.terminalView)
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if userEncodedInputDepth > 0 || Self.isEncodedMouseReport(data) {
            // SwiftTerm encodes mouse reports through TerminalDelegate rather
            // than TerminalViewDelegate. Route those user-originated bytes
            // back through TerminalSession's source/visibility/lifecycle
            // guard. Emulator protocol replies remain allowed in background
            // tabs so terminal negotiation cannot deadlock.
            super.send(source: source, data: data)
            return
        }
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

    override func mouseDown(with event: NSEvent) {
        withUserEncodedInput {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        withUserEncodedInput {
            super.mouseUp(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        withUserEncodedInput {
            super.mouseDragged(with: event)
        }
    }

    private func withUserEncodedInput(_ action: () -> Void) {
        userEncodedInputDepth += 1
        defer { userEncodedInputDepth -= 1 }
        action()
    }

    private static func isEncodedMouseReport(
        _ data: ArraySlice<UInt8>
    ) -> Bool {
        let bytes = Array(data)
        guard bytes.count >= 3,
              bytes[0] == 0x1B,
              bytes[1] == UInt8(ascii: "[") else { return false }
        // SGR mouse: CSI < Cb ; Cx ; Cy M/m
        if bytes[2] == UInt8(ascii: "<") {
            return bytes.last == UInt8(ascii: "M")
                || bytes.last == UInt8(ascii: "m")
        }
        // X10/UTF-8 mouse: CSI M Cb Cx Cy
        if bytes[2] == UInt8(ascii: "M") {
            return bytes.count >= 6
        }
        // URXVT mouse: CSI Cb ; Cx ; Cy M
        return bytes[2] >= UInt8(ascii: "0")
            && bytes[2] <= UInt8(ascii: "9")
            && bytes.contains(UInt8(ascii: ";"))
            && bytes.last == UInt8(ascii: "M")
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
    let placement: AuthoritativeTerminalPlacement

    func makeCoordinator() -> Coordinator {
        Coordinator(lease: session.terminalMountCoordinator.issueLease(for: placement))
    }

    func makeNSView(context: Context) -> AuthoritativeTerminalMountView {
        let mountView = AuthoritativeTerminalMountView()
        context.coordinator.session = session
        context.coordinator.mountView = mountView
        _ = session.terminalMountCoordinator.present(
            lease: context.coordinator.lease,
            in: mountView
        )
        return mountView
    }

    func updateNSView(_ mountView: AuthoritativeTerminalMountView, context: Context) {
        context.coordinator.updatePlacement(placement, session: session)
        _ = session.terminalMountCoordinator.present(
            lease: context.coordinator.lease,
            in: mountView
        )
    }

    static func dismantleNSView(
        _ mountView: AuthoritativeTerminalMountView,
        coordinator: Coordinator
    ) {
        coordinator.session?.terminalMountCoordinator.release(
            lease: coordinator.lease,
            from: mountView
        )
        coordinator.mountView = nil
    }

    @MainActor
    final class Coordinator {
        private(set) var lease: TerminalMountLease
        weak var session: TerminalSession?
        weak var mountView: AuthoritativeTerminalMountView?

        init(lease: TerminalMountLease) {
            self.lease = lease
        }

        func updatePlacement(
            _ placement: AuthoritativeTerminalPlacement,
            session: TerminalSession
        ) {
            guard lease.placement != placement else { return }
            lease = session.terminalMountCoordinator.issueLease(for: placement)
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
        terminalView.changeScrollback(
            ScrollbackPolicy.standard.terminalLineLimit
        )
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
        terminalView.changeScrollback(
            ScrollbackPolicy.standard.terminalLineLimit
        )
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

struct ActiveBlockAuthoritativeTerminalView: View {
    @ObservedObject var session: TerminalSession
    let blockID: UUID

    var body: some View {
        TerminalViewRepresentable(
            session: session,
            placement: .embeddedDirect(blockID: blockID)
        )
    }
}
