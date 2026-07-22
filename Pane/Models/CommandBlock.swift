import Foundation

enum CommandBlockOrigin: Equatable, Sendable {
    case live
    case restored(sessionID: UUID)
}

enum PersistedOutputKind: String, Codable, Sendable, Equatable {
    case none
    case complete
    case excerpt
}

struct CommandBlock: Identifiable, Equatable, Sendable {
    enum ExecutionState: Equatable, Sendable {
        case queued
        case running
        case completed(exitCode: Int32)
        case interrupted(exitCode: Int32?)
        case unknown
    }

    let id: UUID
    var command: String
    let workingDirectory: String
    let submittedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var state: ExecutionState
    var output: String
    var isCollapsed: Bool
    var isRerunnable: Bool
    var origin: CommandBlockOrigin
    var outputKind: PersistedOutputKind

    init(
        id: UUID = UUID(),
        command: String,
        workingDirectory: String,
        submittedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        state: ExecutionState = .queued,
        output: String = "",
        isCollapsed: Bool = false,
        isRerunnable: Bool = true,
        origin: CommandBlockOrigin = .live,
        outputKind: PersistedOutputKind = .none
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.submittedAt = submittedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.state = state
        self.output = output
        self.isCollapsed = isCollapsed
        self.isRerunnable = isRerunnable
        self.origin = origin
        self.outputKind = outputKind
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var processName: String {
        command
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? "zsh"
    }

    var statusText: String {
        switch state {
        case .queued:
            return "Waiting"
        case .running:
            return duration.map(Self.formatDuration) ?? "Running"
        case .completed(let exitCode):
            if exitCode == 0 { return "Succeeded" }
            return "Failed · Exit \(exitCode)"
        case .interrupted(let exitCode):
            if let exitCode { return "Interrupted · Exit \(exitCode)" }
            return "Interrupted"
        case .unknown:
            return "Completion unknown"
        }
    }

    var succeeded: Bool {
        if case .completed(exitCode: 0) = state { return true }
        return false
    }

    var failed: Bool {
        if case .completed(let exitCode) = state { return exitCode != 0 }
        return false
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(max(1, Int((duration * 1_000).rounded()))) ms"
        }
        return String(format: "%.1f s", duration)
    }
}

struct CommandBlockTimeline: Equatable, Sendable {
    private(set) var blocks: [CommandBlock] = []
    private(set) var activeBlockID: UUID?
    private var queuedBlockIDs: [UUID] = []

    @discardableResult
    mutating func enqueue(
        command: String,
        workingDirectory: String,
        at date: Date = Date(),
        isRerunnable: Bool = true
    ) -> UUID {
        let block = CommandBlock(
            command: command,
            workingDirectory: workingDirectory,
            submittedAt: date,
            isRerunnable: isRerunnable
        )
        blocks.append(block)
        queuedBlockIDs.append(block.id)
        return block.id
    }

    @discardableResult
    mutating func beginNext(at date: Date = Date()) -> UUID? {
        guard activeBlockID == nil, !queuedBlockIDs.isEmpty else { return nil }
        let id = queuedBlockIDs.removeFirst()
        guard let index = index(of: id) else { return nil }
        blocks[index].startedAt = date
        blocks[index].state = .running
        activeBlockID = id
        return id
    }

    @discardableResult
    mutating func finishActive(
        exitCode: Int32,
        output: String = "",
        at date: Date = Date()
    ) -> UUID? {
        guard let activeBlockID, let index = index(of: activeBlockID) else { return nil }
        blocks[index].output = output
        blocks[index].completedAt = date
        blocks[index].state = .completed(exitCode: exitCode)
        self.activeBlockID = nil
        return activeBlockID
    }

    mutating func interruptActive(
        exitCode: Int32? = nil,
        output: String = "",
        at date: Date = Date()
    ) {
        guard let activeBlockID, let index = index(of: activeBlockID) else { return }
        blocks[index].output = output
        blocks[index].completedAt = date
        blocks[index].state = .interrupted(exitCode: exitCode)
        self.activeBlockID = nil
    }

