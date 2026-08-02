enum CompletionSourceMapping {
    static func suggestionSource(
        from source: CompletionSource
    ) -> CommandAutocompleteSuggestion.Source {
        switch source {
        case .zsh: return .zsh
        case .history: return .history
        case .builtIn: return .builtIn
        case .executable: return .executable
        case .fileSystem: return .fileSystem
        case .projectScript, .projectCommand: return .projectScript
        case .transition: return .transition
        }
    }

    static func candidateSource(
        from source: CommandAutocompleteSuggestion.Source
    ) -> CompletionSource {
        switch source {
        case .zsh: return .zsh
        case .history: return .history
        case .builtIn: return .builtIn
        case .executable: return .executable
        case .fileSystem: return .fileSystem
        case .projectScript: return .projectScript
        case .transition: return .transition
        }
    }

    static func defaultKind(
        for source: CommandAutocompleteSuggestion.Source
    ) -> CompletionKind {
        switch source {
        case .zsh: return .argument
        case .history, .projectScript: return .fullCommand
        case .builtIn, .executable: return .command
        case .fileSystem: return .path
        case .transition: return .nextCommand
        }
    }
}
