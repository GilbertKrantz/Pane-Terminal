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
    private let autocomplete: CommandAutocomplete

    init(
        executableIndex: ExecutableIndex = ExecutableIndex(),
        maximumSuggestions: Int = 12
    ) {
        self.executableIndex = executableIndex
        self.autocomplete = CommandAutocomplete(maximumSuggestions: maximumSuggestions)
    }

    func suggestions(for context: LocalAutocompleteContext) async -> [CommandAutocompleteSuggestion] {
        guard !Task.isCancelled else { return [] }
        let prefix = Self.commandPrefix(in: context.draft, cursorUTF16Offset: context.cursorUTF16Offset)
        let executables = await executableIndex.candidates(
            prefix: prefix,
            path: context.executableSearchPath,
            currentDirectory: context.currentDirectory,
            shellGeneration: context.shellGeneration
        )
        guard !Task.isCancelled else { return [] }
        return autocomplete.suggestions(
            for: context.draft,
            cursorUTF16Offset: context.cursorUTF16Offset,
            history: context.history,
            currentDirectory: context.currentDirectory,
            executableSearchPath: "",
            indexedExecutables: executables
        )
    }

    private static func commandPrefix(in draft: String, cursorUTF16Offset: Int) -> String {
        let text = draft as NSString
        let cursor = min(max(0, cursorUTF16Offset), text.length)
        var start = cursor
        while start > 0 {
            let character = text.character(at: start - 1)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(character)!) { break }
            start -= 1
        }
        return text.substring(with: NSRange(location: start, length: cursor - start))
    }
}
