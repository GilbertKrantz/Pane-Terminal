import Darwin
import Foundation

struct BoundedByteTail {
    private let limit: Int
    private var storage = Data()
    private var discardedCount = 0
    private var hasDiscardedBytes = false

    init(limit: Int) {
        self.limit = limit
    }

    var isEmpty: Bool {
        storage.count == discardedCount
    }

    var isTruncated: Bool {
        hasDiscardedBytes
    }

    var data: Data {
        Data(storage.dropFirst(discardedCount))
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }

        if data.count >= limit {
            let replacingRetainedBytes = !isEmpty
            storage = Data(data.suffix(limit))
            discardedCount = 0
            hasDiscardedBytes = hasDiscardedBytes || replacingRetainedBytes || data.count > limit
            return
        }

        storage.append(data)
        let retainedCount = storage.count - discardedCount
        if retainedCount > limit {
            discardedCount += retainedCount - limit
            hasDiscardedBytes = true
        }

        if discardedCount >= 1_048_576 {
            storage = Data(storage.dropFirst(discardedCount))
            discardedCount = 0
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        discardedCount = 0
        hasDiscardedBytes = false
    }
}

@MainActor
final class BlockLifecycleController {
    private(set) var timeline = CommandBlockTimeline()
    private(set) var awaitingStartID: UUID?
    private(set) var pruningNotice: ScrollbackPruningNotice?

    var onTimelineChanged: ((CommandBlockTimeline) -> Void)?
    var onTimelinePruned: ((ScrollbackPruningNotice) -> Void)?

    private let scrollbackPolicy: ScrollbackPolicy
    private var activeCapture: BoundedHeadTailByteCapture
    private var activeUsedNonAlternateDirectInteraction = false
    private var activeEnteredAlternateScreen = false

    init(scrollbackPolicy: ScrollbackPolicy = .standard) {
        self.scrollbackPolicy = scrollbackPolicy
        activeCapture = BoundedHeadTailByteCapture(
            limit: scrollbackPolicy.excerptByteLimit
        )
    }

    var isCommandActive: Bool {
        timeline.activeBlockID != nil || awaitingStartID != nil
    }

    var activeOrAwaitingBlockID: UUID? {
        timeline.activeBlockID ?? awaitingStartID
    }

    var activeBlock: CommandBlock? {
        guard let id = activeOrAwaitingBlockID else { return nil }
        return timeline.block(id: id)
    }

    var capturedOutputData: Data {
        activeCapture.data
    }

    var queuedBlocks: [CommandBlock] { timeline.queuedBlocks }

    func firstQueuedBlock() -> CommandBlock? { queuedBlocks.first }

    @discardableResult
    func queue(
        command: String,
        workingDirectory: String,
        isRerunnable: Bool
    ) -> UUID {
        let id = timeline.enqueue(
            command: command,
            workingDirectory: workingDirectory,
            isRerunnable: isRerunnable
        )
        publishTimeline()
        return id
    }

    func markAwaitingStart(_ id: UUID?) {
        if let id {
            guard timeline.activeBlockID == nil,
                  timeline.queuedBlocks.first?.id == id else { return }
        }
        guard awaitingStartID != id else { return }
        awaitingStartID = id
        publishTimeline()
    }

    @discardableResult
    func appendContinuation(_ continuation: String) -> String? {
        guard let awaitingStartID else { return nil }
        let command = timeline.appendContinuation(continuation, to: awaitingStartID)
        if command != nil { publishTimeline() }
        return command
    }

    @discardableResult
    func commandStarted() -> UUID? {
        guard let id = timeline.beginNext() else { return nil }
        awaitingStartID = nil
        resetCapture()
        publishTimeline()
        return id
    }

    func consumeTerminalBytes(_ data: Data) {
        guard !data.isEmpty, timeline.activeBlockID != nil else { return }
        if data.range(of: AlternateScreenTranscriptFilter.transitionPlaceholder) != nil {
            activeEnteredAlternateScreen = true
        }
        activeCapture.append(data)
    }

    func markDirectInteraction() {
        guard timeline.activeBlockID != nil else { return }
        activeUsedNonAlternateDirectInteraction = true
    }

