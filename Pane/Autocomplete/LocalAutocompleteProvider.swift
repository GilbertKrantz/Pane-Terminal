import Foundation

struct LocalAutocompleteContext: Sendable {
    let draft: String
    let cursorUTF16Offset: Int
    let history: [String]
    let currentDirectory: URL
    let executableSearchPath: String
    let shellGeneration: UInt64
}

actor LocalAutocompleteProvider {
    private let executableIndex: ExecutableIndex
    private let projectContextProvider: ProjectContextProvider
    private let projectDefinitionCache: ProjectDefinitionCache
    private let gitContextCache: GitContextCache
    private let autocomplete: CommandAutocomplete
    private let ranker: CompletionRanker
    private let maximumSuggestions: Int

    init(
        executableIndex: ExecutableIndex = ExecutableIndex(),
        projectContextProvider: ProjectContextProvider = ProjectContextProvider(),
        projectDefinitionCache: ProjectDefinitionCache = ProjectDefinitionCache(),
        gitContextCache: GitContextCache = GitContextCache(),
        ranker: CompletionRanker = CompletionRanker(),
        maximumSuggestions: Int = 12
    ) {
        self.executableIndex = executableIndex
        self.projectContextProvider = projectContextProvider
        self.projectDefinitionCache = projectDefinitionCache
        self.gitContextCache = gitContextCache
        self.ranker = ranker
        self.maximumSuggestions = max(0, maximumSuggestions)
        self.autocomplete = CommandAutocomplete(
            maximumSuggestions: max(64, maximumSuggestions * 4)
        )
    }

    func invalidateGitContext() async {
        await gitContextCache.invalidate()
    }

    func invalidateProjectContext() async {
        await projectDefinitionCache.invalidate()
        await gitContextCache.invalidate()
    }

    func projectDefinition(for directory: URL) async -> ProjectContext? {
        await projectDefinitionCache.value(for: directory) {
            self.projectContextProvider.definition(for: directory)
        }
    }

    func suggestions(for context: LocalAutocompleteContext) async -> [CommandAutocompleteSuggestion] {
        guard !Task.isCancelled else { return [] }
        let prefix = Self.commandPrefix(in: context.draft, cursorUTF16Offset: context.cursorUTF16Offset)
        async let indexedExecutables = executableIndex.candidates(
            prefix: prefix,
            path: context.executableSearchPath,
            currentDirectory: context.currentDirectory,
            shellGeneration: context.shellGeneration
        )
        async let discoveredDefinition = projectDefinitionCache.value(for: context.currentDirectory) {
            self.projectContextProvider.definition(for: context.currentDirectory)
        }
        let (executables, definition) = await (indexedExecutables, discoveredDefinition)
        let project: ProjectContext?
        if let definition {
            let git = await gitContextCache.value(for: definition.root) {
                await self.projectContextProvider.gitContext(root: definition.root)
            }
            project = ProjectContext(
                root: definition.root,
                identity: definition.identity,
                kind: definition.kind,
                git: git,
                manifests: definition.manifests,
                scripts: definition.scripts,
                detectedLanguages: definition.detectedLanguages,
                discoveredAt: definition.discoveredAt
            )
        } else {
            project = nil
        }
        guard !Task.isCancelled else { return [] }
        var suggestions = autocomplete.suggestions(
            for: context.draft,
            cursorUTF16Offset: context.cursorUTF16Offset,
            history: context.history,
            currentDirectory: context.currentDirectory,
            executableSearchPath: "",
            indexedExecutables: executables
        )
        suggestions.append(contentsOf: Self.fullCommandHistorySuggestions(
            history: context.history,
            draft: context.draft,
            cursorUTF16Offset: context.cursorUTF16Offset
        ))
        if let project {
            suggestions.append(contentsOf: Self.projectScriptSuggestions(
                in: project,
                draft: context.draft,
                cursorUTF16Offset: context.cursorUTF16Offset
            ))
        }
        let candidates = suggestions.enumerated().map { offset, suggestion in
            Self.rankingCandidate(
                suggestion,
                offset: offset,
                prefix: prefix,
                history: context.history
            )
        }
        return ranker.rank(candidates, maximumResults: maximumSuggestions)
            .map(Self.suggestion(from:))
    }

    private static func fullCommandHistorySuggestions(
        history: [String],
        draft: String,
        cursorUTF16Offset: Int
    ) -> [CommandAutocompleteSuggestion] {
        let draftLength = (draft as NSString).length
        guard cursorUTF16Offset == draftLength,
              !draft.isEmpty,
              !draft.contains(where: \.isNewline) else { return [] }
        let normalizedDraft = NormalizedCommand(draft).full
        guard !normalizedDraft.isEmpty else { return [] }
        var seen: Set<String> = []
        return history.reversed().compactMap { command in
            let normalized = NormalizedCommand(command).full
            guard normalized.count > normalizedDraft.count,
                  normalized.hasPrefix(normalizedDraft),
                  seen.insert(normalized).inserted else { return nil }
            return CommandAutocompleteSuggestion(
                text: normalized,
                replacementText: normalized,
                replacementRange: NSRange(location: 0, length: draftLength),
                source: .history,
                detail: "Command history"
            )
        }
    }

    private static func commandPrefix(in draft: String, cursorUTF16Offset: Int) -> String {
        let text = draft as NSString
        let cursor = min(max(0, cursorUTF16Offset), text.length)
        var start = cursor
        while start > 0 {
            let character = text.character(at: start - 1)
            if Self.isWhitespace(character) { break }
            start -= 1
        }
        return text.substring(with: NSRange(location: start, length: cursor - start))
    }

    private static func projectScriptSuggestions(
        in project: ProjectContext,
        draft: String,
        cursorUTF16Offset: Int
    ) -> [CommandAutocompleteSuggestion] {
        let text = draft as NSString
        let cursor = min(max(0, cursorUTF16Offset), text.length)
        var lineStart = cursor
        while lineStart > 0 {
            let character = text.character(at: lineStart - 1)
            if character == 10 || character == 13 { break }
            lineStart -= 1
        }
        var contentStart = lineStart
        while contentStart < cursor,
              Self.isWhitespace(text.character(at: contentStart), includingNewlines: false) {
            contentStart += 1
        }
        var tokenStart = cursor
        while tokenStart > contentStart,
              !Self.isWhitespace(text.character(at: tokenStart - 1)) {
            tokenStart -= 1
        }

        let typedLine = text.substring(
            with: NSRange(location: contentStart, length: cursor - contentStart)
        )
        guard !typedLine.isEmpty,
              !typedLine.contains(where: { "\"'\\|;&<>".contains($0) }) else {
            return []
        }
        let replacementOffset = tokenStart - contentStart

        return project.scripts.compactMap { script in
            let command = script.command as NSString
            guard command.length > typedLine.utf16.count,
                  script.command.hasPrefix(typedLine),
                  replacementOffset <= command.length else {
                return nil
            }
            let replacement = command.substring(
                from: replacementOffset
            )
            return CommandAutocompleteSuggestion(
                text: script.command,
                replacementText: replacement,
                replacementRange: NSRange(
                    location: tokenStart,
                    length: cursor - tokenStart
                ),
                source: .projectScript,
                detail: script.manifestURL.lastPathComponent
            )
        }
    }

    private static func rankingCandidate(
        _ suggestion: CommandAutocompleteSuggestion,
        offset: Int,
        prefix: String,
        history: [String]
    ) -> CompletionCandidate {
        let source: CompletionSource
        let kind: CompletionKind
        switch suggestion.source {
        case .zsh:
            source = .zsh
            kind = .argument
        case .history:
            source = .history
            kind = .fullCommand
        case .builtIn:
            source = .builtIn
            kind = .command
        case .executable:
            source = .executable
            kind = .command
        case .fileSystem:
            source = .fileSystem
            kind = .path
        case .projectScript:
            source = .projectScript
            kind = .fullCommand
        case .transition:
            source = .transition
            kind = .nextCommand
        }

        var evidence = CompletionEvidence()
        evidence.exactPrefixMatch = suggestion.replacementText.hasPrefix(prefix)
        evidence.prefixMatchLength = prefix.utf16.count
        evidence.projectMatch = suggestion.source == .projectScript
        evidence.workingDirectoryMatch = suggestion.source == .projectScript
        evidence.executableAvailable = suggestion.source == .builtIn
            || suggestion.source == .executable
            || suggestion.source == .projectScript
        if suggestion.source == .history {
            let identity = NormalizedCommand(suggestion.text)
            evidence.sessionFrequency = history.reduce(into: 0) { count, command in
                let occurrence = NormalizedCommand(command)
                if occurrence.full == identity.full
                    || occurrence.full.hasPrefix(identity.full + " ") {
                    count += 1
                }
            }
        }

        return CompletionCandidate(
            displayText: suggestion.text,
            replacementText: suggestion.replacementText,
            replacementRange: suggestion.replacementRange,
            source: source,
            kind: kind,
            detail: suggestion.detail,
            isDirectory: suggestion.isDirectory,
            evidence: evidence
        )
    }

    private static func suggestion(
        from ranked: RankedCompletion
    ) -> CommandAutocompleteSuggestion {
        let candidate = ranked.candidate
        let source: CommandAutocompleteSuggestion.Source
        switch candidate.source {
        case .zsh:
            source = .zsh
        case .history:
            source = .history
        case .builtIn:
            source = .builtIn
        case .executable:
            source = .executable
        case .fileSystem:
            source = .fileSystem
        case .projectScript, .projectCommand:
            source = .projectScript
        case .transition:
            source = .transition
        }
        return CommandAutocompleteSuggestion(
            text: candidate.displayText,
            replacementText: candidate.replacementText,
            replacementRange: candidate.replacementRange,
            source: source,
            isDirectory: candidate.isDirectory,
            detail: candidate.detail
        )
    }

    private static func isWhitespace(
        _ character: unichar,
        includingNewlines: Bool = true
    ) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return (includingNewlines ? CharacterSet.whitespacesAndNewlines : .whitespaces)
            .contains(scalar)
    }
}