    mutating func interruptUnfinished(
        exitCode: Int32? = nil,
        activeOutput: String = "",
        at date: Date = Date()
    ) {
        for index in blocks.indices {
            switch blocks[index].state {
            case .queued:
                blocks[index].completedAt = date
                blocks[index].state = .interrupted(exitCode: exitCode)
            case .running:
                blocks[index].output = activeOutput
                blocks[index].completedAt = date
                blocks[index].state = .interrupted(exitCode: exitCode)
            case .completed, .interrupted, .unknown:
                break
            }
        }
        queuedBlockIDs.removeAll()
        activeBlockID = nil
    }

    mutating func toggleCollapsed(id: UUID) {
        guard let index = index(of: id) else { return }
        blocks[index].isCollapsed.toggle()
    }

    mutating func setCollapsed(_ collapsed: Bool, id: UUID) {
        guard let index = index(of: id) else { return }
        blocks[index].isCollapsed = collapsed
    }

    mutating func setAllCompletedCollapsed(_ collapsed: Bool) {
        for index in blocks.indices {
            switch blocks[index].state {
            case .completed, .interrupted, .unknown:
                blocks[index].isCollapsed = collapsed
            case .queued, .running:
                break
            }
        }
    }

    mutating func restore(_ restoredBlocks: [CommandBlock]) {
        var seen = Set(blocks.map(\.id))
        let uniqueBlocks = restoredBlocks.filter { block in
            seen.insert(block.id).inserted
        }
        blocks.insert(contentsOf: uniqueBlocks, at: 0)
    }

    @discardableResult
    mutating func appendContinuation(_ continuation: String, to id: UUID) -> String? {
        guard let index = index(of: id),
              case .queued = blocks[index].state else { return nil }
        blocks[index].command += "\n" + continuation
        return blocks[index].command
    }

    mutating func interruptQueued(
        id: UUID,
        exitCode: Int32? = nil,
        at date: Date = Date()
    ) {
        guard let index = index(of: id),
              case .queued = blocks[index].state else { return }
        queuedBlockIDs.removeAll { $0 == id }
        blocks[index].completedAt = date
        blocks[index].state = .interrupted(exitCode: exitCode)
    }

    mutating func remove(id: UUID) {
        blocks.removeAll { $0.id == id }
        queuedBlockIDs.removeAll { $0 == id }
        if activeBlockID == id {
            activeBlockID = nil
        }
    }

    mutating func clear() {
        blocks.removeAll()
        queuedBlockIDs.removeAll()
        activeBlockID = nil
    }

    /// Clears only immutable timeline entries. Running and queued commands
    /// remain tracked so their PTY lifecycle markers cannot be orphaned.
    mutating func clearFinalized() {
        blocks.removeAll { block in
            switch block.state {
            case .completed, .interrupted, .unknown:
                return true
            case .queued, .running:
                return false
            }
        }
    }

    mutating func clearFinalizedOutput() {
        for index in blocks.indices {
            switch blocks[index].state {
            case .completed, .interrupted, .unknown:
                blocks[index].output = ""
            case .queued, .running:
                break
            }
        }
    }

    func block(id: UUID) -> CommandBlock? {
        guard let index = index(of: id) else { return nil }
        return blocks[index]
    }

    private func index(of id: UUID) -> Int? {
        blocks.firstIndex { $0.id == id }
    }
}

enum BlockSearchFilter: String, CaseIterable, Sendable {
    case all = "All"
    case failed = "Failed"
    case interrupted = "Interrupted"
    case unknown = "Unknown"
}

struct BlockSearchQuery: Equatable, Sendable {
    var text = ""
    var filter: BlockSearchFilter = .all

    func matches(_ block: CommandBlock) -> Bool {
        let statusMatches: Bool
        switch filter {
        case .all:
            statusMatches = true
        case .failed:
            statusMatches = block.failed
        case .interrupted:
            if case .interrupted = block.state { statusMatches = true } else { statusMatches = false }
        case .unknown:
            if case .unknown = block.state { statusMatches = true } else { statusMatches = false }
        }
        guard statusMatches else { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [block.command, block.output, block.workingDirectory, block.statusText]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
