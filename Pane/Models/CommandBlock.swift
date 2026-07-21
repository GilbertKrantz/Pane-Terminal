import Foundation

struct CommandBlock: Identifiable, Equatable, Sendable {
    enum ExecutionState: Equatable, Sendable {
        case queued
        case running
        case completed(exitCode: Int32)
        case interrupted(exitCode: Int32?)
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

    init(
        id: UUID = UUID(),
        command: String,
        workingDirectory: String,
        submittedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        state: ExecutionState = .queued,
        output: String = "",
        isCollapsed: Bool = false
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
            let durationText = duration.map(Self.formatDuration) ?? "Done"
            return exitCode == 0 ? durationText : "Exited \(exitCode) · \(durationText)"
        case .interrupted(let exitCode):
            if let exitCode {
                return "Interrupted · \(exitCode)"
            }
            return "Interrupted"
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
        at date: Date = Date()
    ) -> UUID {
        let block = CommandBlock(
            command: command,
            workingDirectory: workingDirectory,
            submittedAt: date
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
            case .completed, .interrupted:
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
            case .completed, .interrupted:
                return true
            case .queued, .running:
                return false
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
