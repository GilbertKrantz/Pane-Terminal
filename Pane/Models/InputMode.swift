import Foundation

enum InputMode: String, CaseIterable, Equatable, Sendable {
    case blocks
    case terminal

    var title: String {
        switch self {
        case .blocks: "Blocks Mode"
        case .terminal: "Terminal Mode"
        }
    }

    var shortTitle: String {
        switch self {
        case .blocks: "Blocks"
        case .terminal: "Terminal"
        }
    }

    mutating func toggle() {
        self = self == .blocks ? .terminal : .blocks
    }
}
enum TerminalInputRequirement: Equatable, Sendable {
    case shellIdle
    case lineOriented
    case direct
    case secure
    case unknown
}

/// Visual space is deliberately independent from how input bytes are routed.
/// A one-key confirmation and a normal-buffer TUI both need direct PTY input,
/// but only the latter should replace the main Blocks workspace.
enum ActiveTerminalPresentation: Equatable, Sendable {
    case hidden
    case liveMirror
    case authoritativeInBlock
    case expanded
    case fullTerminal
}

enum InputModeAttribution: Equatable, Sendable {
    case manual
    case secureInput
    case foregroundProcess(String)
    case rawTermios(String?)
    case alternateScreen

    var explanation: String {
        switch self {
        case .manual:
            return "manual selection"
        case .secureInput:
            return "secure input is active"
        case .foregroundProcess(let processName):
            return "\(processName) is running"
        case .rawTermios(let processName):
            if let processName, !processName.isEmpty {
                return "\(processName) requested raw input"
            }
            return "the foreground process requested raw input"
        case .alternateScreen:
            return "alternate screen is active"
        }
    }
}

struct ForegroundProcessSnapshot: Equatable, Sendable {
    let processGroupID: pid_t
    let shellProcessGroupID: pid_t?
    let processName: String?
    let isRawInput: Bool
    let echoEnabled: Bool

    var isShellForeground: Bool {
        processGroupID == shellProcessGroupID
    }

    var isKnownInteractiveProgram: Bool {
        Self.isKnownInteractiveProgram(named: processName)
    }

    var terminalModeAttribution: InputModeAttribution? {
        // Interactive shells commonly put their own line editor into raw
        // termios mode. The shell foreground is still the Blocks-mode idle
        // state, so it must win over the generic ICANON/ECHO signal.
        if isShellForeground {
            return nil
        }
        if isRawInput {
            return .rawTermios(processName)
        }
        if isKnownInteractiveProgram, let processName {
            return .foregroundProcess(processName)
        }
        return nil
    }

    static func isKnownInteractiveProgram(named processName: String?) -> Bool {
        guard let processName else { return false }
        let normalizedName = URL(fileURLWithPath: processName)
            .lastPathComponent
            .lowercased()
        return knownInteractiveProcessNames.contains(normalizedName)
    }

    private static let knownInteractiveProcessNames: Set<String> = [
        "bpython", "claude", "codex", "emacs", "fish", "fzf", "htop",
        "ipython", "less", "more", "nano", "node", "nvim", "opencode",
        "python", "python2", "python3", "radian", "ranger", "ssh", "tmux",
        "top", "vi", "vim", "watch", "zellij"
    ]
}
