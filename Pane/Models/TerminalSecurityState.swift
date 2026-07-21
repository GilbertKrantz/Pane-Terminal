import Foundation

enum TerminalInputMode: Equatable, Sendable {
    case normal
    case secure
}

enum SecureInputDetectionSource: Equatable, Sendable {
    case terminalEchoState
    case applicationSignal
    case promptHeuristic
    case manualOverride
}

struct TerminalSecurityState: Equatable, Sendable {
    let inputMode: TerminalInputMode
    let echoEnabled: Bool
    let detectedAt: Date
    let source: SecureInputDetectionSource

    static var normal: TerminalSecurityState {
        TerminalSecurityState(
            inputMode: .normal,
            echoEnabled: true,
            detectedAt: Date(),
            source: .terminalEchoState
        )
    }
}

protocol SecureInputControlling: Sendable {
    func beginSecureInput(reason: String?)
    func endSecureInput()
}
