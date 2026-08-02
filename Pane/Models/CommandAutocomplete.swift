import Foundation

struct AutocompleteRequestContext: Equatable, Sendable {
    let sessionID: UUID
    let tabID: UUID
    let generation: UInt64
    let query: String
}

/// Main-actor request identity for composer autocomplete. Cancellation is an
/// optimization; this gate is the authority that prevents a late provider
/// result from being presented after its input or owner changed.
@MainActor
struct AutocompleteRequestGate {
    private(set) var generation: UInt64 = 0
    private(set) var context: AutocompleteRequestContext?

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func begin(
        input: String,
        sessionID: UUID,
        tabID: UUID
    ) -> AutocompleteRequestContext? {
        invalidate()
        let query = Self.normalize(input)
        guard !query.isEmpty else { return nil }
        let context = AutocompleteRequestContext(
            sessionID: sessionID,
            tabID: tabID,
            generation: generation,
            query: query
        )
        self.context = context
        return context
    }

    mutating func invalidate() {
        generation &+= 1
        context = nil
    }

    func permits(
        _ request: AutocompleteRequestContext,
        currentInput: String,
        sessionID: UUID,
        tabID: UUID
    ) -> Bool {
        context == request
            && generation == request.generation
            && sessionID == request.sessionID
            && tabID == request.tabID
            && Self.normalize(currentInput) == request.query
    }
}

struct ZshCompletionCandidate: Equatable, Sendable {
    let replacementText: String
    let detail: String?
    let isDirectory: Bool
}

struct CommandAutocompleteSuggestion: Identifiable, Equatable, Hashable, Sendable {
    enum Source: String, Equatable, Hashable, Sendable {
        case zsh
        case history
        case builtIn
        case executable
        case fileSystem
        case projectScript
        case transition
    }

    let text: String
    let replacementText: String
    let replacementRange: NSRange?
    let source: Source
    let isDirectory: Bool
    let detail: String?
    let supportingSources: Set<Source>
    /// Canonical result identity supplied by the completion pipeline. Legacy
    /// presentation-only suggestions may omit it and use the fallback `id`.
    let canonicalResultID: String?

    var id: String {
        canonicalResultID ?? "\(source.rawValue):\(replacementText)"
    }

    init(
        text: String,
        replacementText: String? = nil,
        replacementRange: NSRange? = nil,
        source: Source,
        isDirectory: Bool = false,
        detail: String? = nil,
        stableID: String? = nil,
        supportingSources: Set<Source>? = nil
    ) {
        self.text = text
        self.replacementText = replacementText ?? text
        self.replacementRange = replacementRange
        self.source = source
        self.isDirectory = isDirectory
        self.detail = detail
        self.canonicalResultID = stableID
        self.supportingSources = supportingSources ?? [source]
    }
}

struct CommandAutocompleteEdit: Equatable, Sendable {
    let draft: String
    let cursorUTF16Offset: Int
}

enum CommandAutocompleteTabAction: Equatable, Sendable {
    case cycle
    case accept(CommandAutocompleteSuggestion)
}

/// Keyboard selection state for a transient completion list. Selection is
/// kept separate from the draft so Tab can move through candidates without
/// modifying the command until the user confirms one with Return or a click.
struct CommandAutocompleteSelection: Equatable, Sendable {
    private(set) var highlightedSuggestionID: String?

    mutating func handleTab(
        by offset: Int,
        through suggestions: [CommandAutocompleteSuggestion]
    ) -> CommandAutocompleteTabAction? {
        guard !suggestions.isEmpty, offset != 0 else { return nil }

        if suggestions.count == 1,
           selected(from: suggestions) == suggestions[0] {
            let suggestion = suggestions[0]
            reset()
            return .accept(suggestion)
        }

        _ = move(by: offset, through: suggestions)
        return .cycle
    }

