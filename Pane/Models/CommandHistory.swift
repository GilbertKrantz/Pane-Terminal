import Foundation

struct CommandHistory: Equatable, Sendable {
    private(set) var commands: [String] = []
    private var cursor: Int?
    private var pendingDraft = ""

    var count: Int { commands.count }

    mutating func append(_ command: String) {
        guard !command.isEmpty else {
            resetNavigation()
            return
        }

        if commands.last != command {
            commands.append(command)
        }
        resetNavigation()
    }

    mutating func replaceMostRecent(with command: String) {
        guard !commands.isEmpty else {
            append(command)
            return
        }
        commands[commands.count - 1] = command
        resetNavigation()
    }

    mutating func removeMostRecent() {
        if !commands.isEmpty {
            commands.removeLast()
        }
        resetNavigation()
    }

    mutating func previous(currentDraft: String) -> String {
        guard !commands.isEmpty else { return currentDraft }

        if cursor == nil {
            pendingDraft = currentDraft
            cursor = commands.count - 1
        } else if let cursor, cursor > 0 {
            self.cursor = cursor - 1
        }

        return commands[cursor ?? 0]
    }

    mutating func next(currentDraft: String) -> String {
        guard let cursor else { return currentDraft }

        if cursor < commands.count - 1 {
            self.cursor = cursor + 1
            return commands[cursor + 1]
        }

        let draft = pendingDraft
        resetNavigation()
        return draft
    }

    mutating func resetNavigation() {
        cursor = nil
        pendingDraft = ""
    }
}
