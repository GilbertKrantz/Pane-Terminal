import Combine
import Foundation

enum TerminalInteractionState: Equatable, Sendable {
    case starting
    case shellIdle
    case commandRunningLineInput
    case commandRunningDirect
    case commandRunningSecure
    case alternateScreen
    case fullTerminal
    case restarting
    case shuttingDown
    case stopped

    var focusTarget: PaneFocusTarget {
        switch self {
        case .shellIdle, .commandRunningLineInput:
            return .composer
        case .commandRunningDirect, .commandRunningSecure, .alternateScreen, .fullTerminal:
            return .authoritativeTerminal
        case .starting, .restarting, .shuttingDown, .stopped:
            return .none
        }
    }

    var composerEnabled: Bool {
        self == .shellIdle || self == .commandRunningLineInput
    }

    var terminalAcceptsInput: Bool {
        focusTarget == .authoritativeTerminal
    }

    var inputRequirement: TerminalInputRequirement {
        switch self {
        case .shellIdle: return .shellIdle
        case .commandRunningLineInput: return .lineOriented
        case .commandRunningSecure: return .secure
        case .commandRunningDirect, .alternateScreen, .fullTerminal: return .direct
        case .starting, .restarting, .shuttingDown, .stopped: return .unknown
        }
    }
}

enum TerminalInteractionEvent: Equatable, Sendable {
    case shellStarted
    case shellReady
    case commandSubmitted
    case commandStarted
    case lineInputRequired
    case directInputRequired
    case secureInputRequired
    case secureInputEnded
    case alternateScreenEntered
    case alternateScreenExited
    case commandCompleted
    case commandInterrupted
    case userOpenedFullTerminal
    case userReturnedToBlocks
    case restartRequested
    case restartCompleted
    case shellExited
    case applicationClosing
}

/// The sole policy object for deciding who owns keyboard input. Invalid and
/// duplicate events are deliberately harmless, which makes late PTY/AppKit
/// callbacks safe during restart and teardown.
@MainActor
final class TerminalInteractionController: ObservableObject {
    @Published private(set) var state: TerminalInteractionState
    private(set) var previousNonAlternateState: TerminalInteractionState?
    private(set) var rejectedEventCount = 0
    private var stateBeforeSecureInput: TerminalInteractionState?
    private var blocksStateBehindFullTerminal: TerminalInteractionState = .shellIdle
    private var isManualFullTerminalActive = false
    private let debugLoggingEnabled: Bool
    var onTransition: ((TerminalInteractionState, TerminalInteractionEvent, TerminalInteractionState) -> Void)?

    init(
        initialState: TerminalInteractionState = .starting,
        debugLoggingEnabled: Bool = false
    ) {
        state = initialState
        self.debugLoggingEnabled = debugLoggingEnabled
    }

    var presentationMode: InputMode {
        isManualFullTerminalActive ? .terminal : .blocks
    }

    var effectiveInputRequirement: TerminalInputRequirement {
        if state == .fullTerminal,
           blocksStateBehindFullTerminal == .commandRunningSecure {
            return .secure
        }
        return state.inputRequirement
    }

    var composerEnabled: Bool {
        presentationMode == .blocks && state.composerEnabled
    }

    var showsAuthoritativeTerminal: Bool {
        switch state {
        case .commandRunningDirect, .commandRunningSecure, .alternateScreen, .fullTerminal:
            return true
        case .starting, .shellIdle, .commandRunningLineInput, .restarting, .shuttingDown, .stopped:
            return false
        }
    }

    @discardableResult
    func handle(_ event: TerminalInteractionEvent) -> Bool {
        let old = state
        guard let next = transition(from: old, event: event) else {
            rejectedEventCount += 1
            return false
        }
        guard next != old else {
            onTransition?(old, event, next)
            assertInvariants()
            return true
        }
        if event == .alternateScreenEntered { previousNonAlternateState = old }
        if event == .alternateScreenExited { previousNonAlternateState = nil }
        state = next
#if DEBUG
        if debugLoggingEnabled {
            print("[Interaction] \(old) --\(event)--> \(next); owner=\(next.focusTarget)")
        }
#endif
        onTransition?(old, event, next)
        assertInvariants()
        return true
    }

    func assertInvariants(file: StaticString = #file, line: UInt = #line) {
        assert(!state.terminalAcceptsInput || state.focusTarget == .authoritativeTerminal, file: file, line: line)
        assert(state != .stopped || state.focusTarget == .none, file: file, line: line)
        assert(state != .restarting || !state.composerEnabled, file: file, line: line)
        assert(state != .alternateScreen || state.focusTarget == .authoritativeTerminal, file: file, line: line)
        assert(!isManualFullTerminalActive || state != .shellIdle, file: file, line: line)
    }

