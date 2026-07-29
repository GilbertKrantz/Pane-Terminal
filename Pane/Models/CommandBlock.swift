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

struct TerminalReplaySnapshot: Equatable, Sendable {
    let bytes: Data
    let columns: Int
    let rows: Int
    let isTruncated: Bool
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
    var terminalSnapshot: TerminalReplaySnapshot?
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
        terminalSnapshot: TerminalReplaySnapshot? = nil,
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
        self.terminalSnapshot = terminalSnapshot
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

    var isFinalized: Bool {
        switch state {
        case .completed, .interrupted, .unknown:
            return true
        case .queued, .running:
            return false
        }
    }

    func presentation(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> BlockPresentationModel {
        let directoryLabel: String
        if workingDirectory == homeDirectory {
            directoryLabel = "~"
        } else if workingDirectory.hasPrefix(homeDirectory + "/") {
            directoryLabel = "~" + workingDirectory.dropFirst(homeDirectory.count)
        } else {
            directoryLabel = workingDirectory
        }
        return BlockPresentationModel(
            status: BlockStatusPresentation(state: state, durationLabel: statusText),
            directoryLabel: directoryLabel
        )
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(max(1, Int((duration * 1_000).rounded()))) ms"
        }
        return String(format: "%.1f s", duration)
    }
}

enum BlockStatusPresentation: Equatable, Sendable {
    case success
    case failure(exitCode: Int32)
    case interrupted(exitCode: Int32?)
    case queued
    case running(durationLabel: String)
    case unknown

    init(state: CommandBlock.ExecutionState, durationLabel: String) {
        switch state {
        case .completed(exitCode: 0):
            self = .success
        case .completed(let exitCode):
            self = .failure(exitCode: exitCode)
        case .interrupted(let exitCode):
            self = .interrupted(exitCode: exitCode)
        case .queued:
            self = .queued
        case .running:
            self = .running(durationLabel: durationLabel)
        case .unknown:
            self = .unknown
        }
    }

    var compactLabel: String? {
        switch self {
        case .success:
            return nil
        case .failure(let exitCode):
            return "Failed · Exit \(exitCode)"
        case .interrupted(let exitCode):
            return exitCode.map { "Interrupted · Exit \($0)" } ?? "Interrupted"
        case .queued:
            return "Queued"
        case .running(let durationLabel):
            return durationLabel
        case .unknown:
            return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .success: return "checkmark"
        case .failure: return "xmark"
        case .interrupted: return "stop"
        case .queued: return "clock"
        case .running: return "circle.dotted"
        case .unknown: return "questionmark.circle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .success:
            return "Command succeeded"
        case .failure(let exitCode):
            return "Command failed with exit code \(exitCode)"
        case .interrupted(let exitCode):
            return exitCode.map { "Command interrupted with exit code \($0)" }
                ?? "Command interrupted"
        case .queued:
            return "Command queued"
        case .running:
            return "Command running"
        case .unknown:
            return "Command status unknown"
        }
    }
}

struct BlockPresentationModel: Equatable, Sendable {
    let status: BlockStatusPresentation
    let directoryLabel: String
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
        terminalSnapshot: TerminalReplaySnapshot? = nil,
        at date: Date = Date()
    ) -> UUID? {
        guard let activeBlockID, let index = index(of: activeBlockID) else { return nil }
        blocks[index].output = output
        blocks[index].terminalSnapshot = terminalSnapshot
        blocks[index].completedAt = date
        blocks[index].state = .completed(exitCode: exitCode)
        self.activeBlockID = nil
        return activeBlockID
    }

    mutating func interruptActive(
        exitCode: Int32? = nil,
        output: String = "",
        terminalSnapshot: TerminalReplaySnapshot? = nil,
        at date: Date = Date()
    ) {
        guard let activeBlockID, let index = index(of: activeBlockID) else { return }
        blocks[index].output = output
        blocks[index].terminalSnapshot = terminalSnapshot
        blocks[index].completedAt = date
        blocks[index].state = .interrupted(exitCode: exitCode)
        self.activeBlockID = nil
    }

    mutating func interruptUnfinished(
        exitCode: Int32? = nil,
        activeOutput: String = "",
        activeTerminalSnapshot: TerminalReplaySnapshot? = nil,
        at date: Date = Date()
    ) {
        for index in blocks.indices {
            switch blocks[index].state {
            case .queued:
                blocks[index].completedAt = date
                blocks[index].state = .interrupted(exitCode: exitCode)
            case .running:
                blocks[index].output = activeOutput
                blocks[index].terminalSnapshot = activeTerminalSnapshot
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
                blocks[index].terminalSnapshot = nil
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
    case commands = "Commands"
    case output = "Output"
    case directories = "Directories"
    case status = "Status"
}

struct BlockSearchQuery: Equatable, Sendable {
    var text = ""
    var filter: BlockSearchFilter = .all

    func matches(_ block: CommandBlock) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let fields: [String]
        switch filter {
        case .all: fields = [block.command, block.output, block.workingDirectory, block.statusText]
        case .commands: fields = [block.command]
        case .output: fields = [block.output]
        case .directories: fields = [block.workingDirectory]
        case .status: fields = [block.statusText]
        }
        return fields.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