    mutating func move(
        by offset: Int,
        through suggestions: [CommandAutocompleteSuggestion]
    ) -> Bool {
        guard !suggestions.isEmpty, offset != 0 else {
            highlightedSuggestionID = nil
            return false
        }

        let currentIndex = highlightedSuggestionID.flatMap { highlightedID in
            suggestions.firstIndex { $0.id == highlightedID }
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + offset).modulo(suggestions.count)
        } else {
            nextIndex = offset > 0 ? 0 : suggestions.count - 1
        }
        highlightedSuggestionID = suggestions[nextIndex].id
        return true
    }

    func selected(
        from suggestions: [CommandAutocompleteSuggestion]
    ) -> CommandAutocompleteSuggestion? {
        guard let highlightedSuggestionID else { return nil }
        return suggestions.first { $0.id == highlightedSuggestionID }
    }

    mutating func reset() {
        highlightedSuggestionID = nil
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

/// A synchronous, side-effect-free completion coordinator apart from local
/// directory reads. It never launches a shell or writes to the terminal.
struct CommandAutocomplete {
    static let defaultBuiltInCommands = [
        "alias",
        "bg",
        "cd",
        "clear",
        "dirs",
        "echo",
        "exit",
        "export",
        "fg",
        "history",
        "jobs",
        "popd",
        "printf",
        "pushd",
        "pwd",
        "source",
        "type",
        "unalias",
        "unset",
        "which"
    ]

    let maximumSuggestions: Int

    private let builtInCommands: [String]
    private let fileManager: FileManager

    init(
        maximumSuggestions: Int = 12,
        builtInCommands: [String] = CommandAutocomplete.defaultBuiltInCommands,
        fileManager: FileManager = .default
    ) {
        self.maximumSuggestions = max(0, maximumSuggestions)
        self.builtInCommands = Array(Set(builtInCommands)).sorted()
        self.fileManager = fileManager
    }

    func suggestions(
        for draft: String,
        cursorUTF16Offset: Int? = nil,
        history: [String],
        currentDirectory: URL,
        executableSearchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        indexedExecutables: [String]? = nil
    ) -> [CommandAutocompleteSuggestion] {
        guard maximumSuggestions > 0 else { return [] }

        let token = Self.tokenContext(
            in: draft,
            cursorUTF16Offset: cursorUTF16Offset
        )
        var results: [CommandAutocompleteSuggestion] = []
        var seenTexts: Set<String> = []

        func append(
            text: String,
            replacementText: String,
            source: CommandAutocompleteSuggestion.Source,
            isDirectory: Bool = false
        ) {
            guard results.count < maximumSuggestions,
                  seenTexts.insert(text).inserted else { return }
            results.append(
                CommandAutocompleteSuggestion(
                    text: text,
                    replacementText: replacementText,
                    replacementRange: token.range,
                    source: source,
                    isDirectory: isDirectory
                )
            )
        }

        for candidate in historyCandidates(history, token: token) {
            append(
                text: candidate.text,
                replacementText: candidate.replacementText,
                source: .history
            )
            if results.count == maximumSuggestions { return results }
        }

        if token.isCommandPosition, !token.decodedPrefix.contains("/") {
            for command in builtInCommands where Self.isUsefulMatch(command, for: token) {
                append(
                    text: command,
                    replacementText: command,
                    source: .builtIn
                )
                if results.count == maximumSuggestions { return results }
            }

            let executables = indexedExecutables ?? executableCandidates(
                matching: token.decodedPrefix,
                currentDirectory: currentDirectory,
                searchPath: executableSearchPath
            )
            for executable in executables where Self.isUsefulMatch(executable, for: token) {
                append(
                    text: executable,
                    replacementText: Self.shellEscape(executable),
                    source: .executable
                )
                if results.count == maximumSuggestions { return results }
            }
        }

        for candidate in fileSystemCandidates(
            matching: token.decodedPrefix,
            currentDirectory: currentDirectory
        ) where Self.isUsefulMatch(candidate.text, for: token) {
            append(
                text: candidate.text,
                replacementText: Self.shellEscape(candidate.text),
                source: .fileSystem,
                isDirectory: candidate.isDirectory
            )
            if results.count == maximumSuggestions { return results }
        }

        return results
    }

    func accept(
        _ suggestion: CommandAutocompleteSuggestion,
        in draft: String,
        cursorUTF16Offset: Int? = nil
    ) -> CommandAutocompleteEdit {
        let draftText = draft as NSString
        let cursor = min(
            max(0, cursorUTF16Offset ?? draftText.length),
            draftText.length
        )
        let token = Self.tokenContext(
            in: draft,
            cursorUTF16Offset: cursor
        )
        let replacementRange = Self.validated(
            suggestion.replacementRange,
            in: draftText
        ) ?? token.range
        let updatedDraft = draftText.replacingCharacters(
            in: replacementRange,
            with: suggestion.replacementText
        )
        let updatedCursorOffset = replacementRange.location
            + (suggestion.replacementText as NSString).length

        return CommandAutocompleteEdit(
            draft: updatedDraft,
            cursorUTF16Offset: updatedCursorOffset
        )
    }

    func replacementRange(
        in draft: String,
        cursorUTF16Offset: Int
    ) -> NSRange {
        Self.tokenContext(
            in: draft,
            cursorUTF16Offset: cursorUTF16Offset
        ).range
    }

    func decodedPrefix(
        in draft: String,
        cursorUTF16Offset: Int
    ) -> String {
        Self.tokenContext(
            in: draft,
            cursorUTF16Offset: cursorUTF16Offset
        ).decodedPrefix
    }

    func capturedSuggestions(
        _ candidates: [ZshCompletionCandidate]
    ) -> [CommandAutocompleteSuggestion] {
        var results: [CommandAutocompleteSuggestion] = []
        var seen: Set<String> = []

        for candidate in candidates {
            guard results.count < maximumSuggestions,
                  seen.insert(candidate.replacementText).inserted else { continue }
            results.append(
                CommandAutocompleteSuggestion(
                    text: candidate.replacementText,
                    replacementText: candidate.replacementText,
                    source: .zsh,
                    isDirectory: candidate.isDirectory,
                    detail: candidate.detail
                )
            )
        }
        return results
    }
}

private extension CommandAutocomplete {
    struct TokenContext {
        let range: NSRange
        let contextPrefix: String
        let decodedPrefix: String
        let decodedToken: String
        let isCommandPosition: Bool
    }

    struct Candidate {
        let text: String
        let replacementText: String
    }

    struct FileSystemCandidate {
        let text: String
        let isDirectory: Bool
    }

    enum QuoteState {
        case unquoted
        case singleQuoted
        case doubleQuoted
    }

    func historyCandidates(
        _ history: [String],
        token: TokenContext
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen: Set<String> = []
        let prefixLength = (token.contextPrefix as NSString).length

        // CommandHistory stores oldest first. Walking backward gives stable,
        // session-recency ordering without timestamps or global history reads.
        for command in history.reversed() {
            let commandText = command as NSString
            guard commandText.length >= prefixLength,
                  commandText.substring(with: NSRange(location: 0, length: prefixLength))
                    == token.contextPrefix else { continue }

            let candidateRange = Self.currentTokenRange(
                in: command,
                cursorUTF16Offset: prefixLength
            )
            guard candidateRange.location == prefixLength,
                  candidateRange.length > 0 else { continue }

            let rawCandidate = commandText.substring(with: candidateRange)
            let decodedCandidate = Self.shellUnescape(rawCandidate)
            guard decodedCandidate.hasPrefix(token.decodedPrefix),
                  Self.isUsefulMatch(decodedCandidate, for: token),
                  seen.insert(decodedCandidate).inserted else { continue }

            candidates.append(
                Candidate(
                    text: decodedCandidate,
                    replacementText: rawCandidate
                )
            )
            if candidates.count == maximumSuggestions { break }
        }

        return candidates
    }

    func executableCandidates(
        matching prefix: String,
        currentDirectory: URL,
        searchPath: String?
    ) -> [String] {
        guard let searchPath, !searchPath.isEmpty else { return [] }

        var names: Set<String> = []
        let directoryPaths = searchPath.split(
            separator: ":",
            omittingEmptySubsequences: false
        )

        for directoryPath in directoryPaths {
            let path = String(directoryPath)
            let directory: URL
            if path.isEmpty {
                directory = currentDirectory
            } else if path.hasPrefix("/") {
                directory = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                directory = currentDirectory.appendingPathComponent(path, isDirectory: true)
            }

            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                continue
            }

            for name in entries where name.hasPrefix(prefix) {
                let candidateURL = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: candidateURL.path,
                    isDirectory: &isDirectory
                ), !isDirectory.boolValue,
                    fileManager.isExecutableFile(atPath: candidateURL.path) else { continue }
                names.insert(name)
            }
        }

        return names.sorted()
    }

    func fileSystemCandidates(
        matching prefix: String,
        currentDirectory: URL
    ) -> [FileSystemCandidate] {
        guard !prefix.hasPrefix("~") else { return [] }

        let directoryPrefix: String
        let leafPrefix: String
        if let slash = prefix.lastIndex(of: "/") {
            directoryPrefix = String(prefix[...slash])
            leafPrefix = String(prefix[prefix.index(after: slash)...])
        } else {
            directoryPrefix = ""
            leafPrefix = prefix
        }

        let directory: URL
        if directoryPrefix == "/" {
            directory = URL(fileURLWithPath: "/", isDirectory: true)
        } else {
            let directoryPath = String(directoryPrefix.dropLast())
            if directoryPath.hasPrefix("/") {
                directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            } else if directoryPath.isEmpty {
                directory = currentDirectory
            } else {
                directory = currentDirectory.appendingPathComponent(
                    directoryPath,
                    isDirectory: true
                )
            }
        }

        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        return entries
            .filter { name in
                name.hasPrefix(leafPrefix)
                    && (!name.hasPrefix(".") || leafPrefix.hasPrefix("."))
            }
            .sorted()
            .compactMap { name in
                let candidateURL = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: candidateURL.path,
                    isDirectory: &isDirectory
                ) else { return nil }
                return FileSystemCandidate(
                    text: directoryPrefix + name + (isDirectory.boolValue ? "/" : ""),
                    isDirectory: isDirectory.boolValue
                )
            }
    }

    static func isUsefulMatch(_ candidate: String, for token: TokenContext) -> Bool {
        candidate.hasPrefix(token.decodedPrefix)
            && (candidate != token.decodedPrefix || candidate != token.decodedToken)
    }

    static func validated(
        _ range: NSRange?,
        in text: NSString
    ) -> NSRange? {
        guard let range,
              range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= text.length,
              range.length <= text.length - range.location else {
            return nil
        }
        return range
    }

    static func tokenContext(
        in draft: String,
        cursorUTF16Offset: Int?
    ) -> TokenContext {
        let text = draft as NSString
        let cursor = min(max(0, cursorUTF16Offset ?? text.length), text.length)
        let range = currentTokenRange(in: draft, cursorUTF16Offset: cursor)
        let prefixLength = max(0, min(cursor - range.location, range.length))
        let rawPrefix = text.substring(
            with: NSRange(location: range.location, length: prefixLength)
        )
        let rawToken = text.substring(with: range)
        let contextPrefix = text.substring(
            with: NSRange(location: 0, length: range.location)
        )

        return TokenContext(
            range: range,
            contextPrefix: contextPrefix,
            decodedPrefix: shellUnescape(rawPrefix),
            decodedToken: shellUnescape(rawToken),
            isCommandPosition: isCommandPosition(in: text, tokenStart: range.location)
        )
    }

    static func currentTokenRange(
        in text: String,
        cursorUTF16Offset: Int
    ) -> NSRange {
        let string = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), string.length)
        var ranges: [NSRange] = []
        var tokenStart: Int?
        var quoteState = QuoteState.unquoted
        var isEscaped = false
        var index = 0

        while index < string.length {
            let character = string.character(at: index)

            // Treat physical newlines as token boundaries. This keeps editing
            // scoped to the active line even for a multiline command draft.
            if character == 10 || character == 13 {
                if let start = tokenStart {
                    ranges.append(
                        NSRange(location: start, length: index - start)
                    )
                    resetTokenState(
                        &tokenStart,
                        quoteState: &quoteState,
                        isEscaped: &isEscaped
                    )
                } else {
                    quoteState = .unquoted
                    isEscaped = false
                }
                index += 1
                continue
            }

            switch quoteState {
            case .unquoted:
                if isEscaped {
                    isEscaped = false
                } else if isWhitespace(character) {
                    if let start = tokenStart {
                        ranges.append(
                            NSRange(location: start, length: index - start)
                        )
                        resetTokenState(
                            &tokenStart,
                            quoteState: &quoteState,
                            isEscaped: &isEscaped
                        )
                    }
                    index += 1
                    continue
                } else {
                    if tokenStart == nil { tokenStart = index }
                    if character == 92 {
                        isEscaped = true
                    } else if character == 39 {
                        quoteState = .singleQuoted
                    } else if character == 34 {
                        quoteState = .doubleQuoted
                    }
                }

            case .singleQuoted:
                if character == 39 { quoteState = .unquoted }

            case .doubleQuoted:
                if isEscaped {
                    isEscaped = false
                } else if character == 92 {
                    isEscaped = true
                } else if character == 34 {
                    quoteState = .unquoted
                }
            }

            index += 1
        }

        if let start = tokenStart {
            ranges.append(NSRange(location: start, length: string.length - start))
        }

        if let range = ranges.first(where: {
            cursor >= $0.location && cursor <= NSMaxRange($0)
        }) {
            return range
        }
        return NSRange(location: cursor, length: 0)
    }

    static func resetTokenState(
        _ tokenStart: inout Int?,
        quoteState: inout QuoteState,
        isEscaped: inout Bool
    ) {
        tokenStart = nil
        quoteState = .unquoted
        isEscaped = false
    }

    static func isCommandPosition(in text: NSString, tokenStart: Int) -> Bool {
        var index = tokenStart - 1
        while index >= 0 {
            let character = text.character(at: index)
            if character == 10 || character == 13 { return true }
            if isWhitespace(character) {
                index -= 1
                continue
            }
            return character == 59 // ;
                || character == 124 // |
                || character == 38 // &
                || character == 40 // (
        }
        return true
    }

    static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(character)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func shellUnescape(_ token: String) -> String {
        var result = ""
        var quoteState = QuoteState.unquoted
        var isEscaped = false

        for scalar in token.unicodeScalars {
            if isEscaped {
                result.unicodeScalars.append(scalar)
                isEscaped = false
                continue
            }

            switch quoteState {
            case .unquoted:
                if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "'" {
                    quoteState = .singleQuoted
                } else if scalar == "\"" {
                    quoteState = .doubleQuoted
                } else {
                    result.unicodeScalars.append(scalar)
                }

            case .singleQuoted:
                if scalar == "'" {
                    quoteState = .unquoted
                } else {
                    result.unicodeScalars.append(scalar)
                }

            case .doubleQuoted:
                if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    quoteState = .unquoted
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        if isEscaped { result.append("\\") }
        return result
    }

    static func shellEscape(_ value: String) -> String {
        let safeCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
        )
        var result = ""
        for scalar in value.unicodeScalars {
            if safeCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("\\")
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