    func markAlternateScreenEntered() {
        guard timeline.activeBlockID != nil else { return }
        activeEnteredAlternateScreen = true
    }

    @discardableResult
    func completeActive(
        exitCode: Int32,
        renderedOutput: String?,
        columns: Int,
        rows: Int
    ) -> UUID? {
        guard let activeID = timeline.activeBlockID else { return nil }
        let output = finalizedOutput(renderedOutput: renderedOutput)
        let snapshot = finalizedTerminalSnapshot(columns: columns, rows: rows)
        let completedID: UUID?
        if exitCode == 128 + SIGINT {
            timeline.interruptActive(
                exitCode: exitCode,
                output: output.text,
                outputKind: output.kind,
                terminalSnapshot: snapshot
            )
            completedID = activeID
        } else {
            completedID = timeline.finishActive(
                exitCode: exitCode,
                output: output.text,
                outputKind: output.kind,
                terminalSnapshot: snapshot
            )
        }
        resetCapture()
        applyScrollbackPolicy(compactOversizedOutputs: false)
        publishTimeline()
        return completedID
    }

    @discardableResult
    func interruptAwaiting(exitCode: Int32?) -> UUID? {
        guard let awaitingStartID else { return nil }
        timeline.interruptQueued(id: awaitingStartID, exitCode: exitCode)
        self.awaitingStartID = nil
        applyScrollbackPolicy(compactOversizedOutputs: false)
        publishTimeline()
        return awaitingStartID
    }

    @discardableResult
    func interruptUnfinished(
        exitCode: Int32?,
        renderedOutput: String?,
        columns: Int,
        rows: Int,
        preserveQueued: Bool = false
    ) -> UUID? {
        let blockID = activeOrAwaitingBlockID
        guard blockID != nil else {
            clearCapture()
            awaitingStartID = nil
            return nil
        }

        let output = finalizedOutput(renderedOutput: renderedOutput)
        if preserveQueued {
            if timeline.activeBlockID != nil {
                timeline.interruptActive(
                    exitCode: exitCode,
                    output: output.text,
                    outputKind: output.kind,
                    terminalSnapshot: finalizedTerminalSnapshot(
                        columns: columns,
                        rows: rows
                    )
                )
            } else if let awaitingStartID {
                timeline.interruptQueued(id: awaitingStartID, exitCode: exitCode)
            }
        } else {
            timeline.interruptUnfinished(
                exitCode: exitCode,
                activeOutput: output.text,
                activeOutputKind: output.kind,
                activeTerminalSnapshot: finalizedTerminalSnapshot(
                    columns: columns,
                    rows: rows
                )
            )
        }
        awaitingStartID = nil
        resetCapture()
        applyScrollbackPolicy(compactOversizedOutputs: false)
        publishTimeline()
        return blockID
    }

    func remove(id: UUID) {
        if timeline.activeBlockID == id {
            resetCapture()
        }
        if awaitingStartID == id {
            awaitingStartID = nil
        }
        timeline.remove(id: id)
        publishTimeline()
    }

    @discardableResult
    func removeQueued(id: UUID) -> Bool {
        guard id != awaitingStartID else { return false }
        let removed = timeline.removeQueued(id: id)
        if removed { publishTimeline() }
        return removed
    }

    @discardableResult
    func moveQueued(id: UUID, before destinationID: UUID) -> Bool {
        guard id != awaitingStartID, destinationID != awaitingStartID else { return false }
        let moved = timeline.moveQueued(id: id, before: destinationID)
        if moved { publishTimeline() }
        return moved
    }

    @discardableResult
    func moveQueuedToFront(id: UUID) -> Bool {
        guard id != awaitingStartID else { return false }
        let moved = timeline.moveQueuedToFront(id: id)
        if moved { publishTimeline() }
        return moved
    }

    func clearFinalized() {
        timeline.clearFinalized()
        publishTimeline()
    }

    func clearFinalizedOutput() {
        timeline.clearFinalizedOutput()
        publishTimeline()
    }

    func restore(_ blocks: [CommandBlock]) {
        timeline.restore(blocks)
        applyScrollbackPolicy()
        publishTimeline()
    }