    private func transition(
        from state: TerminalInteractionState,
        event: TerminalInteractionEvent
    ) -> TerminalInteractionState? {
        if event == .applicationClosing {
            guard state != .shuttingDown else { return nil }
            resetTransientPresentationState()
            return .shuttingDown
        }
        if event == .shellExited {
            guard state != .shuttingDown, state != .stopped else { return nil }
            resetTransientPresentationState()
            return .stopped
        }
        if event == .restartRequested {
            guard state != .shuttingDown, state != .restarting else { return nil }
            resetTransientPresentationState()
            return .restarting
        }
        if state == .shuttingDown || state == .stopped || state == .restarting {
            switch event {
            case .shellStarted:
                return state == .restarting ? .starting : nil
            case .shellReady, .restartCompleted:
                return state == .restarting ? .shellIdle : nil
            default:
                return nil
            }
        }

        switch event {
        case .shellStarted:
            return state == .starting ? .starting : nil
        case .shellReady, .restartCompleted:
            if state == .alternateScreen,
               previousNonAlternateState == .starting {
                previousNonAlternateState = .shellIdle
                return .alternateScreen
            }
            return state == .starting ? .shellIdle : nil
        case .commandSubmitted, .commandStarted:
            if state == .shellIdle || state == .commandRunningLineInput {
                return .commandRunningLineInput
            }
            if state == .fullTerminal {
                blocksStateBehindFullTerminal = .commandRunningLineInput
                return .fullTerminal
            }
            return nil
        case .lineInputRequired:
            if state == .commandRunningDirect || state == .commandRunningSecure {
                stateBeforeSecureInput = nil
                return .commandRunningLineInput
            }
            if state == .fullTerminal, blocksStateBehindFullTerminal != .shellIdle {
                blocksStateBehindFullTerminal = .commandRunningLineInput
                return .fullTerminal
            }
            return state == .commandRunningLineInput ? state : nil
        case .directInputRequired:
            if state == .commandRunningLineInput || state == .commandRunningSecure {
                stateBeforeSecureInput = nil
                return .commandRunningDirect
            }
            if state == .fullTerminal, blocksStateBehindFullTerminal != .shellIdle {
                blocksStateBehindFullTerminal = .commandRunningDirect
                return .fullTerminal
            }
            return nil
        case .secureInputRequired:
            switch state {
            case .shellIdle, .commandRunningLineInput, .commandRunningDirect:
                stateBeforeSecureInput = state
                return .commandRunningSecure
            case .fullTerminal:
                stateBeforeSecureInput = blocksStateBehindFullTerminal
                blocksStateBehindFullTerminal = .commandRunningSecure
                return .fullTerminal
            default: return nil
            }
        case .secureInputEnded:
            if state == .commandRunningSecure {
                defer { stateBeforeSecureInput = nil }
                switch stateBeforeSecureInput {
                case .shellIdle: return .shellIdle
                case .commandRunningDirect: return .commandRunningDirect
                default: return .commandRunningLineInput
                }
            }
            if state == .fullTerminal, blocksStateBehindFullTerminal == .commandRunningSecure {
                switch stateBeforeSecureInput {
                case .shellIdle: blocksStateBehindFullTerminal = .shellIdle
                case .commandRunningDirect: blocksStateBehindFullTerminal = .commandRunningDirect
                default: blocksStateBehindFullTerminal = .commandRunningLineInput
                }
                stateBeforeSecureInput = nil
                return .fullTerminal
            }
            return nil
        case .alternateScreenEntered:
            switch state {
            case .starting, .shellIdle, .commandRunningLineInput, .commandRunningDirect, .commandRunningSecure, .fullTerminal:
                return .alternateScreen
            default: return nil
            }
        case .alternateScreenExited:
            guard state == .alternateScreen else { return nil }
            if isManualFullTerminalActive { return .fullTerminal }
            switch previousNonAlternateState {
            case .commandRunningSecure:
                return .commandRunningSecure
            case .shellIdle:
                return .shellIdle
            case .starting:
                return .starting
            default:
                return .commandRunningDirect
            }
        case .commandCompleted, .commandInterrupted:
            stateBeforeSecureInput = nil
            if state == .fullTerminal {
                blocksStateBehindFullTerminal = .shellIdle
                return .fullTerminal
            }
            if state == .alternateScreen, isManualFullTerminalActive {
                blocksStateBehindFullTerminal = .shellIdle
                return .fullTerminal
            }
            switch state {
            case .commandRunningLineInput, .commandRunningDirect, .commandRunningSecure, .alternateScreen:
                return .shellIdle
            default: return nil
            }
        case .userOpenedFullTerminal:
            switch state {
            case .shellIdle, .commandRunningLineInput, .commandRunningDirect, .commandRunningSecure:
                blocksStateBehindFullTerminal = state
                isManualFullTerminalActive = true
                return .fullTerminal
            case .alternateScreen:
                isManualFullTerminalActive = true
                return .alternateScreen
            case .fullTerminal:
                return .fullTerminal
            default:
                return nil
            }
        case .userReturnedToBlocks:
            switch state {
            case .fullTerminal:
                isManualFullTerminalActive = false
                return blocksStateBehindFullTerminal
            case .alternateScreen where isManualFullTerminalActive:
                isManualFullTerminalActive = false
                return .alternateScreen
            default: return nil
            }
        case .restartRequested, .shellExited, .applicationClosing:
            return nil // handled above
        }
    }

    private func resetTransientPresentationState() {
        previousNonAlternateState = nil
        stateBeforeSecureInput = nil
        blocksStateBehindFullTerminal = .shellIdle
        isManualFullTerminalActive = false
    }
}