    func toggleCollapsed(id: UUID) {
        timeline.toggleCollapsed(id: id)
        publishTimeline()
    }

    func setAllCompletedCollapsed(_ collapsed: Bool) {
        timeline.setAllCompletedCollapsed(collapsed)
        publishTimeline()
    }

    func clearCapture() {
        resetCapture()
    }

    func dismissPruningNotice() {
        pruningNotice = nil
    }

    func assertInvariants(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let unfinished = timeline.blocks.filter {
            switch $0.state {
            case .queued, .running: return true
            case .completed, .interrupted, .unknown: return false
            }
        }
        let running = unfinished.filter {
            if case .running = $0.state { return true }
            return false
        }
        assert(running.count <= 1, "More than one running block", file: file, line: line)
        assert(
            timeline.activeBlockID == running.first?.id,
            "Active block ID does not identify the running block",
            file: file,
            line: line
        )
        if let awaitingStartID {
            assert(
                timeline.block(id: awaitingStartID)?.state == .queued,
                "Awaiting-start ID must identify a queued block",
                file: file,
                line: line
            )
        }
    }

    nonisolated static func requiresRichTerminalRendering(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        var sawCarriageReturn = false
        var previousWasCarriageReturn = false

        for byte in data {
            if byte == 0x1B || byte == 0x9B || byte == 0x08 { return true }
            if byte == 0x0D {
                sawCarriageReturn = true
                previousWasCarriageReturn = true
                continue
            }
            if previousWasCarriageReturn, byte != 0x0A { return true }
            previousWasCarriageReturn = false
        }
        return sawCarriageReturn && !data.contains(0x0A)
    }

    private func finalizedOutput(renderedOutput: String?) -> CompactedBlockOutput {
        guard timeline.activeBlockID != nil else {
            return CompactedBlockOutput(text: "", kind: .none, omittedByteCount: 0)
        }
        // A mounted terminal transcript is itself bounded by terminal
        // scrollback. Once the stream capture has truncated, use its
        // head/tail representation so a short rendered viewport cannot be
        // mislabeled as complete output.
        if activeCapture.isTruncated {
            return BoundedOutputCompactor.compactSanitizedCapture(
                activeCapture,
                byteLimit: scrollbackPolicy.excerptByteLimit
            )
        }
        if let renderedOutput {
            return BoundedOutputCompactor.compact(
                renderedOutput,
                byteLimit: scrollbackPolicy.excerptByteLimit
            )
        }
        return BoundedOutputCompactor.compactSanitizedCapture(
            activeCapture,
            byteLimit: scrollbackPolicy.excerptByteLimit
        )
    }

    private func finalizedTerminalSnapshot(
        columns: Int,
        rows: Int
    ) -> TerminalReplaySnapshot? {
        guard timeline.activeBlockID != nil else { return nil }
        let rawBytes = activeCapture.data
        let requiresRichRendering = Self.requiresRichTerminalRendering(rawBytes)
            || (activeUsedNonAlternateDirectInteraction && !activeEnteredAlternateScreen)
        guard requiresRichRendering else { return nil }

        let safeBytes = BoundedOutputCompactor.compactReplay(
            activeCapture,
            byteLimit: scrollbackPolicy.excerptByteLimit
        )
        guard !safeBytes.isEmpty else { return nil }
        return TerminalReplaySnapshot(
            bytes: safeBytes,
            columns: max(1, columns),
            rows: max(1, rows),
            isTruncated: activeCapture.isTruncated
        )
    }

    private func resetCapture() {
        activeCapture.removeAll()
        activeUsedNonAlternateDirectInteraction = false
        activeEnteredAlternateScreen = false
    }

    private func applyScrollbackPolicy(compactOversizedOutputs: Bool = true) {
        guard let notice = timeline.enforceScrollbackPolicy(
            scrollbackPolicy,
            compactOversizedOutputs: compactOversizedOutputs
        ) else {
            return
        }
        pruningNotice = notice
        onTimelinePruned?(notice)
    }

    private func publishTimeline() {
        assertInvariants()
        onTimelineChanged?(timeline)
    }
}
